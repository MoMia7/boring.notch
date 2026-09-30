//
//  DecisionEngine.swift
//  boringNotch
//
//  Fast typed decisions ("System One"). Uses TypeSafe's Jev when it is configured and
//  reachable; callers that must keep working offline can fall back to the local Gemma
//  model, constrained with a GBNF grammar so it can only answer with valid options.
//

import Defaults
import Foundation
import OSLog
import Security

private let log = Logger(subsystem: "io.otron.notch", category: "decisions")

extension Defaults.Keys {
    static let jevModel = Key<String>("jevModel", default: "jev-latest")
    static let jevInstantActions = Key<Bool>("jevInstantActions", default: true)
    static let jevAmbientNudges = Key<Bool>("jevAmbientNudges", default: true)
    static let jevSmartSuggestions = Key<Bool>("jevSmartSuggestions", default: true)
    static let jevDoneCheck = Key<Bool>("jevDoneCheck", default: true)
}

enum DecisionQuestion {
    /// Probability that the statement is true.
    case noul(String)
    /// Pick one option. Options are (id, description) pairs; ids must be [a-z0-9_]+.
    case choice(String, [(String, String)])
    /// Ordered levels, lowest first (2–10 of them). Answer is 0-based.
    case score(String, [String])
}

struct DecisionAnswer {
    var choice: String?
    var probability: Double?
    var score: Double?
    var confidence: Double
}

enum DecisionSource: String {
    case jev
    case gemma
}

struct DecisionResult {
    let answers: [String: DecisionAnswer]
    let source: DecisionSource
    let latency: TimeInterval

    subscript(_ id: String) -> DecisionAnswer? { answers[id] }
}

enum DecisionFallback {
    /// Give up when Jev is unavailable.
    case none
    /// Ask the local model instead (slow, and evicts the agent's prompt cache).
    case gemma
}

@MainActor
final class DecisionEngine: ObservableObject {
    static let shared = DecisionEngine()

    @Published private(set) var lastJevError: String?
    @Published private(set) var lastJevModel: String?

    private var jevBackoffUntil = Date.distantPast
    private var lastGemmaDecision = Date.distantPast
    private let jevURL = URL(string: "https://api.typesafe.ai/v1/systemone")!

    var hasJevKey: Bool { JevKeychain.load() != nil }
    var jevAvailable: Bool { hasJevKey && Date() >= jevBackoffUntil }

    /// - Parameters:
    ///   - state: JSON-serialisable context sent to Jev. Keep it small and free of private content.
    ///   - localState: richer context used only for the on-device fallback (defaults to `state`).
    ///   - questions: ordered (id, question) pairs.
    ///   - gemmaMinInterval: minimum spacing between local fallbacks.
    func decide(
        state: Any,
        localState: Any? = nil,
        questions: [(String, DecisionQuestion)],
        fallback: DecisionFallback = .none,
        timeout: TimeInterval = 2.5,
        gemmaMinInterval: TimeInterval = 120
    ) async -> DecisionResult? {
        if jevAvailable, let result = await askJev(state: state, questions: questions, timeout: timeout) {
            return result
        }
        guard fallback == .gemma else { return nil }
        // The local model has a single slot; never compete with a running agent turn.
        guard !AgentManager.shared.isBusy,
              Date().timeIntervalSince(lastGemmaDecision) >= gemmaMinInterval else { return nil }
        lastGemmaDecision = Date()
        return await askGemma(state: localState ?? state, questions: questions)
    }

    /// Used by Settings to verify the key.
    func testJev() async -> String {
        guard hasJevKey else { return "No API key saved." }
        jevBackoffUntil = .distantPast
        let result = await askJev(
            state: ["message": "Can you turn the volume down a bit?"],
            questions: [("about_audio", .noul("The message is about sound or volume"))],
            timeout: 5
        )
        if let result, let p = result["about_audio"]?.probability {
            return String(format: "OK · %@ · %.0f ms · p=%.2f", lastJevModel ?? "jev", result.latency * 1000, p)
        }
        return lastJevError ?? "Failed"
    }

    // MARK: - Jev

