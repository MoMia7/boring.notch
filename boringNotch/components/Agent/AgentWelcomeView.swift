//
//  AgentWelcomeView.swift
//  boringNotch
//
//  First thing you see when the notch opens on a fresh conversation.
//

import AppKit
import Defaults
import SwiftUI

struct AgentSuggestion: Identifiable {
    enum Action {
        case send(String)     // run immediately
        case prefill(String)  // put in the input for the user to finish
    }

    let id = UUID()
    let key: String
    let title: String
    let icon: String
    let tint: Color
    let action: Action
}

struct AgentWelcomeView: View {
    @ObservedObject private var agent = AgentManager.shared
    let onSend: (String) -> Void
    let onPrefill: (String) -> Void

    @State private var suggestions: [AgentSuggestion] = []
    @State private var appeared = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if case .offline = agent.connection {
                offlineCard
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        SuggestionChip(suggestion: suggestion) { run(suggestion) }
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 6)
                            .animation(.smooth(duration: 0.35).delay(0.04 * Double(index)), value: appeared)
                    }
                }
                .disabled(agent.connection != .connected)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 2)
        .onAppear {
            let pool = Self.makePool()
            suggestions = Array(pool.prefix(9))
            agent.refreshModelState()
            appeared = true
            Task { await rank(pool) }
        }
        .onDisappear { appeared = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            NotchMarkBadge(mood: headerMood)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(statusLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var headerMood: NotchMood {
        switch agent.connection {
        case .offline: return .offline
        case .connecting: return .thinking
        case .connected:
            if case .unreachable = agent.modelState { return .offline }
            return .idle
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part: String
        switch hour {
        case 5..<12: part = "Good morning"
        case 12..<17: part = "Good afternoon"
        case 17..<22: part = "Good evening"
        default: part = "Up late"
        }
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "\(part)." : "\(part), \(first)."
    }

    private var statusLine: String {
        switch agent.connection {
        case .connecting:
            return "Connecting to the agent…"
        case .offline:
            return "Agent offline"
        case .connected:
            switch agent.modelState {
            case .ready(let name): return "\(name) is ready · what should I do?"
            case .asleep(let name): return "\(name) is asleep · first reply takes about 40 seconds"
            case .cloud(let provider, let model): return "\(model) via \(Self.providerName(provider)) · what should I do?"
            case .unreachable: return "Agent is up, but the model server isn’t answering"
            case .unknown: return "What should I do?"
            }
        }
    }

    static func providerName(_ id: String) -> String {
        switch id {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "google": return "Google"
        case "openrouter": return "OpenRouter"
        case "groq": return "Groq"
        default: return id.capitalized
        }
    }

    private var statusColor: Color {
        switch agent.connection {
        case .connecting: return .gray
        case .offline: return .red
        case .connected:
            switch agent.modelState {
            case .ready, .unknown, .cloud: return .green
            case .asleep: return .yellow
            case .unreachable: return .orange
            }
        }
    }

    // MARK: Offline

    private var offlineCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("The background agent isn’t running. Restart it with:")
                .font(.system(size: 10.5))
                .foregroundStyle(.gray)
            HStack(spacing: 6) {
                Text("launchctl kickstart -k gui/$UID/io.otron.notch.opencode")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("launchctl kickstart -k gui/$UID/io.otron.notch.opencode", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
                .help("Copy command")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        }
    }

    // MARK: Suggestions

    private func run(_ suggestion: AgentSuggestion) {
        switch suggestion.action {
        case .send(let prompt): onSend(prompt)
        case .prefill(let text): onPrefill(text)
        }
    }

    /// Reorders the pool with Jev using only coarse context; keeps the default order offline.
    private func rank(_ pool: [AgentSuggestion]) async {
        guard Defaults[.jevSmartSuggestions], DecisionEngine.shared.jevAvailable, pool.count > 9 else { return }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        let nextMeeting = CalendarManager.shared.events
            .filter { !$0.isAllDay && $0.start > now }
            .map { Int($0.start.timeIntervalSince(now) / 60) }
            .min()
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        let clipKind = clip.hasPrefix("http") && !clip.contains("\n") ? "web_link"
            : clip.count > 40 ? "text" : clip.isEmpty ? "empty" : "short_text"
        let state: [String: Any] = [
            "local_time": formatter.string(from: now),
            "front_app": NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown",
            "music_playing": MusicManager.shared.isPlaying,
            "clipboard": clipKind,
            "minutes_to_next_meeting": nextMeeting ?? -1,
            "battery_percent": Int(BatteryStatusViewModel.shared.levelBattery),
        ]
        let questions = pool.map { ($0.key, DecisionQuestion.noul("The user is likely to want this shortcut right now: \($0.title)")) }
        guard let result = await DecisionEngine.shared.decide(state: state, questions: questions, timeout: 1.2) else { return }
        let ranked = pool.sorted { (result[$0.key]?.probability ?? 0) > (result[$1.key]?.probability ?? 0) }
        withAnimation(.smooth(duration: 0.3)) { suggestions = Array(ranked.prefix(9)) }
    }

    /// Candidate shortcuts in default (offline) priority order.
    static func makePool() -> [AgentSuggestion] {
        var list: [AgentSuggestion] = []
        let now = Date()

        if let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), clip.count > 40 {
            list.append(.init(key: "clipboard", title: "Summarize clipboard", icon: "doc.on.clipboard", tint: .purple,
                              action: .send("Summarize the text on my clipboard (use pbpaste) in two sentences.")))
        }
        if let meeting = CalendarManager.shared.events.first(where: {
            !$0.isAllDay && $0.start > now && $0.start.timeIntervalSince(now) < 45 * 60
        }) {
            list.append(.init(key: "next_meeting", title: "Prep for \(meeting.title)", icon: "person.2", tint: .red,
                              action: .send("Give me a two-line brief for my calendar event \"\(meeting.title)\" using its notes and attendees.")))
        }
        let hour = Calendar.current.component(.hour, from: now)
        list.append(hour < 12
            ? .init(key: "calendar", title: "Plan my day", icon: "calendar", tint: .red,
                    action: .send("What's on my calendar today? Give me a one-line summary."))
            : .init(key: "calendar", title: "Rest of my day", icon: "calendar", tint: .red,
                    action: .send("What's left on my calendar today? Give me a one-line summary.")))
        list += [
            .init(key: "remind", title: "Remind me to…", icon: "checklist", tint: .orange, action: .prefill("Remind me to ")),
            .init(key: "find", title: "Find a file…", icon: "magnifyingglass", tint: .blue, action: .prefill("Find the file ")),
            .init(key: "health", title: "Mac health", icon: "gauge.with.dots.needle.67percent", tint: .green,
                  action: .send("Check my battery, free disk space and the top CPU process. Answer in one line.")),
            .init(key: "download", title: "Latest download", icon: "arrow.down.circle", tint: .teal,
                  action: .send("Open the most recently added file in ~/Downloads.")),
            .init(key: "dark_mode", title: "Toggle dark mode", icon: "circle.lefthalf.filled", tint: .indigo,
                  action: .send("Toggle dark mode.")),
            MusicManager.shared.isPlaying
                ? .init(key: "music", title: "Pause music", icon: "pause.fill", tint: .pink, action: .send("Pause the music"))
                : .init(key: "music", title: "Play music", icon: "play.fill", tint: .pink, action: .send("Play music")),
            .init(key: "desktop", title: "Tidy Desktop", icon: "sparkles.rectangle.stack", tint: .mint,
                  action: .send("List the files on my Desktop older than 30 days and suggest which to move to the Trash. Don't move anything yet.")),
            .init(key: "focus", title: "Front app help", icon: "questionmark.app", tint: .cyan,
                  action: .prefill("In the app I'm using, how do I ")),
        ]
        return list
    }
}

private struct SuggestionChip: View {
    let suggestion: AgentSuggestion
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(suggestion.tint)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(suggestion.tint.opacity(0.18)))
                Text(suggestion.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if case .prefill = suggestion.action {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 9))
                        .foregroundStyle(.gray.opacity(hovering ? 1 : 0))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(hovering ? 0.12 : 0.04), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
    }
}
