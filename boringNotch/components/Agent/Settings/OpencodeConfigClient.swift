//
//  OpencodeConfigClient.swift
//  boringNotch
//
//  Configuration side of the local `opencode serve` harness: health, providers,
//  models, credentials and OAuth logins. Everything goes through opencode's HTTP
//  API because the sandboxed app can't touch opencode.json or run the CLI.
//
//  Notes on opencode 1.14.x behaviour (verified against the live server):
//  - PATCH /config writes <workspace>/config.json, which opencode never reads back,
//    and PATCH /global/config would change the user's own opencode setup. So the
//    notch's model choice lives in the app (Defaults[.agentModelOverride]) and is
//    sent with every prompt; empty means the workspace default (local Gemma).
//  - PUT/DELETE /auth/{id} update auth.json; provider lists are cached per
//    instance, so we POST /global/dispose afterwards to reload them.
//

import AppKit
import Defaults
import Foundation

extension Defaults.Keys {
    /// "provider/model" sent with each prompt; empty uses the workspace default.
    static let agentModelOverride = Key<String>("agentModelOverride", default: "")
}

struct OpencodeModel: Identifiable, Hashable {
    let id: String
    let name: String
}

struct OpencodeProvider: Identifiable, Hashable {
    let id: String
    let name: String
    /// "env", "config", "custom" or "api" (credential stored in auth.json).
    let source: String
    let env: [String]
    let models: [OpencodeModel]
    let usesOAuth: Bool
}

struct OpencodeAuthPrompt: Hashable {
    struct Option: Hashable {
        let label: String
        let value: String
        let hint: String?
    }

    let type: String  // "text" or "select"
    let key: String
    let message: String
    let placeholder: String?
    let options: [Option]
    let whenKey: String?
    let whenOp: String?
    let whenValue: String?

    func isVisible(_ inputs: [String: String]) -> Bool {
        guard let whenKey, let whenValue else { return true }
        let current = inputs[whenKey] ?? ""
        return whenOp == "neq" ? current != whenValue : current == whenValue
    }
}

struct OpencodeAuthMethod: Hashable {
    /// Position in the provider's method list; the server addresses methods by index.
    let index: Int
    let type: String  // "oauth" or "api"
    let label: String
    let prompts: [OpencodeAuthPrompt]
}

struct OpencodeAuthorization {
    let url: String
    let method: String  // "auto" or "code"
    let instructions: String
}

enum OpencodeHealth: Equatable {
    case unknown
    case healthy(String)
    case unreachable
}

@MainActor
final class OpencodeConfigClient: ObservableObject {
    static let shared = OpencodeConfigClient()

    static let localProviderID = "local"
    static let oauthDummyKey = "opencode-oauth-dummy-key"

    @Published private(set) var health: OpencodeHealth = .unknown
    /// Providers opencode can currently use (GET /config/providers).
    @Published private(set) var connected: [OpencodeProvider] = []
    /// Every provider opencode knows about (GET /provider), for connecting new ones.
    @Published private(set) var allProviders: [OpencodeProvider] = []
    @Published private(set) var authMethods: [String: [OpencodeAuthMethod]] = [:]
    @Published private(set) var defaultAgent = "notch"
    /// Model the default agent uses, as "provider/model".
    @Published private(set) var activeModel = ""
    /// Model used for titles and summaries, as "provider/model".
    @Published private(set) var smallModel = ""
    /// The workspace's own default (opencode.json `model`), i.e. local Gemma.
    @Published private(set) var workspaceModel = ""
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private init() {}