    private func askJev(state: Any, questions: [(String, DecisionQuestion)], timeout: TimeInterval) async -> DecisionResult? {
        guard let key = JevKeychain.load() else { return nil }
        var qs: [String: Any] = [:]
        for (id, question) in questions {
            switch question {
            case .noul(let instructions):
                qs[id] = ["type": "noul", "instructions": instructions]
            case .choice(let instructions, let options):
                qs[id] = ["type": "choice", "instructions": instructions,
                          "criteria": Dictionary(options, uniquingKeysWith: { a, _ in a })]
            case .score(let instructions, let levels):
                qs[id] = ["type": "score", "instructions": instructions, "criteria": levels]
            }
        }
        let body: [String: Any] = ["state": state, "model": Defaults[.jevModel], "questions": qs]
        var req = URLRequest(url: jevURL)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        let started = Date()
        do {
            let (responseData, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let answers = json["answers"] as? [String: Any] else {
                let text = String(data: responseData, encoding: .utf8) ?? ""
                lastJevError = "HTTP \(status): \(text.prefix(200))"
                log.error("jev failed: \(self.lastJevError ?? "", privacy: .public)")
                // Back off on auth/rate/overload errors so callers go straight to their fallback.
                if [401, 403, 429, 529].contains(status) || status >= 500 {
                    jevBackoffUntil = Date().addingTimeInterval(status == 429 ? 20 : 60)
                }
                return nil
            }
            lastJevError = nil
            lastJevModel = json["model"] as? String
            var parsed: [String: DecisionAnswer] = [:]
            for (id, question) in questions {
                guard let raw = answers[id] as? [String: Any] else { continue }
                parsed[id] = Self.parseJevAnswer(raw, question: question)
            }
            return DecisionResult(answers: parsed, source: .jev, latency: Date().timeIntervalSince(started))
        } catch {
            lastJevError = error.localizedDescription
            log.error("jev request error: \(error.localizedDescription, privacy: .public)")
            jevBackoffUntil = Date().addingTimeInterval(30)
            return nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseJevAnswer(_ raw: [String: Any], question: DecisionQuestion) -> DecisionAnswer {
        let confidence = number(raw["confidence"]) ?? 1
        switch question {
        case .noul:
            let p = number(raw["noul"]) ?? number(raw["probability"]) ?? number(raw["value"]) ?? 0
            return DecisionAnswer(probability: p, confidence: max(p, 1 - p))
        case .choice:
            return DecisionAnswer(choice: raw["choice"] as? String, confidence: confidence)
        case .score:
            return DecisionAnswer(score: number(raw["score"]), confidence: confidence)
        }
    }

    // MARK: - Gemma fallback

    private func askGemma(state: Any, questions: [(String, DecisionQuestion)]) async -> DecisionResult? {
        let stateText: String = {
            if let s = state as? String { return s }
            guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return "\(state)" }
            return String(data: data, encoding: .utf8) ?? ""
        }()

        var lines: [String] = []
        var grammar: [String] = []
        for (index, (id, question)) in questions.enumerated() {
            switch question {
            case .noul(let instructions):
                lines.append("\(index + 1). \(id) (yes or no): \(instructions)")
                grammar.append("\"\(id)=\" (\"yes\" | \"no\")")
            case .choice(let instructions, let options):
                let described = options.map { "   - \($0.0): \($0.1)" }.joined(separator: "\n")
                lines.append("\(index + 1). \(id) (pick one id): \(instructions)\n\(described)")
                grammar.append("\"\(id)=\" (" + options.map { "\"\($0.0)\"" }.joined(separator: " | ") + ")")
            case .score(let instructions, let levels):
                let described = levels.enumerated().map { "   \($0.offset): \($0.element)" }.joined(separator: "\n")
                lines.append("\(index + 1). \(id) (level number): \(instructions)\n\(described)")
                grammar.append("\"\(id)=\" (" + levels.indices.map { "\"\($0)\"" }.joined(separator: " | ") + ")")
            }
        }
        let prompt = """
        Decide the questions below about this state. Read the state literally.

        STATE:
        \(stateText)

        QUESTIONS:
        \(lines.joined(separator: "\n"))

        Answer one line per question as id=answer.
        """
        let body: [String: Any] = [
            "model": "gemma-4-26b",
            "temperature": 0,
            "max_tokens": 16 * questions.count + 16,
            "messages": [["role": "user", "content": prompt]],
            "grammar": "root ::= " + grammar.joined(separator: " \"\\n\" "),
        ]
        guard let url = URL(string: Defaults[.agentModelURL] + "/v1/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 240  // the model may need to wake up
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let started = Date()
        guard let (responseData, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else { return nil }

        var values: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        var parsed: [String: DecisionAnswer] = [:]
        for (id, question) in questions {
            guard let value = values[id] else { continue }
            switch question {
            case .noul:
                // No calibrated probability locally; treat a "yes" as fairly confident.
                parsed[id] = DecisionAnswer(probability: value == "yes" ? 0.8 : 0.2, confidence: 0.6)
            case .choice:
                parsed[id] = DecisionAnswer(choice: value, confidence: 0.6)
            case .score:
                parsed[id] = DecisionAnswer(score: Double(value), confidence: 0.6)
            }
        }
        return DecisionResult(answers: parsed, source: .gemma, latency: Date().timeIntervalSince(started))
    }
}

// MARK: - Keychain

enum JevKeychain {
    private static let service = "io.otron.notch.jev"
    private static let account = "api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
