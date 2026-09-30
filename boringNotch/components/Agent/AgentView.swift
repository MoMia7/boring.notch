//
//  AgentView.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

/// The notch panel normally refuses key status; the agent tab needs it for typing.
enum AgentKeyPolicy {
    static var allowsKey = false
}

struct AgentView: View {
    @ObservedObject private var agent = AgentManager.shared
    @ObservedObject private var monitor = AmbientMonitor.shared
    @ObservedObject private var voice = VoiceInput.shared
    @State private var draft = ""
    @State private var window: NSWindow?
    @State private var previousApp: NSRunningApplication?
    @State private var holdingForInput = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let permission = agent.permissions.first {
                PermissionCard(permission: permission, command: agent.command(for: permission)) { reply in
                    agent.reply(to: permission, with: reply)
                }
            } else if let nudge = monitor.nudge {
                NudgeCard(nudge: nudge, onButton: { monitor.perform($0) }, onDismiss: { monitor.dismiss() })
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else if agent.items.isEmpty && !agent.isBusy {
                AgentWelcomeView(onSend: { agent.send($0) }, onPrefill: prefill)
                    .transition(.opacity)
            } else {
                transcript
                    .transition(.opacity)
            }
            inputBar
        }
        .padding(.horizontal, 4)
        .animation(.smooth(duration: 0.25), value: agent.items.isEmpty)
        .background(WindowAccessor(window: $window))
        .onAppear { AgentKeyPolicy.allowsKey = true }
        .onDisappear {
            AgentKeyPolicy.allowsKey = false
            releaseFocus()
        }
        .onChange(of: inputFocused) { _, focused in
            if focused { holdOpen() } else { releaseHold() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if (note.object as? NSWindow) === window { inputFocused = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentFocusInput)) { _ in
            focusInput()
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(agent.items) { item in
                        AgentRow(item: item).id(item.id)
                        if let summary = agent.runSummaries[item.id] {
                            AgentRunSummaryView(summary: summary)
                        }
                        if let followUp = agent.followUp, followUp.itemID == item.id {
                            FollowUpBanner(followUp: followUp)
                        }
                        if let offer = agent.learnOffer, offer.itemID == item.id {
                            LearnOfferCard(offer: offer)
                        }
                    }
                    if agent.isBusy {
                        AgentActivityView().id("busy")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: agent.items) { _, _ in scrollToEnd(proxy) }
            .onChange(of: agent.isBusy) { _, _ in scrollToEnd(proxy) }
            .onChange(of: agent.runSummaries) { _, _ in scrollToEnd(proxy) }
            .onChange(of: agent.learnOffer) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target = agent.isBusy ? "busy" : agent.items.last?.id
        guard let target else { return }
        withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    // MARK: Input

    @ViewBuilder
    private var inputBar: some View {
        if voice.isActive {
            voiceBar
        } else {
            textBar
        }
    }

    private var voiceBar: some View {
        HStack(spacing: 8) {
            VoiceWaveform(level: voice.level)
                .frame(width: 22, height: 16)
            Text(voice.transcript.isEmpty ? (voice.state == .finishing ? "Transcribing…" : "Listening…") : voice.transcript)
                .font(.callout)
                .foregroundStyle(voice.transcript.isEmpty ? .gray : .white)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            Text("release to send")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Color(red: 1.0, green: 0.45, blue: 0.5).opacity(0.14)))
        .overlay(Capsule().strokeBorder(Color(red: 1.0, green: 0.45, blue: 0.5).opacity(0.35 + 0.5 * Double(voice.level)), lineWidth: 1))
    }

    private var textBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .help(statusHelp)
            TextField(voicePlaceholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($inputFocused)
                .onSubmit(submit)
                .onExitCommand { releaseFocus() }
            if agent.isBusy {
                iconButton("stop.fill", help: "Stop") { agent.abort() }
            } else {
                iconButton("arrow.up", help: "Send") { submit() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            iconButton("square.and.pencil", help: "New conversation") { agent.newSession() }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .contentShape(Capsule())
        .onTapGesture { focusInput() }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var statusColor: Color {
        switch agent.connection {
        case .connected: return agent.isBusy ? .yellow : .green
        case .connecting: return .gray
        case .offline: return .red
        }
    }

    private var statusHelp: String {
        switch agent.connection {
        case .connected: return agent.isBusy ? "Working" : "Ready"
        case .connecting: return "Connecting"
        case .offline(let reason): return reason
        }
    }

    private var voicePlaceholder: String {
        if case .failed(let message) = voice.state { return message }
        let key = Defaults[.pushToTalkKey]
        return key == .off ? "Ask Notch…" : "Ask Notch… or hold \(key.shortName) to talk"
    }

    private func prefill(_ text: String) {
        draft = text
        focusInput()
    }

    private func submit() {
        let text = draft
        draft = ""
        agent.send(text)
    }

    // MARK: Focus handling

    private func focusInput() {
        guard let window else { return }
        if previousApp == nil { previousApp = NSWorkspace.shared.frontmostApplication }
        AgentKeyPolicy.allowsKey = true
        window.makeKey()
        inputFocused = true
    }

    private func releaseFocus() {
        inputFocused = false
        releaseHold()
        if let window, window.isKeyWindow {
            previousApp?.activate()
        }
        previousApp = nil
    }

    private func holdOpen() {
        guard !holdingForInput else { return }
        holdingForInput = true
        SharingStateManager.shared.beginInteraction()
    }

    private func releaseHold() {
        guard holdingForInput else { return }
        holdingForInput = false
        SharingStateManager.shared.endInteraction()
        SharingStateManager.shared.requestCloseIfReady()
    }
}

extension Notification.Name {
    static let agentFocusInput = Notification.Name("agentFocusInput")
}

// MARK: - Rows

private struct AgentRow: View {
    let item: AgentItem

    var body: some View {
        switch item.kind {
        case .user:
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.35)))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .assistant:
            Text(LocalizedStringKey(item.text))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .tool(let name, let status):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: icon(for: status))
                    .foregroundStyle(color(for: status))
                Text(name).foregroundStyle(.gray)
                Text(item.text)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .font(.system(size: 10, design: .monospaced))
        case .quick(let icon):
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                Image(systemName: icon).foregroundStyle(.white.opacity(0.8))
                Text(item.text).foregroundStyle(.white.opacity(0.9))
                Text("instant").foregroundStyle(.gray)
            }
            .font(.caption)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
    }

