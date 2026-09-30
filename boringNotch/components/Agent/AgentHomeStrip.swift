//
//  AgentHomeStrip.swift
//  boringNotch
//
//  One-line agent bar under the Home tab: a prompt that jumps to the full Notch tab,
//  and the latest status (working, approval needed, last result).
//

import Defaults
import SwiftUI

struct AgentHomeStrip: View {
    @ObservedObject private var agent = AgentManager.shared
    @ObservedObject private var voice = VoiceInput.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @State private var hoveringPrompt = false
    @State private var hoveringStatus = false

    var body: some View {
        HStack(spacing: 8) {
            prompt
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { _ in status }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    // MARK: Prompt

    private var prompt: some View {
        Button(action: openFull(focus: true)) {
            HStack(spacing: 7) {
                NotchMark(mood: mood, animated: agent.isBusy || voice.isActive)
                    .frame(width: 18)
                    .foregroundStyle(.white.opacity(0.9))
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(.gray.opacity(hoveringPrompt ? 1 : 0.8))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringPrompt = $0 }
    }

    private var placeholder: String {
        if voice.isActive { return voice.transcript.isEmpty ? "Listening…" : voice.transcript }
        let key = Defaults[.pushToTalkKey]
        return key == .off ? "Ask Notch…" : "Ask Notch… or hold \(key.shortName)"
    }

    private var mood: NotchMood {
        if voice.isActive { return .listening }
        if !agent.permissions.isEmpty { return .attention }
        if agent.isBusy { return .working }
        if case .offline = agent.connection { return .offline }
        return .idle
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        if let line = statusLine {
            Button(action: openFull(focus: false)) {
                HStack(spacing: 5) {
                    if let icon = line.icon {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(line.tint)
                    }
                    Text(line.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.gray.opacity(hoveringStatus ? 1 : 0.5))
                }
                .frame(maxWidth: 300, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringStatus = $0 }
            .help("Open the Notch tab")
        }
    }

    private struct StatusLine {
        var icon: String?
        var tint: Color = .gray
        var text: String
    }

    private var statusLine: StatusLine? {
        if !agent.permissions.isEmpty {
            return StatusLine(icon: "hand.raised.fill", tint: .yellow, text: "Needs your approval")
        }
        if agent.isBusy {
            var parts = ["Working"]
            if agent.stepCount > 0 { parts.append("step \(agent.stepCount)") }
            if let tool = agent.runningTool, case .tool(let name, _) = tool.kind { parts.append(name) }
            if let started = agent.taskStartedAt {
                parts.append(AgentActivityView.clock(Date().timeIntervalSince(started)))
            }
            return StatusLine(icon: "circle.dotted", tint: .accentColor, text: parts.joined(separator: " · "))
        }
        if case .offline = agent.connection {
            return StatusLine(icon: "bolt.horizontal.circle", tint: .red, text: "Agent offline")
        }
        // Most recent outcome.
        guard let last = agent.items.last(where: {
            switch $0.kind {
            case .assistant, .quick, .error: return true
            default: return false
            }
        }) else { return nil }
        let firstLine = last.text.split(separator: "\n").first.map(String.init) ?? last.text
        switch last.kind {
        case .quick: return StatusLine(icon: "bolt.fill", tint: .yellow, text: firstLine)
        case .error: return StatusLine(icon: "exclamationmark.triangle.fill", tint: .orange, text: firstLine)
        default: return StatusLine(icon: "text.bubble", tint: .gray, text: firstLine)
        }
    }

    private func openFull(focus: Bool) -> () -> Void {
        {
            withAnimation(.smooth) { coordinator.currentView = .agent }
            if focus {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    NotificationCenter.default.post(name: .agentFocusInput, object: nil)
                }
            }
        }
    }
}
