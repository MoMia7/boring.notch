//
//  SetupChecklist.swift
//  boringNotch
//
//  What Notch Agent needs to be fully working, with a fix button for each item.
//  Shown in onboarding and in Settings → Agent. Also replaces boring.notch when it's
//  installed, carrying its settings over.
//

import AppKit
import AVFoundation
import Defaults
import EventKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "io.otron.notch", category: "setup")

extension Notification.Name {
    /// userInfo["page"] = AgentSettingsPage raw value
    static let openAgentSettingsPage = Notification.Name("openAgentSettingsPage")
}

extension Defaults.Keys {
    static let replacedBoringNotch = Key<Bool>("replacedBoringNotch", default: false)
}

@MainActor
final class SetupStatus: ObservableObject {
    static let shared = SetupStatus()

    static let legacyBundleID = "theboringteam.boringnotch"
    static let setupCommand = "curl -fsSL https://raw.githubusercontent.com/MoMia7/boring.notch/main/agent/setup.sh | zsh"

    @Published private(set) var agentRunning: Bool?
    @Published private(set) var modelName: String?
    @Published private(set) var accessibility: Bool?
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var calendars = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminders = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var jevKey = false
    @Published private(set) var spotify = false
    @Published private(set) var legacyInstalled = false

    private init() {}

    func refresh() async {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        calendars = EKEventStore.authorizationStatus(for: .event)
        reminders = EKEventStore.authorizationStatus(for: .reminder)
        jevKey = DecisionEngine.shared.hasJevKey
        spotify = SpotifyClient.shared.isConnected
        legacyInstalled = !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Self.legacyBundleID).isEmpty
        accessibility = await XPCHelperClient.shared.isAccessibilityAuthorized()

        let client = OpencodeConfigClient.shared
        await client.refreshHealth()
        if case .healthy = client.health {
            agentRunning = true
            await client.reload(includeCatalog: false)
            let (provider, _) = OpencodeConfigClient.split(client.activeModel)
            modelName = client.connected.contains { $0.id == provider } ? client.activeModel : nil
        } else {
            agentRunning = false
            modelName = nil
        }
    }

    // MARK: Fixes

    func requestAccessibility() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
        Self.openPrivacyPane("Privacy_Accessibility")
    }

    func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            Self.openPrivacyPane("Privacy_Microphone")
        }
        await refresh()
    }

    func requestCalendarAndReminders() async {
        let store = EKEventStore()
        if calendars == .notDetermined { _ = try? await store.requestFullAccessToEvents() }
        if reminders == .notDetermined { _ = try? await store.requestFullAccessToReminders() }
        if calendars != .notDetermined && calendars != .fullAccess { Self.openPrivacyPane("Privacy_Calendars") }
        await refresh()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openSettings(_ page: AgentSettingsPage) {
        SettingsWindowController.shared.showWindow()
        NotificationCenter.default.post(name: .openAgentSettingsPage, object: nil, userInfo: ["page": page.rawValue])
    }

    // MARK: Replace boring.notch

    /// Notch Agent includes everything boring.notch does; running both would fight over
    /// the notch. Carries its settings over, then quits it and moves it to the Trash.
    func replaceLegacyIfInstalled() async {
        let installed = !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Self.legacyBundleID).isEmpty
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.legacyBundleID).isEmpty
        guard installed || running else { return }

        if let data = await XPCHelperClient.shared.exportPreferences(bundleIdentifier: Self.legacyBundleID),
           let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let defaults = UserDefaults.standard
            var imported = 0
            for (key, value) in prefs where defaults.object(forKey: key) == nil
                && !key.hasPrefix("SU") && !key.hasPrefix("NSWindow") && !key.hasPrefix("NSStatusItem") {
                defaults.set(value, forKey: key)
                imported += 1
            }
            log.notice("imported \(imported) boring.notch settings")
        }
        let retired = await XPCHelperClient.shared.retireApp(bundleIdentifier: Self.legacyBundleID)
        log.notice("replaced boring.notch: \(retired)")
        if retired { Defaults[.replacedBoringNotch] = true }
        legacyInstalled = !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Self.legacyBundleID).isEmpty
    }
}

// MARK: - View

struct SetupChecklist: View {
    enum Group { case permissions, agent, extras }

    var groups: [Group] = [.permissions, .agent, .extras]
    @ObservedObject private var status = SetupStatus.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if groups.contains(.agent) {
                row(icon: "server.rack", title: "Background agent",
                    detail: status.agentRunning == false ? "Not running. Run the setup command in Terminal." : "opencode is running",
                    state: status.agentRunning.map { $0 ? .ok : .missing } ?? .checking) {
                    Button(copied ? "Copied" : "Copy setup command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SetupStatus.setupCommand, forType: .string)
                        copied = true
                    }
                }
                row(icon: "cpu", title: "Model",
                    detail: status.modelName ?? "Log in with ChatGPT or add an API key",
                    state: status.agentRunning != true ? .blocked : (status.modelName != nil ? .ok : .missing)) {
                    Button("Choose…") { SetupStatus.openSettings(.models) }
                }
            }
            if groups.contains(.permissions) {
                row(icon: "keyboard", title: "Accessibility",
                    detail: "Needed for the push-to-talk key and media keys",
                    state: status.accessibility.map { $0 ? .ok : .missing } ?? .checking) {
                    Button("Allow") { status.requestAccessibility() }
                }
                row(icon: "mic.fill", title: "Microphone",
                    detail: "Voice input, transcribed on this Mac",
                    state: status.microphone == .authorized ? .ok : .missing) {
                    Button("Allow") { Task { await status.requestMicrophone() } }
                }
                row(icon: "calendar", title: "Calendar & Reminders",
                    detail: "Shows events and adds reminders/events instantly",
                    state: status.calendars == .fullAccess && status.reminders == .fullAccess ? .ok : .missing) {
                    Button("Allow") { Task { await status.requestCalendarAndReminders() } }
                }
            }
            if groups.contains(.extras) {
                row(icon: "bolt.fill", title: "Jev instant actions",
                    detail: "Optional · makes simple requests run instantly",
                    state: status.jevKey ? .ok : .optional) {
                    Button("Add key…") { SetupStatus.openSettings(.jev) }
                }
                row(icon: "music.note", title: "Spotify",
                    detail: "Optional · Premium, for instant songs and playlists",
                    state: status.spotify ? .ok : .optional) {
                    Button("Connect…") { SetupStatus.openSettings(.spotify) }
                }
                if status.legacyInstalled {
                    row(icon: "arrow.triangle.2.circlepath", title: "boring.notch is installed",
                        detail: "Notch Agent includes it; running both conflicts",
                        state: .missing) {
                        Button("Replace") { Task { await status.replaceLegacyIfInstalled() } }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await status.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private enum RowState { case ok, missing, optional, blocked, checking }

    private func row<Fix: View>(icon: String, title: String, detail: String, state: RowState,
                                @ViewBuilder fix: () -> Fix) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            switch state {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .checking:
                ProgressView().controlSize(.small)
            case .blocked:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .missing, .optional:
                fix().controlSize(.small)
            }
        }
    }
}
