//
//  AgentManager.swift
//  boringNotch
//
//  Talks to a local `opencode serve` instance (the agent harness) over HTTP + SSE.
//  The harness itself runs as a launchd agent outside the app sandbox, so the app
//  only needs the network client entitlement.
//

import AppKit
import Defaults
import Foundation

extension Defaults.Keys {
    static let agentServerURL = Key<String>("agentServerURL", default: "http://127.0.0.1:4096")
    static let agentSessionID = Key<String>("agentSessionID", default: "")
    static let agentModelURL = Key<String>("agentModelURL", default: "http://127.0.0.1:8081")
}

extension Notification.Name {
    static let agentNeedsAttention = Notification.Name("agentNeedsAttention")
    /// A request made without looking at the notch (e.g. by voice) finished; userInfo["dwell"] is seconds to show it.
    static let agentShowResult = Notification.Name("agentShowResult")
}

struct AgentItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case tool(name: String, status: String)
        case quick(icon: String)
        case error
    }

    let id: String
    var kind: Kind
    var text: String
    var callID: String? = nil
}

struct AgentPermission: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let permission: String
    let patterns: [String]
    let callID: String?
}

enum AgentModelState: Equatable {
    case unknown
    case ready(String)
    case asleep(String)
    /// A hosted model selected in Settings; the local server's state doesn't matter.
    case cloud(provider: String, model: String)
    case unreachable
}

/// Live model state reported by the gemma-tools-proxy at GET /notch/status.
struct ModelLiveStatus: Decodable, Equatable {
    struct LastRun: Decodable, Equatable {
        let kind: String
        let promptTokens: Int
        let cached: Int
        let prefillTps: Double
        let genTokens: Int
        let genTps: Double
        let durationMs: Double
        let endedAt: Double
    }

    let phase: String            // idle | waking | prefill | generating
    let kind: String
    let promptTotal: Int
    let promptCached: Int
    let promptProcessed: Int
    let prefillTps: Double
    let genTokens: Int
    let genTps: Double
    let elapsedMs: Double
    let last: LastRun?
}

struct AgentRetry: Equatable {
    let attempt: Int
    let message: String
    let next: Date?
}

/// Shown when the done-check thinks a finished task didn't actually get done.
struct AgentFollowUp: Equatable {
    enum Kind: String { case failed, incomplete, looping }
    let kind: Kind
    let itemID: String
    let request: String
}

/// Stats shown under a finished answer.
struct AgentRunSummary: Equatable {
    let duration: TimeInterval
    let steps: Int
    let tools: Int
    let genTokens: Int
    let genTps: Double?
}

enum AgentConnection: Equatable {
    case connecting
    case connected
    case offline(String)
}

@MainActor
final class AgentManager: ObservableObject {
    static let shared = AgentManager()

