// OpenAI-compatible shim in front of llama-server (which runs with --skip-chat-parsing).
// Parses Gemma 4 native tool calls `<|tool_call>call:name{k:<|"|>v<|"|>}<tool_call|>`
// into OpenAI `tool_calls`, and re-streams responses as SSE when the client asks for it.

const UPSTREAM = process.env.UPSTREAM ?? "http://127.0.0.1:8080";
const PORT = Number(process.env.PORT ?? 8081);
const Q = '<|"|>';

// Convert Gemma's argument syntax to a JS value.
export function parseGemmaArgs(src: string): unknown {
  let i = 0;
  const ws = () => { while (i < src.length && /\s/.test(src[i])) i++; };
  const value = (): unknown => {
    ws();
    if (src.startsWith(Q, i)) {
      const end = src.indexOf(Q, i + Q.length);
      const s = src.slice(i + Q.length, end < 0 ? src.length : end);
      i = end < 0 ? src.length : end + Q.length;
      return s;
    }
    if (src[i] === "{") {
      i++;
      const obj: Record<string, unknown> = {};
      for (;;) {
        ws();
        if (src[i] === "}") { i++; return obj; }
        if (i >= src.length) return obj;
        let key: string;
        if (src.startsWith(Q, i)) key = value() as string;
        else if (src[i] === '"') { const e = src.indexOf('"', i + 1); key = src.slice(i + 1, e); i = e + 1; }
        else { const m = /^[^:}\s]+/.exec(src.slice(i))!; key = m[0]; i += key.length; }
        ws(); if (src[i] === ":") i++;
        obj[key] = value();
        ws(); if (src[i] === ",") i++;
      }
    }
    if (src[i] === "[") {
      i++;
      const arr: unknown[] = [];
      for (;;) {
        ws();
        if (src[i] === "]") { i++; return arr; }
        if (i >= src.length) return arr;
        arr.push(value());
        ws(); if (src[i] === ",") i++;
      }
    }
    if (src[i] === '"') {
      // plain JSON string
      let j = i + 1;
      while (j < src.length && src[j] !== '"') j += src[j] === "\\" ? 2 : 1;
      const raw = src.slice(i, j + 1); i = j + 1;
      try { return JSON.parse(raw); } catch { return raw.slice(1, -1); }
    }
    const m = /^[^,}\]\s]+/.exec(src.slice(i));
    if (!m) return null;
    i += m[0].length;
    const t = m[0];
    if (t === "true") return true;
    if (t === "false") return false;
    if (t === "null" || t === "none" || t === "None") return null;
    const n = Number(t);
    return Number.isNaN(n) ? t : n;
  };
  return value();
}

type ToolCall = { id: string; type: "function"; function: { name: string; arguments: string } };

export function splitContent(raw: string): { content: string; reasoning: string; toolCalls: ToolCall[] } {
  const toolCalls: ToolCall[] = [];
  let reasoning = "";
  let text = raw.replace(/<\|channel>thought\n?([\s\S]*?)<channel\|>/g, (_, r) => { reasoning += r; return ""; });
  text = text.replace(/<\|tool_call>call:([\w.\-]+)([\s\S]*?)(?:<tool_call\|>|$)/g, (_, name, args) => {
    let parsed: unknown = {};
    try { parsed = parseGemmaArgs(args.trim() || "{}") ?? {}; } catch {}
    toolCalls.push({
      id: "call_" + crypto.randomUUID().replace(/-/g, "").slice(0, 24),
      type: "function",
      function: { name, arguments: JSON.stringify(parsed) },
    });
    return "";
  });
  text = text.replace(/<\|?tool_response\|?>|<\|tool_call>|<tool_call\|>|<\|channel>|<channel\|>|<turn\|>|<\|turn>/g, "");
  return { content: text.trim(), reasoning: reasoning.trim(), toolCalls };
}

// Gemma sometimes misspells argument names ("descrption"), which makes the harness reject
// the call and the model retry the same mistake forever. Snap near-miss keys onto the
// tool's schema and fill missing required strings, so calls validate.
function editDistance(a: string, b: string): number {
  const dp = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) dp[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++)
      dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return dp[a.length][b.length];
}

export function repairArgs(args: Record<string, unknown>, schema: any): Record<string, unknown> {
  const props: Record<string, any> = schema?.properties ?? {};
  const names = Object.keys(props);
  if (!names.length) return args;
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args)) {
    if (key in props) { out[key] = value; continue; }
    let best = "", bestD = Infinity;
    for (const name of names) {
      if (name in args || name in out) continue;
      const k = key.toLowerCase(), n = name.toLowerCase();
      let prefix = 0;
      while (prefix < Math.min(k.length, n.length) && k[prefix] === n[prefix]) prefix++;
      const d = n.startsWith(k) || k.startsWith(n) || prefix >= 5 ? 1 : editDistance(k, n);
      if (d < bestD) { best = name; bestD = d; }
    }
    if (best && bestD <= Math.max(2, Math.floor(best.length * 0.34))) out[best] = value;
    else out[key] = value;
  }
  for (const name of schema?.required ?? []) {
    if (!(name in out) && props[name]?.type === "string") out[name] = name === "description" ? "Run command" : "";
  }
  return out;
}

