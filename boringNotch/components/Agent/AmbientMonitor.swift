//
//  AmbientMonitor.swift
//  boringNotch
//
//  The "perpetual" part of the agent: watches a few cheap signals (new downloads,
//  meetings about to start, low battery, clipboard) and asks a fast decision model
//  whether each one is worth a small nudge in the notch. Jev gets only coarse,
//  content-free metadata; when Jev is unavailable, the local model decides for the
//  important signals, with richer context since nothing leaves the Mac.
//

import AppKit
import Combine
import Defaults
import Foundation

extension Notification.Name {
    static let agentNudge = Notification.Name("agentNudge")
}

struct AgentNudge: Identifiable {
    enum Action {
        case prompt(String)
        case open(URL)
        case reveal(URL)
    }

    struct Button: Identifiable {
        let id = UUID()
        let label: String
        let icon: String
        let action: Action
    }

    let id = UUID()
    let icon: String
    let tint: NSColor
    let title: String
    let detail: String
    let buttons: [Button]
    let source: DecisionSource
    let createdAt = Date()
}

@MainActor
final class AmbientMonitor: ObservableObject {
    static let shared = AmbientMonitor()

    @Published private(set) var nudge: AgentNudge?

    private var lastNudgeAt = Date.distantPast
    private var nudgesThisHour: [Date] = []
    private var downloadsSource: DispatchSourceFileSystemObject?
    private var knownDownloads: Set<String> = []
    private var notifiedEvents: Set<String> = []
    private var batteryNudged = false
    private var lastClipboardChange = NSPasteboard.general.changeCount
    private var lastClipboardNudge = Date.distantPast
    private var timers: [Timer] = []
    private var expiryTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard timers.isEmpty else { return }
        watchDownloads()
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                AmbientMonitor.shared.checkMeetings()
                AmbientMonitor.shared.checkBattery()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in AmbientMonitor.shared.checkClipboard() }
        })
    }

    func dismiss() {
        nudge = nil
        expiryTask?.cancel()
    }

    func perform(_ button: AgentNudge.Button) {
        switch button.action {
        case .prompt(let text): AgentManager.shared.send(text)
        case .open(let url): NSWorkspace.shared.open(url)
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        dismiss()
    }

    // MARK: - Signals

    private var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    private func watchDownloads() {
        let path = realHome + "/Downloads"
        knownDownloads = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                // Let the browser finish renaming/writing before we look.
                try? await Task.sleep(for: .seconds(2))
                await AmbientMonitor.shared.scanDownloads(path)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        downloadsSource = source
    }

    private func scanDownloads(_ path: String) async {
        let current = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
        let added = current.subtracting(knownDownloads)
        knownDownloads = current
        let partial = ["crdownload", "download", "part", "tmp", "partial"]
        for name in added where !name.hasPrefix(".") {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            let ext = url.pathExtension.lowercased()
            guard !partial.contains(ext) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
            await considerDownload(url: url, ext: ext, sizeMB: size / 1_048_576)
        }
    }

    private func checkMeetings() {
        let now = Date()
        for event in CalendarManager.shared.events where !event.isAllDay {
            let minutes = event.start.timeIntervalSince(now) / 60
            guard minutes > 0.5, minutes <= 6, !notifiedEvents.contains(event.id) else { continue }
            notifiedEvents.insert(event.id)
            Task { await considerMeeting(event, minutes: Int(minutes.rounded())) }
        }
    }

    private func checkBattery() {
        let battery = BatteryStatusViewModel.shared
        if battery.isPluggedIn { batteryNudged = false; return }
        guard !batteryNudged, battery.levelBattery > 0, battery.levelBattery <= 15 else { return }
        batteryNudged = true
        Task { await considerBattery(level: Int(battery.levelBattery)) }
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastClipboardChange else { return }
        lastClipboardChange = pasteboard.changeCount
        // Clipboard changes are frequent; only consult Jev (never the local model) and rarely.
        guard DecisionEngine.shared.jevAvailable,
              Date().timeIntervalSince(lastClipboardNudge) > 900,
              let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        let kind: String
        if !text.contains("\n"), let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") {
            kind = "web_link"
        } else if text.contains("\n") && text.range(of: #"[{};]\s*$"#, options: [.regularExpression]) != nil {
            kind = "code"
        } else if text.count > 600 {
            kind = "long_text"
        } else {
            return
        }
        Task { await considerClipboard(kind: kind, text: text) }
    }

    // MARK: - Decisions

    private func context() -> [String: Any] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        let now = Date()
        let inMeeting = CalendarManager.shared.events.contains { !$0.isAllDay && $0.start <= now && $0.end > now }
        nudgesThisHour.removeAll { now.timeIntervalSince($0) > 3600 }
        return [
            "local_time": formatter.string(from: now),
            "front_app": NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown",
            "in_meeting_now": inMeeting,
            "nudges_in_last_hour": nudgesThisHour.count,
            "music_playing": MusicManager.shared.isPlaying,
        ]
    }

    private var canNudge: Bool {
        Defaults[.jevAmbientNudges]
            && !AgentManager.shared.isBusy
            && AgentManager.shared.permissions.isEmpty
            && Date().timeIntervalSince(lastNudgeAt) > 180
    }

    private static let interruptQuestion = DecisionQuestion.noul(
        "It is worth briefly interrupting the user with a small popup in the notch about this event right now, given what they are doing"
    )

    private func considerDownload(url: URL, ext: String, sizeMB: Double) async {
        guard canNudge else { return }
        let readable = ["pdf", "txt", "md", "docx", "doc", "rtf", "csv", "html", "pages"].contains(ext)
        let archive = ["zip", "tar", "gz", "tgz", "7z", "rar"].contains(ext)
        var options: [(String, String)] = [("open", "Open the file"), ("reveal", "Show it in Finder")]
        if readable { options.append(("summarize", "Summarize the document")) }
        if archive { options.append(("unzip", "Extract the archive")) }
        options.append(("none", "No follow-up is useful"))

        let event: [String: Any] = ["type": "file_downloaded", "file_type": ext.isEmpty ? "unknown" : ext,
                                    "size_mb": (sizeMB * 10).rounded() / 10]
        var local = event
        local["file_name"] = url.lastPathComponent
        guard let result = await DecisionEngine.shared.decide(
            state: ["event": event, "context": context()],
            localState: ["event": local, "context": context()],
            questions: [("interrupt", Self.interruptQuestion),
                        ("followup", .choice("The most useful follow-up for this download", options))],
            fallback: .gemma
        ), shouldInterrupt(result) else { return }

        var buttons: [AgentNudge.Button] = []
        let quoted = "\"\(url.path)\""
        let followup = result["followup"]?.choice ?? "open"
        if followup == "summarize" || readable {
            buttons.append(.init(label: "Summarize", icon: "text.alignleft",
                                 action: .prompt("Summarize the file \(quoted) in three short bullet points.")))
        }
        if followup == "unzip" || archive {
            buttons.append(.init(label: "Extract", icon: "archivebox",
                                 action: .prompt("Extract the archive \(quoted) into a folder next to it.")))
        }
        buttons.append(.init(label: "Open", icon: "arrow.up.forward.app", action: .open(url)))
        buttons.append(.init(label: "Show", icon: "folder", action: .reveal(url)))
        if followup != "open", let index = buttons.firstIndex(where: { $0.label.lowercased().hasPrefix(followup.prefix(4)) }) {
            buttons.insert(buttons.remove(at: index), at: 0)
        }
        present(AgentNudge(icon: "arrow.down.circle.fill", tint: .systemBlue, title: "Downloaded \(url.lastPathComponent)",
                           detail: String(format: "%@ · %.1f MB", ext.uppercased(), sizeMB),
                           buttons: Array(buttons.prefix(3)), source: result.source))
    }

    private func considerMeeting(_ event: EventModel, minutes: Int) async {
        guard Defaults[.jevAmbientNudges], AgentManager.shared.permissions.isEmpty else { return }
        let joinURL = Self.meetingLink(in: event)
        let info: [String: Any] = ["type": "meeting_starting", "minutes_until_start": minutes,
                                   "has_video_link": joinURL != nil, "attendees": event.participants.count]
        var local = info
        local["title"] = event.title
        guard let result = await DecisionEngine.shared.decide(
            state: ["event": info, "context": context()],
            localState: ["event": local, "context": context()],
            questions: [("interrupt", Self.interruptQuestion),
                        ("followup", .choice("The most useful follow-up", [
                            ("join", "Join the video call"),
                            ("brief", "Give a quick brief of the meeting from its notes"),
                            ("none", "No follow-up is useful"),
                        ]))],
            fallback: .gemma,
            gemmaMinInterval: 30
        ), shouldInterrupt(result) else { return }

        var buttons: [AgentNudge.Button] = []
        if let joinURL { buttons.append(.init(label: "Join", icon: "video.fill", action: .open(joinURL))) }
        buttons.append(.init(label: "Brief me", icon: "text.bubble",
                             action: .prompt("Give me a two-line brief for my calendar event \"\(event.title)\" starting at \(event.start.formatted(date: .omitted, time: .shortened)), using its notes and attendees.")))
        if result["followup"]?.choice == "brief" { buttons.reverse() }
        present(AgentNudge(icon: "calendar", tint: .systemRed, title: event.title,
                           detail: "Starts in \(minutes) min" + (joinURL != nil ? " · video call" : ""),
                           buttons: buttons, source: result.source))
    }

    private func considerBattery(level: Int) async {
        guard canNudge else { return }
        guard let result = await DecisionEngine.shared.decide(
            state: ["event": ["type": "battery_low", "percent": level, "charging": false], "context": context()],
            questions: [("interrupt", Self.interruptQuestion)],
            fallback: .gemma
        ), shouldInterrupt(result) else { return }
        present(AgentNudge(icon: "battery.25", tint: .systemOrange, title: "Battery at \(level)%",
                           detail: "Not charging",
                           buttons: [.init(label: "What's draining it?", icon: "bolt.slash",
                                           action: .prompt("Which apps are using the most energy right now? One line."))],
                           source: result.source))
    }

    private func considerClipboard(kind: String, text: String) async {
        guard canNudge else { return }
        guard let result = await DecisionEngine.shared.decide(
            state: ["event": ["type": "clipboard_copied", "content_kind": kind, "length": text.count], "context": context()],
            questions: [("interrupt", .noul("The user would want a quick offer to help with what they just copied, right now, without being annoyed"))],
            fallback: .none
        ), (result["interrupt"]?.probability ?? 0) >= 0.85 else { return }
        lastClipboardNudge = Date()
        let button: AgentNudge.Button
        switch kind {
        case "web_link":
            button = .init(label: "Summarize page", icon: "safari", action: .prompt("Summarize the web page at \(text) in three bullet points."))
        case "code":
            button = .init(label: "Explain code", icon: "curlybraces", action: .prompt("Explain the code on my clipboard (use pbpaste) in two sentences."))
        default:
            button = .init(label: "Summarize", icon: "text.alignleft", action: .prompt("Summarize the text on my clipboard (use pbpaste) in two sentences."))
        }
        present(AgentNudge(icon: "doc.on.clipboard", tint: .systemPurple, title: "Copied \(kind.replacingOccurrences(of: "_", with: " "))",
                           detail: "\(text.count) characters", buttons: [button], source: result.source))
    }

    private func shouldInterrupt(_ result: DecisionResult) -> Bool {
        let threshold = result.source == .jev ? 0.7 : 0.5
        return (result["interrupt"]?.probability ?? 0) >= threshold && result["followup"]?.choice != "none"
    }

    private func present(_ nudge: AgentNudge) {
        lastNudgeAt = Date()
        nudgesThisHour.append(Date())
        self.nudge = nudge
        NotificationCenter.default.post(name: .agentNudge, object: nil)
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.nudge = nil
        }
    }

    private static func meetingLink(in event: EventModel) -> URL? {
        if let url = event.url, url.scheme?.hasPrefix("http") == true { return url }
        let haystack = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|webex\.com|whereby\.com)[^\s<>"]*"#
        guard let range = haystack.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(haystack[range]))
    }
}