    private var baseURL: String {
        let raw = Defaults[.agentServerURL].trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: - Loading

    func refreshHealth() async {
        guard let data = try? await request("GET", "/global/health", timeout: 3),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["healthy"] as? Bool == true else {
            health = .unreachable
            return
        }
        health = .healthy(obj["version"] as? String ?? "")
    }

    func reload(includeCatalog: Bool = true) async {
        isLoading = true
        defer { isLoading = false }
        await refreshHealth()
        guard case .healthy = health else { return }
        do {
            async let configData = request("GET", "/config")
            async let agentData = request("GET", "/agent")
            async let providersData = request("GET", "/config/providers", timeout: 30)
            async let authData = request("GET", "/provider/auth")

            let config = try JSONSerialization.jsonObject(with: try await configData) as? [String: Any] ?? [:]
            let agents = try JSONSerialization.jsonObject(with: try await agentData) as? [[String: Any]] ?? []
            defaultAgent = config["default_agent"] as? String ?? "notch"
            workspaceModel = config["model"] as? String ?? ""
            let override = Defaults[.agentModelOverride]
            activeModel = override.isEmpty ? (Self.agentModel(named: defaultAgent, in: agents) ?? workspaceModel) : override
            smallModel = config["small_model"] as? String ?? workspaceModel

            let providers = try await providersData
            connected = await Task.detached { Self.parseProviders(providers, key: "providers") }.value
                .sorted(by: Self.providerOrder)
            authMethods = Self.parseAuthMethods(try await authData)
            lastError = nil

            // A saved choice can disappear when opencode refreshes its model catalog.
            if !override.isEmpty {
                let (providerID, modelID) = Self.split(override)
                if !(connected.first { $0.id == providerID }?.models.contains { $0.id == modelID } ?? false) {
                    Defaults[.agentModelOverride] = ""
                    activeModel = workspaceModel
                    lastError = "“\(override)” is no longer available, so the agent is back on \(workspaceModel). Pick another model below."
                }
            }
        } catch {
            lastError = "Couldn't load opencode settings: \(error.localizedDescription)"
        }
        if includeCatalog || allProviders.isEmpty {
            // ~6 MB (models.dev catalog); parse off the main actor.
            if let data = try? await request("GET", "/provider", timeout: 60) {
                allProviders = await Task.detached { Self.parseProviders(data, key: "all") }.value
                    .sorted(by: Self.providerOrder)
            }
        }
    }

    // MARK: - Models

    /// Sets the model the notch agent uses. Stored in the app and sent with each prompt,
    /// so the user's own opencode configuration is never modified.
    func setActiveModel(_ model: String) async {
        Defaults[.agentModelOverride] = model == workspaceModel ? "" : model
        activeModel = model
    }

    // MARK: - Credentials

    /// Stores an API key (plus any provider-specific fields) in opencode's auth store.
    func setAPIKey(_ key: String, for providerID: String, metadata: [String: String] = [:]) async -> Bool {
        var body: [String: Any] = ["type": "api", "key": key.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !metadata.isEmpty { body["metadata"] = metadata }
        do {
            try await request("PUT", "/auth/\(Self.escape(providerID))", body: body)
            await applyAuthChange()
            return true
        } catch {
            lastError = "Couldn't save the key: \(error.localizedDescription)"
            return false
        }
    }

    func removeAuth(for providerID: String) async {
        do {
            try await request("DELETE", "/auth/\(Self.escape(providerID))")
            await applyAuthChange()
        } catch {
            lastError = "Couldn't remove credentials: \(error.localizedDescription)"
        }
    }

    /// Starts an OAuth flow. For "auto" flows opencode itself receives the redirect
    /// (or polls the device endpoint), so the caller should then `finishOAuth` without a code.
    func startOAuth(providerID: String, method: Int, inputs: [String: String]) async throws -> OpencodeAuthorization {
        var body: [String: Any] = ["method": method]
        if !inputs.isEmpty { body["inputs"] = inputs }
        let data = try await request("POST", "/provider/\(Self.escape(providerID))/oauth/authorize", body: body, timeout: 60)
        guard let obj = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any],
              let url = obj["url"] as? String else {
            throw OpencodeError.message("This login method didn't return an authorization URL.")
        }
        return OpencodeAuthorization(url: url,
                                     method: obj["method"] as? String ?? "auto",
                                     instructions: obj["instructions"] as? String ?? "")
    }

    /// Completes an OAuth flow. For "auto" this blocks until the user finishes in the browser.
    func finishOAuth(providerID: String, method: Int, code: String?) async throws {
        var body: [String: Any] = ["method": method]
        if let code, !code.isEmpty { body["code"] = code.trimmingCharacters(in: .whitespacesAndNewlines) }
        try await request("POST", "/provider/\(Self.escape(providerID))/oauth/callback", body: body, timeout: 600)
        await applyAuthChange()
    }

    private func applyAuthChange() async {
        // Provider state is cached per instance; dispose so the new credentials are picked up.
        _ = try? await request("POST", "/global/dispose")
        await reload(includeCatalog: true)
    }

    // MARK: - Helpers

    func provider(_ id: String) -> OpencodeProvider? {
        connected.first { $0.id == id } ?? allProviders.first { $0.id == id }
    }

    func isConnected(_ id: String) -> Bool { connected.contains { $0.id == id } }

    func methods(for providerID: String) -> [OpencodeAuthMethod] {
        if let methods = authMethods[providerID], !methods.isEmpty { return methods }
        return [OpencodeAuthMethod(index: 0, type: "api", label: "API key", prompts: [])]
    }

    func displayName(for model: String) -> String {
        let (providerID, modelID) = Self.split(model)
        guard let provider = provider(providerID) else { return model }
        let modelName = provider.models.first { $0.id == modelID }?.name ?? modelID
        return "\(provider.name) · \(modelName)"
    }

    nonisolated static func split(_ model: String) -> (String, String) {
        guard let slash = model.firstIndex(of: "/") else { return (model, "") }
        return (String(model[..<slash]), String(model[model.index(after: slash)...]))
    }

    private nonisolated static func agentModel(named name: String, in agents: [[String: Any]]) -> String? {
        guard let agent = agents.first(where: { $0["name"] as? String == name }),
              let model = agent["model"] as? [String: Any],
              let providerID = model["providerID"] as? String,
              let modelID = model["modelID"] as? String else { return nil }
        return "\(providerID)/\(modelID)"
    }

    private nonisolated static func providerOrder(_ a: OpencodeProvider, _ b: OpencodeProvider) -> Bool {
        let pinned = [localProviderID, "openai", "anthropic", "github-copilot", "google", "openrouter"]
        let ia = pinned.firstIndex(of: a.id) ?? Int.max
        let ib = pinned.firstIndex(of: b.id) ?? Int.max
        if ia != ib { return ia < ib }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private nonisolated static func parseProviders(_ data: Data, key: String) -> [OpencodeProvider] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj[key] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let modelsObj = entry["models"] as? [String: [String: Any]] ?? [:]
            let models = modelsObj.compactMap { modelID, model -> OpencodeModel? in
                if (model["status"] as? String) == "deprecated" { return nil }
                return OpencodeModel(id: modelID, name: model["name"] as? String ?? modelID)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            // Only compare against the placeholder; the key itself is never kept.
            let options = entry["options"] as? [String: Any] ?? [:]
            let usesOAuth = (entry["key"] as? String) == oauthDummyKey || (options["apiKey"] as? String) == oauthDummyKey
            return OpencodeProvider(id: id,
                                    name: entry["name"] as? String ?? id,
                                    source: entry["source"] as? String ?? "",
                                    env: entry["env"] as? [String] ?? [],
                                    models: models,
                                    usesOAuth: usesOAuth)
        }
    }

    private nonisolated static func parseAuthMethods(_ data: Data) -> [String: [OpencodeAuthMethod]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else { return [:] }
        return obj.mapValues { methods in
            methods.enumerated().map { index, method in
                let prompts = (method["prompts"] as? [[String: Any]] ?? []).compactMap { prompt -> OpencodeAuthPrompt? in
                    guard let key = prompt["key"] as? String else { return nil }
                    let when = prompt["when"] as? [String: Any]
                    let options = (prompt["options"] as? [[String: Any]] ?? []).compactMap { option -> OpencodeAuthPrompt.Option? in
                        guard let value = option["value"] as? String else { return nil }
                        return .init(label: option["label"] as? String ?? value, value: value, hint: option["hint"] as? String)
                    }
                    return OpencodeAuthPrompt(type: prompt["type"] as? String ?? "text",
                                              key: key,
                                              message: prompt["message"] as? String ?? key,
                                              placeholder: prompt["placeholder"] as? String,
                                              options: options,
                                              whenKey: when?["key"] as? String,
                                              whenOp: when?["op"] as? String,
                                              whenValue: when?["value"] as? String)
                }
                return OpencodeAuthMethod(index: index,
                                          type: method["type"] as? String ?? "api",
                                          label: method["label"] as? String ?? "Log in",
                                          prompts: prompts)
            }
        }
    }

    private nonisolated static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    @discardableResult
    private func request(_ method: String, _ path: String, body: Any? = nil, timeout: TimeInterval = 15) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpencodeError.from(data)
        }
        return data
    }
}

enum OpencodeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }

    /// Extracts opencode's `{name, data: {message}}` error body when there is one.
    static func from(_ data: Data) -> OpencodeError {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let inner = obj["data"] as? [String: Any]
            if let message = inner?["message"] as? String ?? obj["message"] as? String { return .message(message) }
            if let name = obj["name"] as? String { return .message(name) }
        }
        return .message("The agent server rejected the request.")
    }
}