function sse(obj: unknown) { return `data: ${JSON.stringify(obj)}\n\n`; }

// Live view of what the model is doing, polled by the notch app at GET /notch/status.
type Phase = "idle" | "waking" | "prefill" | "generating";
const status = {
  phase: "idle" as Phase,
  kind: "",               // agent | decision | chat
  startedAt: 0,           // ms epoch of the current request
  promptTotal: 0,
  promptCached: 0,
  promptProcessed: 0,
  prefillTps: 0,
  genTokens: 0,
  genStartedAt: 0,
  genTps: 0,
  last: null as null | { kind: string; promptTokens: number; cached: number; prefillTps: number; genTokens: number; genTps: number; durationMs: number; endedAt: number },
};

function statusJSON() {
  const now = Date.now();
  let genTps = status.genTps;
  if (status.phase === "generating" && status.genStartedAt && status.genTokens > 1) {
    genTps = (status.genTokens - 1) / ((now - status.genStartedAt) / 1000);
  }
  return { ...status, genTps: Math.round(genTps * 10) / 10, elapsedMs: status.startedAt ? now - status.startedAt : 0, now };
}

async function isSleeping(): Promise<boolean> {
  try {
    const r = await fetch(`${UPSTREAM}/props`, { signal: AbortSignal.timeout(1000) });
    return !!(await r.json()).is_sleeping;
  } catch { return false; }
}

type UpstreamResult = { id: string; created: number; model: string; content: string; finish: string; usage: any; timings: any };

