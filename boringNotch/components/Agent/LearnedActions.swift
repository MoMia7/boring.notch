//
//  LearnedActions.swift
//  boringNotch
//
//  System 2 teaches System 1: when the agent finishes a task with plain shell commands,
//  the user can save it as an instant action. Jev routes to it from then on and the
//  commands replay directly (no LLM), in a few hundred milliseconds.
//

import Foundation
import OSLog

private let log = Logger(subsystem: "io.otron.notch", category: "learned")

struct LearnedAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// The original request, used (with the title) as the description Jev matches against.
    var request: String
    var commands: [String]
    var createdAt = Date()
    var uses = 0

    var jevID: String { "learned_" + id.uuidString.prefix(8).lowercased() }
}

/// A finished task that could become an instant action.
struct LearnCandidate: Equatable {
    let itemID: String      // assistant reply it belongs to (where the offer is shown)
    let request: String
    let commands: [String]
}

@MainActor
final class LearnedActions: ObservableObject {
    static let shared = LearnedActions()

    @Published private(set) var actions: [LearnedAction] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("learned-actions.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([LearnedAction].self, from: data) {
            actions = saved
        }
    }

    // MARK: Candidates

    /// Looks at the last finished task: learnable when every tool call was a completed shell
    /// command and none of them is unsafe.
    func candidate(from items: [AgentItem]) -> LearnCandidate? {
        guard let userIndex = items.lastIndex(where: { $0.kind == .user }),
              let reply = items.last(where: { $0.kind == .assistant }),
              let replyIndex = items.firstIndex(of: reply), replyIndex > userIndex else { return nil }
        let request = items[userIndex].text
        var commands: [String] = []
        for item in items[userIndex...] {
            guard case .tool(let name, let status) = item.kind else { continue }
            // Retries after a failed/misspelled call are fine as long as the final ones succeeded.
            if status == "error" { continue }
            guard name == "bash", status == "completed" else { return nil }
            let command = item.text.components(separatedBy: "\n").first ?? item.text
            guard !command.isEmpty, RequestParsing.isSafeToLearn(command) else { return nil }
            if !commands.contains(command) { commands.append(command) }
        }
        guard !commands.isEmpty, commands.count <= 4,
              !actions.contains(where: { $0.request.caseInsensitiveCompare(request) == .orderedSame }) else { return nil }
        return LearnCandidate(itemID: reply.id, request: request, commands: commands)
    }

    // MARK: Store

    @discardableResult
    func learn(_ candidate: LearnCandidate) -> LearnedAction {
        var title = candidate.request.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        if title.count > 48 { title = String(title.prefix(47)) + "…" }
        title = title.prefix(1).uppercased() + title.dropFirst()
        let action = LearnedAction(title: title, request: candidate.request, commands: candidate.commands)
        actions.append(action)
        save()
        log.notice("learned action with \(candidate.commands.count) command(s)")
        return action
    }

    func delete(_ action: LearnedAction) {
        actions.removeAll { $0.id == action.id }
        save()
    }

    func rename(_ action: LearnedAction, to title: String) {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        actions[index].title = title
        save()
    }

    func action(forJevID id: String) -> LearnedAction? { actions.first { $0.jevID == id } }

    /// Replays the commands; returns the first line of output (or the title) for the notch.
    func run(_ action: LearnedAction) async -> String? {
        var lastOutput = ""
        for command in action.commands {
            guard let output = await AgentManager.shared.runShellCapturing(command) else { return nil }
            lastOutput = output
        }
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index].uses += 1
            save()
        }
        let firstLine = lastOutput.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty ? action.title : String(firstLine.prefix(80))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(actions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