    @Published private(set) var items: [AgentItem] = []
    @Published private(set) var permissions: [AgentPermission] = []
    @Published private(set) var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            isBusy ? beginTask() : finishTask()
        }
    }
    @Published private(set) var connection: AgentConnection = .connecting
    @Published private(set) var sessionTitle = ""
    @Published private(set) var modelState: AgentModelState = .unknown

    // Live activity for the current task.
    @Published private(set) var taskStartedAt: Date?
    @Published private(set) var stepCount = 0
    @Published private(set) var retry: AgentRetry?
    @Published private(set) var modelStatus: ModelLiveStatus?
    @Published private(set) var toolStartedAt: [String: Date] = [:]
    /// Keyed by the id of the last assistant item of each finished task.
    @Published private(set) var runSummaries: [String: AgentRunSummary] = [:]
    @Published private(set) var followUp: AgentFollowUp?
    /// Brief result of an instant action shown inside the closed notch.
    @Published private(set) var quickResult: (id: UUID, icon: String, label: String)?
    private var quickResultTask: Task<Void, Never>?
    /// True while a spoken request is being routed (keeps the listening strip up, avoiding a flicker).
    @Published private(set) var isRoutingVoice = false

    private var taskToolIDs: Set<String> = []
    private var taskGenTokens = 0
    private var taskGenSeconds: Double = 0
    private var lastCountedRun: Double = 0
    private var statusTask: Task<Void, Never>?
    private var showResultWhenDone = false
    /// Last time a request was sent or finished; after a long gap we start a fresh
    /// conversation so the model doesn't re-read an ever-growing history.
    private var lastActivityAt = Date()
    private static let freshSessionAfter: TimeInterval = 10 * 60

    private var sessionID: String = Defaults[.agentSessionID]
    private var roles: [String: String] = [:]  // messageID -> role
    private var eventTask: Task<Void, Never>?
    private var holdingNotch = false

    private var baseURL: URL { URL(string: Defaults[.agentServerURL]) ?? URL(string: "http://127.0.0.1:4096")! }

    private init() {
        start()
    }

    // MARK: - Public actions

    func start() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in await self?.runEventLoop() }
    }

    /// - Parameter showResult: pop the notch open with the outcome when done (for requests
    ///   made without the notch open, like push-to-talk).
    func send(_ text: String, showResult: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            followUp = nil
            // Simple requests ("mute", "open Slack") are handled instantly without the LLM.
            if showResult { isRoutingVoice = true }
            let quick = await QuickActions.shared.tryHandle(trimmed)
            isRoutingVoice = false
            if let quick {
                items.append(AgentItem(id: UUID().uuidString, kind: .user, text: trimmed))
                items.append(AgentItem(id: UUID().uuidString, kind: .quick(icon: quick.icon), text: quick.label))
                if showResult { flashResult(icon: quick.icon, label: quick.label) }
                return
            }
            showResultWhenDone = showResult
            do {
                let idle = Date().timeIntervalSince(lastActivityAt) > Self.freshSessionAfter
                if sessionID.isEmpty || (idle && !items.isEmpty && !isBusy && permissions.isEmpty) {
                    try await createSession()
                }
                lastActivityAt = Date()
                isBusy = true
                var body: [String: Any] = ["parts": [["type": "text", "text": trimmed]]]
                let override = Defaults[.agentModelOverride]
                if let slash = override.firstIndex(of: "/") {
                    body["model"] = ["providerID": String(override[..<slash]),
                                     "modelID": String(override[override.index(after: slash)...])]
                }
                _ = try await request("POST", "/session/\(sessionID)/prompt_async", body: body)
            } catch {
                isBusy = false
                appendError("Couldn't reach the agent: \(error.localizedDescription)")
                if showResult { showResultWhenDone = false; announceResult(dwell: 6) }
            }
        }
    }

    /// Runs a fixed command through the harness without involving the model.
    func runShell(_ command: String) async {
        do {
            if sessionID.isEmpty { try await createSession() }
            _ = try await request("POST", "/session/\(sessionID)/shell", body: ["agent": "notch", "command": command])
        } catch {
            appendError("Command failed: \(error.localizedDescription)")
        }
    }

    func abort() {
        guard !sessionID.isEmpty else { return }
        Task { _ = try? await request("POST", "/session/\(sessionID)/abort") }
    }

    func newSession() {
        Task {
            if isBusy { abort() }
            try? await createSession()
        }
    }

    /// reply: "once", "always" or "reject"
    func reply(to permission: AgentPermission, with reply: String) {
        permissions.removeAll { $0.id == permission.id }
        updateNotchHold()
        Task {
            _ = try? await request("POST", "/permission/\(permission.id)/reply", body: ["reply": reply])
        }
    }

    func command(for permission: AgentPermission) -> String {
        if let callID = permission.callID,
           let item = items.last(where: { $0.callID == callID }), !item.text.isEmpty {
            return item.text
        }
        let joined = permission.patterns.joined(separator: " | ")
        return joined.isEmpty ? permission.permission : joined
    }

    /// Asks llama-server (through the proxy) whether the model is loaded.
    func refreshModelState() {
        let override = Defaults[.agentModelOverride]
        if let slash = override.firstIndex(of: "/"), override[..<slash] != "local" {
            modelState = .cloud(provider: String(override[..<slash]), model: String(override[override.index(after: slash)...]))
            return
        }
        Task {
            guard let url = URL(string: Defaults[.agentModelURL] + "/props") else { return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let props = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                modelState = .unreachable
                return
            }
            let name = (props["model_alias"] as? String) ?? "Local model"
            modelState = (props["is_sleeping"] as? Bool) == true ? .asleep(name) : .ready(name)
        }
    }

    // MARK: - Activity

    var runningTool: AgentItem? {
        items.last {
            if case .tool(_, let status) = $0.kind { return status == "running" || status == "pending" }
            return false
        }
    }

    private func beginTask() {
        if taskStartedAt == nil { taskStartedAt = Date() }
        stepCount = 0
        retry = nil
        taskToolIDs = []
        taskGenTokens = 0
        taskGenSeconds = 0
        lastCountedRun = Date().timeIntervalSince1970 * 1000
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollModelStatus()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func finishTask() {
        lastActivityAt = Date()
        statusTask?.cancel()
        statusTask = nil
        Task { await pollModelStatus() }  // pick up the final generation stats
        if let started = taskStartedAt,
           let last = items.last(where: { $0.kind == .assistant }) {
            runSummaries[last.id] = AgentRunSummary(
                duration: Date().timeIntervalSince(started),
                steps: max(stepCount, 1),
                tools: taskToolIDs.count,
                genTokens: taskGenTokens,
                genTps: taskGenSeconds > 0 ? Double(taskGenTokens) / taskGenSeconds : nil
            )
        }
        taskStartedAt = nil
        retry = nil
        modelStatus = nil
        Task { await checkDone() }
        if showResultWhenDone {
            showResultWhenDone = false
            let reply = items.last(where: { $0.kind == .assistant || $0.kind == .error })?.text ?? ""
            announceResult(dwell: min(12, 5 + Double(reply.count) * 0.04))
        }
    }

    func dismissFollowUp() { followUp = nil }

    /// Briefly shows a result inside the closed notch (instant actions, timers).
    func flashResult(icon: String, label: String, duration: TimeInterval = 2.6) {
        let id = UUID()
        quickResult = (id, icon, label)
        quickResultTask?.cancel()
        quickResultTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self?.quickResult?.id == id else { return }
            self?.quickResult = nil
        }
    }

    private func announceResult(dwell: TimeInterval) {
        NotificationCenter.default.post(name: .agentShowResult, object: nil, userInfo: ["dwell": dwell])
    }

    /// Asks Jev whether the last task actually finished. Jev-only; skipped offline.
    private func checkDone() async {
        guard Defaults[.jevDoneCheck], DecisionEngine.shared.jevAvailable,
              let userIndex = items.lastIndex(where: { $0.kind == .user }),
              let reply = items.last(where: { $0.kind == .assistant }),
              let replyIndex = items.firstIndex(of: reply), replyIndex > userIndex else { return }
        let request = items[userIndex].text
        let tools: [[String: String]] = items[userIndex...].compactMap {
            guard case .tool(let name, let status) = $0.kind else { return nil }
            return ["tool": name, "status": status, "input": String($0.text.prefix(160))]
        }
        let state: [String: Any] = [
            "user_request": String(request.prefix(500)),
            "tool_calls": tools,
            "final_reply": String(reply.text.prefix(600)),
        ]
        guard let result = await DecisionEngine.shared.decide(
            state: state,
            questions: [
                ("outcome", .choice("How did the assistant's attempt at the user's request end?", [
                    ("done", "The request was carried out and the reply confirms the result"),
                    ("needs_input", "The assistant asked the user a question or is waiting for confirmation"),
                    ("failed", "A step failed or the reply says it could not do it"),
                    ("incomplete", "The assistant stopped partway without finishing or explaining why"),
                ])),
                ("looping", .noul("The assistant repeated the same tool call several times without making progress")),
            ],
            timeout: 3
        ), items.last?.id == reply.id, !isBusy else { return }

        let outcome = result["outcome"]?.choice ?? "done"
        let confident = (result["outcome"]?.confidence ?? 0) >= 0.7
        if (result["looping"]?.probability ?? 0) >= 0.7 {
            followUp = AgentFollowUp(kind: .looping, itemID: reply.id, request: request)
        } else if confident, let kind = AgentFollowUp.Kind(rawValue: outcome) {
            followUp = AgentFollowUp(kind: kind, itemID: reply.id, request: request)
        }
    }

    private func pollModelStatus() async {
        guard let url = URL(string: Defaults[.agentModelURL] + "/notch/status") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let status = try? JSONDecoder().decode(ModelLiveStatus.self, from: data) else { return }
        if let last = status.last, last.kind == "agent", last.endedAt > lastCountedRun {
            lastCountedRun = last.endedAt
            taskGenTokens += last.genTokens
            if last.genTps > 0 { taskGenSeconds += Double(last.genTokens) / last.genTps }
        }
        if isBusy { modelStatus = status }
    }

    // MARK: - Session

    private func createSession() async throws {
        let data = try await request("POST", "/session", body: [String: Any]())
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { throw URLError(.cannotParseResponse) }
        switchTo(session: id)
    }

    private func switchTo(session id: String) {
        sessionID = id
        Defaults[.agentSessionID] = id
        items = []
        roles = [:]
        permissions = []
        isBusy = false
        sessionTitle = ""
        updateNotchHold()
    }

    private func loadHistory() async {
        if !sessionID.isEmpty,
           let data = try? await request("GET", "/session/\(sessionID)/message"),
           let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var rebuilt: [AgentItem] = []
            roles = [:]
            for message in messages {
                guard let info = message["info"] as? [String: Any],
                      let mid = info["id"] as? String else { continue }
                roles[mid] = info["role"] as? String
                for part in message["parts"] as? [[String: Any]] ?? [] {
                    if let item = makeItem(from: part) { rebuilt.append(item) }
                }
            }
            items = rebuilt
        } else if !sessionID.isEmpty {
            // Session no longer exists on the server.
            switchTo(session: "")
        }

        if let data = try? await request("GET", "/permission"),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            permissions = list.compactMap(makePermission).filter { $0.sessionID == sessionID }
        }
        if !sessionID.isEmpty,
           let data = try? await request("GET", "/session/status"),
           let statuses = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mine = statuses[sessionID] as? [String: Any] {
            isBusy = (mine["type"] as? String) == "busy"
        }
        updateNotchHold()
    }

    // MARK: - Events

    private func runEventLoop() async {
        var delay: UInt64 = 1
        while !Task.isCancelled {
            connection = .connecting
            do {
                var req = URLRequest(url: baseURL.appendingPathComponent("event"))
                req.timeoutInterval = .infinity
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                connection = .connected
                delay = 1
                await loadHistory()
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = payload.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    handle(event)
                }
                throw URLError(.networkConnectionLost)
            } catch {
                connection = .offline("Agent offline – is opencode serve running on \(baseURL.host ?? ""):\(baseURL.port ?? 0)?")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 15)
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String,
              let props = event["properties"] as? [String: Any] else { return }
        let eventSession = (props["sessionID"] as? String)
            ?? ((props["part"] as? [String: Any])?["sessionID"] as? String)
            ?? ((props["info"] as? [String: Any])?["sessionID"] as? String)
        guard eventSession == nil || eventSession == sessionID else { return }

        switch type {
        case "message.updated":
            if let info = props["info"] as? [String: Any], let id = info["id"] as? String {
                roles[id] = info["role"] as? String
                if let error = info["error"] as? [String: Any] {
                    let data = error["data"] as? [String: Any]
                    let message = data?["message"] as? String ?? error["name"] as? String ?? "Unknown error"
                    if (error["name"] as? String) != "MessageAbortedError" { appendError(message) }
                }
            }
        case "message.part.updated":
            guard let part = props["part"] as? [String: Any] else { return }
            if part["type"] as? String == "step-start", isBusy { stepCount += 1 }
            if let item = makeItem(from: part) {
                if case .tool(_, let status) = item.kind {
                    if isBusy { taskToolIDs.insert(item.id) }
                    if status == "running", toolStartedAt[item.id] == nil { toolStartedAt[item.id] = Date() }
                }
                upsert(item)
            }
        case "message.part.delta":
            guard (props["field"] as? String) == "text",
                  let partID = props["partID"] as? String,
                  let delta = props["delta"] as? String else { return }
            if let index = items.firstIndex(where: { $0.id == partID }) {
                items[index].text += delta
            } else {
                let role = roles[props["messageID"] as? String ?? ""]
                items.append(AgentItem(id: partID, kind: role == "user" ? .user : .assistant, text: delta))
            }
        case "session.status":
            let info = props["status"] as? [String: Any]
            let status = info?["type"] as? String
            isBusy = status == "busy" || status == "retry"
            if status == "retry" {
                let next = (info?["next"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                retry = AgentRetry(attempt: info?["attempt"] as? Int ?? 1,
                                   message: info?["message"] as? String ?? "Retrying", next: next)
            } else {
                retry = nil
            }
        case "session.idle":
            isBusy = false
        case "session.updated":
            if let info = props["info"] as? [String: Any], let title = info["title"] as? String {
                sessionTitle = title
            }
        case "session.error":
            if let error = props["error"] as? [String: Any], (error["name"] as? String) != "MessageAbortedError" {
                let data = error["data"] as? [String: Any]
                if (error["name"] as? String)?.contains("ModelNotFound") == true {
                    appendError("The model “\(Defaults[.agentModelOverride])” isn't available. Choose another in Settings → Agent.")
                } else {
                    appendError(data?["message"] as? String ?? error["name"] as? String ?? "Agent error")
                }
                isBusy = false
            }
        case "permission.asked":
            if let permission = makePermission(props), !permissions.contains(where: { $0.id == permission.id }) {
                permissions.append(permission)
                NotificationCenter.default.post(name: .agentNeedsAttention, object: nil)
            }
        case "permission.replied":
            if let requestID = props["requestID"] as? String {
                permissions.removeAll { $0.id == requestID }
            }
        default:
            break
        }
        updateNotchHold()
    }

    private func makeItem(from part: [String: Any]) -> AgentItem? {
        guard let id = part["id"] as? String, let type = part["type"] as? String else { return nil }
        let role = roles[part["messageID"] as? String ?? ""]
        switch type {
        case "text":
            if part["synthetic"] as? Bool == true { return nil }
            let text = part["text"] as? String ?? ""
            return AgentItem(id: id, kind: role == "user" ? .user : .assistant, text: text)
        case "tool":
            let tool = part["tool"] as? String ?? "tool"
            let state = part["state"] as? [String: Any] ?? [:]
            let status = state["status"] as? String ?? "pending"
            let input = state["input"] as? [String: Any] ?? [:]
            var summary = (input["command"] as? String)
                ?? (input["filePath"] as? String)
                ?? (input["url"] as? String)
                ?? (input["pattern"] as? String)
                ?? (state["title"] as? String)
                ?? ""
            if status == "error", let error = state["error"] as? String {
                summary += summary.isEmpty ? error : "\n" + (error.components(separatedBy: "\n").first ?? error)
            }
            return AgentItem(id: id, kind: .tool(name: tool, status: status), text: summary,
                             callID: part["callID"] as? String)
        default:
            return nil
        }
    }

    private func makePermission(_ props: [String: Any]) -> AgentPermission? {
        guard let id = props["id"] as? String, let session = props["sessionID"] as? String else { return nil }
        return AgentPermission(
            id: id,
            sessionID: session,
            permission: props["permission"] as? String ?? "action",
            patterns: props["patterns"] as? [String] ?? [],
            callID: (props["tool"] as? [String: Any])?["callID"] as? String
        )
    }

    private func upsert(_ item: AgentItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            // Deltas may have already filled in text that a stale part update would erase.
            if item.text.isEmpty, case .assistant = item.kind { return }
            items[index] = item
        } else {
            items.append(item)
        }
    }

    private func appendError(_ message: String) {
        items.append(AgentItem(id: UUID().uuidString, kind: .error, text: message))
    }

    /// Keep the notch open while an approval is waiting for the user.
    private func updateNotchHold() {
        let shouldHold = !permissions.isEmpty
        guard shouldHold != holdingNotch else { return }
        holdingNotch = shouldHold
        if shouldHold {
            SharingStateManager.shared.beginInteraction()
        } else {
            SharingStateManager.shared.endInteraction()
            SharingStateManager.shared.requestCloseIfReady()
        }
    }

    // MARK: - HTTP

    @discardableResult
    private func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        req.httpMethod = method
        req.timeoutInterval = 15
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
