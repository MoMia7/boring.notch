//
//  AgentActivityView.swift
//  boringNotch
//
//  Live "what is the agent doing" strip shown while a task runs.
//

import SwiftUI

struct AgentActivityView: View {
    @ObservedObject private var agent = AgentManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let activity = describe(now: context.date)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Group {
                        if activity.icon == "notch.mark" {
                            NotchMarkBadge(mood: .thinking)
                        } else {
                            Image(systemName: activity.icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(activity.tint)
                                .symbolEffect(.pulse, isActive: true)
                        }
                    }
                    .frame(width: 14)
                    Text(activity.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 4)
                    Text(footer(now: context.date))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.gray)
                }
                if let detail = activity.detail {
                    Text(detail)
                        .font(.system(size: 10, design: activity.monospaced ? .monospaced : .default))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 20)
                }
                if let progress = activity.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(activity.tint)
                        .controlSize(.mini)
                        .padding(.leading, 20)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            .animation(.smooth(duration: 0.2), value: activity.title)
        }
    }

    // MARK: - Content

    private struct Activity {
        var icon: String
        var tint: Color
        var title: String
        var detail: String? = nil
        var progress: Double? = nil
        var monospaced = false
    }

    private func footer(now: Date) -> String {
        var parts: [String] = []
        if agent.stepCount > 0 { parts.append("step \(agent.stepCount)") }
        if let started = agent.taskStartedAt { parts.append(Self.clock(now.timeIntervalSince(started))) }
        return parts.joined(separator: " · ")
    }

    private func describe(now: Date) -> Activity {
        if !agent.permissions.isEmpty {
            return Activity(icon: "hand.raised.fill", tint: .yellow, title: "Waiting for your approval")
        }
        if let retry = agent.retry {
            var detail = retry.message
            if let next = retry.next, next > now {
                detail += " · next try in \(Int(next.timeIntervalSince(now).rounded(.up)))s"
            }
            return Activity(icon: "arrow.clockwise", tint: .orange,
                            title: "Retrying (attempt \(retry.attempt))", detail: detail)
        }
        if let tool = agent.runningTool, case .tool(let name, _) = tool.kind {
            var detail = tool.text
            if let started = agent.toolStartedAt[tool.id] {
                detail = "\(Self.clock(now.timeIntervalSince(started))) · " + detail
            }
            return Activity(icon: "terminal", tint: .blue, title: "Running \(name)",
                            detail: detail.isEmpty ? nil : detail, monospaced: true)
        }
        if case .cloud(let provider, let name) = agent.modelState {
            return Activity(icon: "cloud", tint: .accentColor, title: "Thinking…",
                            detail: "Waiting for \(AgentWelcomeView.providerName(provider)) · \(name)")
        }
        guard let model = agent.modelStatus else {
            return Activity(icon: "notch.mark", tint: .accentColor, title: "Thinking…")
        }
        switch model.phase {
        case "waking":
            return Activity(icon: "moon.zzz.fill", tint: .purple, title: "Waking the model",
                            detail: "Loading weights after being idle · \(Self.clock(model.elapsedMs / 1000))")
        case "prefill":
            let total = max(model.promptTotal, 1)
            let newTokens = max(model.promptTotal - model.promptCached, 1)
            let done = max(model.promptProcessed - model.promptCached, 0)
            var detail = "\(Self.number(model.promptProcessed)) / \(Self.number(model.promptTotal)) tokens"
            if model.promptCached > 0 { detail += " (\(Self.number(model.promptCached)) cached)" }
            if model.prefillTps > 0 {
                detail += " · \(Int(model.prefillTps)) tok/s"
                let remaining = Double(newTokens - done) / model.prefillTps
                if remaining > 1 { detail += " · ~\(Self.clock(remaining)) left" }
            }
            return Activity(icon: "text.magnifyingglass", tint: .teal, title: "Reading context",
                            detail: model.promptTotal == 0 ? "Starting…" : detail,
                            progress: model.promptTotal == 0 ? nil : Double(model.promptProcessed) / Double(total))
        case "generating":
            var detail = "\(model.genTokens) tokens"
            if model.genTps > 0 { detail += String(format: " · %.1f tok/s", model.genTps) }
            return Activity(icon: "pencil.line", tint: .green, title: "Writing", detail: detail)
        default:
            return Activity(icon: "notch.mark", tint: .accentColor, title: "Thinking…",
                            detail: "Waiting for the harness")
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func number(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}

/// One-line recap under a finished answer.
struct AgentRunSummaryView: View {
    let summary: AgentRunSummary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal")
            Text(text)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.gray.opacity(0.8))
    }

    private var text: String {
        var parts = ["\(AgentActivityView.clock(summary.duration))"]
        parts.append(summary.steps == 1 ? "1 step" : "\(summary.steps) steps")
        if summary.tools > 0 { parts.append(summary.tools == 1 ? "1 tool" : "\(summary.tools) tools") }
        if let tps = summary.genTps { parts.append(String(format: "%.1f tok/s", tps)) }
        return parts.joined(separator: " · ")
    }
}