    private func icon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        case "running": return "circle.dotted"
        default: return "circle"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "error": return .red
        default: return .gray
        }
    }
}

/// "Make this instant?": shows the exact commands that will be replayed before saving.
private struct LearnOfferCard: View {
    let offer: LearnCandidate
    @State private var expanded = false
    private var agent: AgentManager { AgentManager.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                Text("Make this instant next time?").foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 4)
                Button(expanded ? "Hide" : "Show commands") { withAnimation(.smooth) { expanded.toggle() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.gray)
                chip("Make instant", tint: .yellow.opacity(0.35)) { agent.acceptLearnOffer() }
                Button { agent.dismissLearnOffer() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
            if expanded {
                ForEach(offer.commands, id: \.self) { command in
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.yellow.opacity(0.08)))
    }

    private func chip(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
    }
}

private struct FollowUpBanner: View {
    let followUp: AgentFollowUp
    private var agent: AgentManager { AgentManager.shared }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: followUp.kind == .looping ? "arrow.triangle.2.circlepath" : "exclamationmark.bubble")
                .foregroundStyle(.orange)
            Text(title).foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 4)
            chip("Keep going") { agent.send("Continue and finish my original request: \(followUp.request)") }
            chip("Try another way") {
                agent.send("That didn't work. Try a different approach to: \(followUp.request)")
            }
            Button { agent.dismissFollowUp() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
    }

    private var title: String {
        switch followUp.kind {
        case .failed: return "Looks like that failed"
        case .incomplete: return "Looks unfinished"
        case .looping: return "It seemed to go in circles"
        }
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

private struct NudgeCard: View {
    let nudge: AgentNudge
    let onButton: (AgentNudge.Button) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: nudge.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: nudge.tint))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(nsColor: nudge.tint).opacity(0.18)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(nudge.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(nudge.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.gray)
                }
                Spacer(minLength: 4)
                Text(nudge.source == .jev ? "jev" : "local")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.gray.opacity(0.7))
                    .help(nudge.source == .jev ? "Decided by Jev" : "Decided on-device by Gemma (Jev unavailable)")
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                ForEach(Array(nudge.buttons.enumerated()), id: \.element.id) { index, button in
                    Button { onButton(button) } label: {
                        Label(button.label, systemImage: button.icon)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(index == 0 ? Color(nsColor: nudge.tint).opacity(0.45) : Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct PermissionCard: View {
    let permission: AgentPermission
    let command: String
    let onReply: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Allow \(permission.permission)?", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)
            ScrollView(.vertical, showsIndicators: false) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                replyButton("Deny", "reject", tint: .red.opacity(0.35))
                Spacer()
                replyButton("Always allow", "always", tint: .white.opacity(0.1))
                replyButton("Allow once", "once", tint: .green.opacity(0.45))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func replyButton(_ title: String, _ reply: String, tint: Color) -> some View {
        Button { onReply(reply) } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
    }
}

/// Exposes the hosting NSWindow to SwiftUI.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}

struct AgentServerURLField: View {
    @Default(.agentServerURL) private var url

    var body: some View {
        TextField("Agent server URL", text: $url)
    }
}
