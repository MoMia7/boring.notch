// Run with: bun test agent/local-gemma
import { describe, expect, test } from "bun:test";
import { parseGemmaArgs, repairArgs, splitContent, TextStreamer } from "./proxy.ts";

const bashSchema = {
  type: "object",
  properties: { command: { type: "string" }, description: { type: "string" }, timeout: { type: "number" }, workdir: { type: "string" } },
  required: ["command", "description"],
};

describe("parseGemmaArgs", () => {
  test("Gemma string quoting and numbers", () => {
    expect(parseGemmaArgs('{city:<|"|>Paris<|"|>,days:3}')).toEqual({ city: "Paris", days: 3 });
  });
  test("nested objects, arrays and booleans", () => {
    expect(parseGemmaArgs('{a:{b:[1,<|"|>x<|"|>,true]},c:null}')).toEqual({ a: { b: [1, "x", true] }, c: null });
  });
});

describe("splitContent", () => {
  test("extracts a tool call and strips control tokens", () => {
    const r = splitContent('<|tool_call>call:bash{command:<|"|>ls<|"|>}<tool_call|><|tool_response>');
    expect(r.toolCalls).toHaveLength(1);
    expect(r.toolCalls[0].function.name).toBe("bash");
    expect(JSON.parse(r.toolCalls[0].function.arguments)).toEqual({ command: "ls" });
    expect(r.content).toBe("");
  });
  test("separates thinking from the answer", () => {
    const r = splitContent("<|channel>thought\nhmm<channel|>The answer is 4.");
    expect(r.reasoning).toBe("hmm");
    expect(r.content).toBe("The answer is 4.");
  });
});

describe("repairArgs", () => {
  test("misspelled keys snap to the schema", () => {
    for (const bad of ["descrptio", "descrption", "descrpt", "descr"]) {
      expect(repairArgs({ command: "df -h /", [bad]: "x" }, bashSchema)).toEqual({ command: "df -h /", description: "x" });
    }
    expect(repairArgs({ command: "ls", timout: 5 }, bashSchema)).toMatchObject({ timeout: 5 });
    expect(repairArgs({ command: "ls", workdirectory: "/tmp" }, bashSchema)).toMatchObject({ workdir: "/tmp" });
  });
  test("missing required strings are filled", () => {
    expect(repairArgs({ command: "ls" }, bashSchema)).toEqual({ command: "ls", description: "Run command" });
  });
});

describe("TextStreamer", () => {
  const run = (chunks: string[]) => {
    const out: string[] = [];
    const s = new TextStreamer((t) => out.push(t));
    chunks.forEach((c) => s.push(c));
    s.finish();
    return out.join("");
  };
  test("plain text streams through", () => {
    expect(run(["You have ", "146 GiB", " free."])).toBe("You have 146 GiB free.");
  });
  test("stops at a tool call, even when the marker is split across chunks", () => {
    expect(run(["Checking", " now.<", "|tool_", "call>call:bash{command:<|\"|>df<|\"|>}"])).toBe("Checking now.");
  });
  test("a lone '<' that isn't a marker is kept", () => {
    expect(run(["a < b", " and c"])).toBe("a < b and c");
  });
  test("leading whitespace is trimmed", () => {
    expect(run(["\n  Hello"])).toBe("Hello");
  });
});