/** Streams from llama-server so prompt progress and token rate are observable. */
async function callUpstream(body: any, signal: AbortSignal, kind: string): Promise<UpstreamResult | Response> {
  Object.assign(status, {
    phase: (await isSleeping()) ? "waking" : "prefill", kind, startedAt: Date.now(),
    promptTotal: 0, promptCached: 0, promptProcessed: 0, prefillTps: 0, genTokens: 0, genStartedAt: 0, genTps: 0,
  });
  try {
    const up = await fetch(`${UPSTREAM}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...body, stream: true, return_progress: true, stream_options: { include_usage: true } }),
      signal,
    });
    if (!up.ok || !up.body) {
      return new Response(await up.text(), { status: up.status, headers: { "content-type": "application/json" } });
    }
    const result: UpstreamResult = { id: "", created: 0, model: body.model, content: "", finish: "stop", usage: null, timings: {} };
    const decoder = new TextDecoder();
    let buffer = "";
    for await (const chunk of up.body as any) {
      buffer += decoder.decode(chunk, { stream: true });
      let nl: number;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (payload === "[DONE]") continue;
        let ev: any;
        try { ev = JSON.parse(payload); } catch { continue; }
        if (ev.error) return Response.json({ error: ev.error }, { status: 500 });
        result.id ||= ev.id; result.created ||= ev.created; result.model = ev.model ?? result.model;
        const pp = ev.prompt_progress;
        if (pp) {
          status.phase = "prefill";
          status.promptTotal = pp.total; status.promptCached = pp.cache; status.promptProcessed = pp.processed;
          const done = pp.processed - pp.cache;
          if (pp.time_ms > 0) status.prefillTps = Math.round((done / pp.time_ms) * 10000) / 10;
        }
        const choice = ev.choices?.[0];
        const delta = choice?.delta?.content;
        if (typeof delta === "string" && delta.length) {
          if (status.phase !== "generating") { status.phase = "generating"; status.genStartedAt = Date.now(); }
          status.genTokens++;
          result.content += delta;
        }
        if (choice?.finish_reason) result.finish = choice.finish_reason;
        if (ev.usage) result.usage = ev.usage;
        if (ev.timings) result.timings = ev.timings;
      }
    }
    const t = result.timings;
    status.last = {
      kind, promptTokens: result.usage?.prompt_tokens ?? status.promptTotal, cached: t.cache_n ?? status.promptCached,
      prefillTps: Math.round((t.prompt_per_second ?? 0) * 10) / 10, genTokens: t.predicted_n ?? status.genTokens,
      genTps: Math.round((t.predicted_per_second ?? 0) * 10) / 10, durationMs: Date.now() - status.startedAt, endedAt: Date.now(),
    };
    return result;
  } finally {
    status.phase = "idle";
    status.startedAt = 0;
  }
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map((p: any) => p?.text ?? "").join(" ");
  return "";
}

function localTitle(body: any, stream: boolean): Response {
  const users = (body.messages ?? []).filter((m: any) => m.role === "user");
  const raw = textOf(users.at(-1)?.content)
    .replace(/<[^>]+>/g, " ")
    .replace(/^.*?generate a title for this conversation:?/is, "")
    .replace(/\s+/g, " ")
    .trim();
  const words = raw.split(" ").slice(0, 7).join(" ");
  const title = (words.length > 50 ? words.slice(0, 50) : words) || "Notch task";
  const base = { id: "title-" + Date.now(), created: Math.floor(Date.now() / 1000), model: body.model };
  const usage = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 };
  if (!stream) {
    return Response.json({ ...base, object: "chat.completion", usage,
      choices: [{ index: 0, message: { role: "assistant", content: title }, finish_reason: "stop" }] });
  }
  const chunk = { ...base, object: "chat.completion.chunk" };
  const out =
    sse({ ...chunk, choices: [{ index: 0, delta: { role: "assistant", content: title }, finish_reason: null }] }) +
    sse({ ...chunk, choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage }) +
    "data: [DONE]\n\n";
  return new Response(out, { headers: { "content-type": "text/event-stream" } });
}

async function chat(req: Request): Promise<Response> {
  const body = await req.json();
  if (process.env.DUMP_DIR) await Bun.write(`${process.env.DUMP_DIR}/last-request.json`, JSON.stringify(body, null, 2));
  const wantStream = !!body.stream;

  // llama-server runs a single slot; opencode's title request would evict the cached agent
  // prompt and force a full re-prefill on the next turn. Answer it locally instead.
  const system = (body.messages ?? []).filter((m: any) => m.role === "system").map((m: any) => String(m.content)).join("\n");
  if (system.includes("You are a title generator")) return localTitle(body, wantStream);

  const hasTools = Array.isArray(body.tools) && body.tools.length > 0;
  const upstreamBody = {
    ...body,
    stream: false,
    stop: [...(Array.isArray(body.stop) ? body.stop : body.stop ? [body.stop] : []), "<|tool_response>"],
  };
  delete upstreamBody.stream_options;
  const kind = hasTools ? "agent" : body.grammar ? "decision" : "chat";
  const res = await callUpstream(upstreamBody, req.signal, kind);
  if (res instanceof Response) return res;
  const t = res.timings ?? {};
  console.log(
    `[${kind}] msgs=${body.messages?.length} tools=${body.tools?.length ?? 0} prompt=${res.usage?.prompt_tokens} ` +
    `cached=${t.cache_n ?? 0} prefill=${Math.round(t.prompt_ms ?? 0)}ms gen=${res.usage?.completion_tokens}tok/${Math.round(t.predicted_ms ?? 0)}ms`,
  );
  const data: any = {
    id: res.id, object: "chat.completion", created: res.created, model: res.model, usage: res.usage, timings: res.timings,
  };
  const { content, reasoning, toolCalls } = splitContent(res.content);
  const calls = hasTools ? toolCalls : [];
  for (const call of calls) {
    const tool = body.tools.find((t: any) => t.function?.name === call.function.name);
    if (!tool) continue;
    const before = call.function.arguments;
    call.function.arguments = JSON.stringify(repairArgs(JSON.parse(before), tool.function.parameters));
    if (call.function.arguments !== before) console.log(`[repair] ${call.function.name}: ${before} -> ${call.function.arguments}`);
  }
  const finish = calls.length ? "tool_calls" : res.finish;
  const message: any = { role: "assistant", content: content || (calls.length ? null : "") };
  if (reasoning) message.reasoning_content = reasoning;
  if (calls.length) message.tool_calls = calls;

  if (!wantStream) {
    return Response.json({ ...data, choices: [{ index: 0, message, finish_reason: finish }] });
  }
  const base = { id: data.id, object: "chat.completion.chunk", created: data.created, model: data.model };
  let out = sse({ ...base, choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] });
  if (reasoning) out += sse({ ...base, choices: [{ index: 0, delta: { reasoning_content: reasoning }, finish_reason: null }] });
  if (content) out += sse({ ...base, choices: [{ index: 0, delta: { content }, finish_reason: null }] });
  calls.forEach((c, index) => {
    out += sse({ ...base, choices: [{ index: 0, delta: { tool_calls: [{ index, ...c }] }, finish_reason: null }] });
  });
  out += sse({ ...base, choices: [{ index: 0, delta: {}, finish_reason: finish }], usage: data.usage });
  out += "data: [DONE]\n\n";
  return new Response(out, { headers: { "content-type": "text/event-stream", "cache-control": "no-cache" } });
}

if (import.meta.main) {
  Bun.serve({
    port: PORT,
    hostname: "127.0.0.1",
    idleTimeout: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/notch/status") return Response.json(statusJSON());
      if (req.method === "POST" && url.pathname.endsWith("/chat/completions")) {
        try { return await chat(req); }
        catch (e) { return Response.json({ error: { message: String(e) } }, { status: 500 }); }
      }
      // Pass everything else (models, health, ...) straight through.
      return fetch(`${UPSTREAM}${url.pathname}${url.search}`, {
        method: req.method, headers: req.headers, body: req.method === "GET" ? undefined : await req.arrayBuffer(),
      });
    },
  });
  console.log(`gemma-tools-proxy on http://127.0.0.1:${PORT} -> ${UPSTREAM}`);
}
