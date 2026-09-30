//
//  AgentSettingsView.swift
//  boringNotch
//
//  Settings pane for the notch agent: connection to `opencode serve`, model and
//  provider selection, provider credentials (API keys and OAuth, e.g. ChatGPT/Codex),
//  and the Jev (TypeSafe) decision engine.
//

import AppKit
import Defaults
import KeyboardShortcuts
import SwiftUI

/// Pages of the Notch Agent settings, each shown as its own sidebar entry.
enum AgentSettingsPage: String, CaseIterable {
    case agent = "Agent"
    case models = "Models"
    case voice = "Voice"
    case jev = "Jev"
    case spotify = "Spotify"

    var icon: String {
        switch self {
        case .agent: return "notch.mark"
        case .models: return "cpu"
        case .voice: return "waveform"
        case .jev: return "bolt.fill"
        case .spotify: return "music.note"
        }
    }
}

struct AgentSettings: View {
    var page: AgentSettingsPage = .agent
    @ObservedObject private var client = OpencodeConfigClient.shared
    @Default(.agentServerURL) private var serverURL
    @State private var connectProviderID = ""

    var body: some View {
        Form {
            switch page {
            case .agent:
                connectionSection
            case .models:
                modelSection
                providersSection
                Section {
                    ProviderAuthForm(providerID: "openai", preferOAuth: true)
                } header: {
                    Text("ChatGPT / Codex")
                } footer: {
                    Text("Log in with a ChatGPT Plus/Pro subscription to use OpenAI models without an API key. This replaces any OpenAI API key stored in opencode.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                connectSection
            case .voice:
                VoiceSettingsSection()
            case .jev:
                JevSettingsSection()
            case .spotify:
                SpotifySettingsSection()
            }
            if page == .agent || page == .models, let error = client.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(page.rawValue)
        .task { await client.reload() }
        .task(id: serverURL) {
            while !Task.isCancelled {
                await client.refreshHealth()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            AgentServerURLField()
            HStack {
                Text("Status")
                Spacer()
                healthLabel
                Button {
                    Task { await client.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(client.isLoading)
                .help("Reload providers and models")
            }
            KeyboardShortcuts.Recorder("Open Agent:", name: .openAgent)
        } header: {
            Text("Connection")
        } footer: {
            Text("The agent tab talks to a local `opencode serve` instance. Restart the app after changing the URL.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var healthLabel: some View {
        switch client.health {
        case .unknown:
            Label("Checking…", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .healthy(let version):
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(version.isEmpty ? "Connected" : "Connected · opencode \(version)")
                    .foregroundStyle(.secondary)
            }
        case .unreachable:
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Unreachable").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            ModelPickerRow(title: "Agent model", model: client.activeModel) { model in
                Task { await client.setActiveModel(model) }
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local (Gemma via llama.cpp)")
                    Text(localModel.isEmpty ? "Not configured in opencode.json" : localModel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if usingLocal {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Use local model") {
                        Task { await client.setActiveModel(localModel) }
                    }
                    .disabled(localModel.isEmpty)
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Applies to the next prompt. Stored in this app only; your own opencode configuration isn't changed.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    /// The workspace default, falling back to the first model of the "local" provider.
    private var localModel: String {
        if OpencodeConfigClient.split(client.workspaceModel).0 == OpencodeConfigClient.localProviderID {
            return client.workspaceModel
        }
        guard let local = client.provider(OpencodeConfigClient.localProviderID), let first = local.models.first else { return "" }
        return "\(local.id)/\(first.id)"
    }

    private var usingLocal: Bool {
        !localModel.isEmpty && client.activeModel == localModel
    }

    // MARK: Providers

    private var providersSection: some View {
        Section {
            if client.connected.isEmpty {
                Text(client.isLoading ? "Loading…" : "No providers available")
                    .foregroundStyle(.secondary)
            }
            ForEach(client.connected) { provider in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                        Text("\(provider.models.count) models")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    customBadge(text: Self.sourceLabel(provider))
                    if provider.source == "api" || provider.usesOAuth {
                        Button("Remove") {
                            Task { await client.removeAuth(for: provider.id) }
                        }
                        .help("Remove the credentials stored in opencode")
                    }
                }
            }
        } header: {
            Text("Connected providers")
        }
    }

    static func sourceLabel(_ provider: OpencodeProvider) -> String {
        if provider.usesOAuth { return "Logged in" }
        switch provider.source {
        case "api": return "API key"
        case "env": return "Environment"
        case "config": return "Config"
        default: return "Built-in"
        }
    }

    // MARK: Connect

    private var connectSection: some View {
        Section {
            Picker("Provider", selection: $connectProviderID) {
                Text("Choose…").tag("")
                ForEach(client.allProviders.filter { $0.id != OpencodeConfigClient.localProviderID }) { provider in
                    Text(client.isConnected(provider.id) ? "\(provider.name) ✓" : provider.name)
                        .tag(provider.id)
                }
            }
            if !connectProviderID.isEmpty {
                ProviderAuthForm(providerID: connectProviderID, preferOAuth: false)
                    .id(connectProviderID)
            }
        } header: {
            Text("Add credentials")
        } footer: {
            Text("Keys are sent to opencode's credential store (auth.json) and are never saved by this app.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

// MARK: - Model picker

private struct ModelPickerRow: View {
    @ObservedObject private var client = OpencodeConfigClient.shared
    let title: String
    let model: String
    let onSelect: (String) -> Void

    @State private var providerID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: $providerID) {
                if client.provider(providerID) == nil {
                    Text(providerID.isEmpty ? "—" : providerID).tag(providerID)
                }
                ForEach(client.connected) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            Picker("", selection: modelBinding) {
                if !currentModelListed {
                    Text(currentModelID.isEmpty ? "Choose a model…" : currentModelID).tag(currentModelID)
                }
                ForEach(client.provider(providerID)?.models ?? []) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .labelsHidden()
            .disabled(providerID.isEmpty)
        }
        .onAppear { syncProvider() }
        .onChange(of: model) { _, _ in syncProvider() }
    }

    /// Model id shown in the second picker: the active one if it belongs to the selected provider.
    private var currentModelID: String {
        let (p, m) = OpencodeConfigClient.split(model)
        return p == providerID ? m : ""
    }

    private var currentModelListed: Bool {
        client.provider(providerID)?.models.contains { $0.id == currentModelID } ?? false
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { currentModelID },
            set: { newValue in
                guard !newValue.isEmpty, "\(providerID)/\(newValue)" != model else { return }
                onSelect("\(providerID)/\(newValue)")
            }
        )
    }

    private func syncProvider() {
        let current = OpencodeConfigClient.split(model).0
        if !current.isEmpty { providerID = current }
    }
}

// MARK: - Provider authentication

/// Credential entry for one provider: API keys and every OAuth method opencode offers.
struct ProviderAuthForm: View {
    @ObservedObject private var client = OpencodeConfigClient.shared
    let providerID: String
    let preferOAuth: Bool

    private enum Phase: Equatable {
        case idle
        case working
        case waitingForBrowser(url: String, instructions: String)
        case needsCode(url: String, instructions: String)
        case done(String)
        case failed(String)
    }

    @State private var methodIndex = -1
    @State private var inputs: [String: String] = [:]
    @State private var apiKey = ""
    @State private var code = ""
    @State private var phase: Phase = .idle
    @State private var flowTask: Task<Void, Never>?

    private var methods: [OpencodeAuthMethod] { client.methods(for: providerID) }

    private var method: OpencodeAuthMethod? {
        methods.first { $0.index == methodIndex } ?? methods.first
    }

    var body: some View {
        Group {
            HStack {
                Text(client.provider(providerID)?.name ?? providerID)
                Spacer()
                if let provider = client.connected.first(where: { $0.id == providerID }) {
                    customBadge(text: provider.usesOAuth ? "Logged in" : "Connected (\(AgentSettings.sourceLabel(provider)))")
                } else {
                    customBadge(text: "Not connected")
                }
            }

            if methods.count > 1 {
                Picker("Method", selection: $methodIndex) {
                    ForEach(methods, id: \.index) { method in
                        Text(method.label).tag(method.index)
                    }
                }
                .onChange(of: methodIndex) { _, _ in resetFlow() }
            }

            if let method {
                ForEach(method.prompts.filter { $0.isVisible(inputs) }, id: \.key) { prompt in
                    promptField(prompt)
                }
                if method.type == "api" {
                    SecureField("API key", text: $apiKey)
                    HStack {
                        Spacer()
                        Button("Save key") { saveKey(method) }
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || phase == .working)
                    }
                } else {
                    oauthControls(method)
                }
            }

            statusView
        }
        .onAppear {
            if methodIndex < 0 {
                let preferred = preferOAuth ? methods.first { $0.type == "oauth" } : methods.first
                methodIndex = preferred?.index ?? 0
            }
        }
        .onDisappear { flowTask?.cancel() }
    }

    @ViewBuilder
    private func promptField(_ prompt: OpencodeAuthPrompt) -> some View {
        if prompt.type == "select" {
            Picker(prompt.message, selection: binding(for: prompt.key, default: prompt.options.first?.value ?? "")) {
                ForEach(prompt.options, id: \.value) { option in
                    Text(option.hint.map { "\(option.label) (\($0))" } ?? option.label).tag(option.value)
                }
            }
        } else {
            TextField(prompt.message, text: binding(for: prompt.key, default: ""), prompt: prompt.placeholder.map { Text($0) })
        }
    }

    private func binding(for key: String, default value: String) -> Binding<String> {
        Binding(
            get: { inputs[key] ?? value },
            set: { inputs[key] = $0 }
        )
    }

    /// Inputs for visible prompts, including select defaults the user didn't touch.
    private func resolvedInputs(_ method: OpencodeAuthMethod) -> [String: String] {
        var result: [String: String] = [:]
        for prompt in method.prompts where prompt.isVisible(inputs) {
            let value = inputs[prompt.key] ?? (prompt.type == "select" ? prompt.options.first?.value ?? "" : "")
            if !value.isEmpty { result[prompt.key] = value }
        }
        return result
    }

    @ViewBuilder
    private func oauthControls(_ method: OpencodeAuthMethod) -> some View {
        switch phase {
        case .waitingForBrowser(let url, let instructions):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(instructions.isEmpty ? "Waiting for you to finish in the browser…" : instructions)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open login page again") { open(url) }
                    Spacer()
                    Button("Cancel") { resetFlow() }
                }
            }
        case .needsCode(let url, let instructions):
            VStack(alignment: .leading, spacing: 6) {
                Text(instructions.isEmpty ? "Paste the authorization code from the browser." : instructions)
                    .textSelection(.enabled)
                TextField("Authorization code", text: $code)
                HStack {
                    Button("Open login page again") { open(url) }
                    Spacer()
                    Button("Cancel") { resetFlow() }
                    Button("Submit") { submitCode(method) }
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        default:
            HStack {
                Spacer()
                Button(method.label.lowercased().hasPrefix("log") ? method.label : "Log in – \(method.label)") {
                    startOAuth(method)
                }
                .disabled(phase == .working)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .working:
            HStack {
                ProgressView().controlSize(.small)
                Text("Working…").foregroundStyle(.secondary)
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    // MARK: Actions

    private func saveKey(_ method: OpencodeAuthMethod) {
        let key = apiKey
        let metadata = resolvedInputs(method)
        phase = .working
        Task {
            let ok = await client.setAPIKey(key, for: providerID, metadata: metadata)
            apiKey = ""
            phase = ok ? .done("Key saved") : .failed(client.lastError ?? "Couldn't save the key")
        }
    }

    private func startOAuth(_ method: OpencodeAuthMethod) {
        flowTask?.cancel()
        let provider = providerID
        let methodIndex = method.index
        let inputs = resolvedInputs(method)
        phase = .working
        flowTask = Task {
            do {
                let auth = try await client.startOAuth(providerID: provider, method: methodIndex, inputs: inputs)
                open(auth.url)
                if auth.method == "code" {
                    phase = .needsCode(url: auth.url, instructions: auth.instructions)
                    return
                }
                phase = .waitingForBrowser(url: auth.url, instructions: auth.instructions)
                try await client.finishOAuth(providerID: provider, method: methodIndex, code: nil)
                guard !Task.isCancelled else { return }
                phase = .done("Logged in")
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed("Login failed: \(error.localizedDescription)")
            }
        }
    }

    private func submitCode(_ method: OpencodeAuthMethod) {
        let provider = providerID
        let methodIndex = method.index
        let value = code
        phase = .working
        flowTask = Task {
            do {
                try await client.finishOAuth(providerID: provider, method: methodIndex, code: value)
                code = ""
                phase = .done("Logged in")
            } catch {
                phase = .failed("Login failed: \(error.localizedDescription)")
            }
        }
    }

    private func resetFlow() {
        flowTask?.cancel()
        flowTask = nil
        code = ""
        phase = .idle
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Jev

private struct JevSettingsSection: View {
    @Default(.jevModel) private var jevModel
    @State private var key = ""
    @State private var hasKey = false
    @State private var saveStatus: String?
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Section {
            HStack {
                SecureField("Jev API key", text: $key, prompt: Text(hasKey ? "Saved in Keychain" : "Not set"))
                Button("Save") {
                    let ok = JevKeychain.save(key)
                    key = ""
                    hasKey = JevKeychain.load() != nil
                    saveStatus = ok ? (hasKey ? "Saved" : "Removed") : "Couldn't save to Keychain"
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasKey {
                    Button("Remove") {
                        JevKeychain.delete()
                        hasKey = false
                        saveStatus = "Removed"
                    }
                }
            }
            if let saveStatus {
                Text(saveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Model", text: $jevModel)
            Defaults.Toggle(key: .jevInstantActions) {
                Text("Instant actions")
            }
            Defaults.Toggle(key: .jevAmbientNudges) {
                Text("Ambient nudges")
            }
            Defaults.Toggle(key: .jevSmartSuggestions) {
                Text("Smart suggestions")
            }
            Defaults.Toggle(key: .jevDoneCheck) {
                Text("Done check")
            }
            HStack {
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
                Button("Test") {
                    isTesting = true
                    testResult = nil
                    Task {
                        testResult = await DecisionEngine.shared.testJev()
                        isTesting = false
                    }
                }
                .disabled(isTesting)
            }
        } header: {
            Text("Jev (TypeSafe) decisions")
        } footer: {
            Text("Jev answers quick yes/no decisions for the notch. The key is stored in your Keychain; without it the local model is used.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .onAppear { hasKey = JevKeychain.load() != nil }
    }
}

/// Push-to-talk settings.
struct VoiceSettingsSection: View {
    @Default(.pushToTalkDucking) private var ducking

    var body: some View {
        Section {
            PushToTalkKeyPicker()
            Toggle("Lower music while listening", isOn: $ducking)
        } header: {
            Text("Push to talk")
        } footer: {
            Text("Hold the key, speak, and release to send. Speech is transcribed on this Mac with Apple's on-device model (macOS 26 or later); audio never leaves the computer. Holding the key together with other keys keeps its normal shortcut behavior.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
