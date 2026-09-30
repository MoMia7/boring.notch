//
//  QuickActions.swift
//  boringNotch
//
//  Instant actions: one Jev decision routes simple requests ("mute", "open Slack",
//  "next song") straight to a native action, skipping the local LLM entirely.
//  Anything else, or anything Jev isn't sure about, goes to the agent as usual.
//

import AppKit
import Defaults
import Foundation
import OSLog

private let log = Logger(subsystem: "io.otron.notch", category: "instant")

@MainActor
final class QuickActions {
    static let shared = QuickActions()

    private struct Action {
        let id: String
        let description: String
        let label: String
        let icon: String
        /// Whether the action takes a level (0–100) from the "level" question.
        var usesLevel = false
        /// For actions whose result text is only known after running (nil = failed → agent).
        var dynamicRun: (@MainActor () async -> String?)? = nil
        let run: @MainActor (_ app: URL?, _ level: Float) async -> Void
    }

    private lazy var actions: [Action] = [
        Action(id: "volume_up", description: "Turn the volume up a step (no specific level given)", label: "Volume up", icon: "speaker.wave.3.fill") { _, _ in
            VolumeManager.shared.increase()
        },
        Action(id: "volume_down", description: "Turn the volume down a step (no specific level given)", label: "Volume down", icon: "speaker.wave.1.fill") { _, _ in
            VolumeManager.shared.decrease()
        },
        Action(id: "set_volume", description: "Set the volume to a stated level such as max, half, off or a percentage", label: "Volume set", icon: "speaker.wave.2.fill", usesLevel: true) { _, level in
            VolumeManager.shared.setAbsolute(level)
        },
        Action(id: "set_brightness", description: "Set the screen brightness to a stated level such as max, half or a percentage", label: "Brightness set", icon: "sun.max.fill", usesLevel: true) { _, level in
            BrightnessManager.shared.setAbsolute(value: level)
        },
        Action(id: "mute_toggle", description: "Mute or unmute the sound", label: "Toggled mute", icon: "speaker.slash.fill") { _, _ in
            VolumeManager.shared.toggleMuteAction()
        },
        Action(id: "brightness_up", description: "Make the screen brighter", label: "Brightness up", icon: "sun.max.fill") { _, _ in
            BrightnessManager.shared.setRelative(delta: 0.1)
        },
        Action(id: "brightness_down", description: "Make the screen dimmer", label: "Brightness down", icon: "sun.min.fill") { _, _ in
            BrightnessManager.shared.setRelative(delta: -0.1)
        },
        Action(id: "play_pause", description: "Play, pause or resume the current music or media", label: "Play/pause", icon: "playpause.fill") { _, _ in
            MusicManager.shared.togglePlay()
        },
        Action(id: "next_track", description: "Skip to the next song or track", label: "Next track", icon: "forward.fill") { _, _ in
            MusicManager.shared.nextTrack()
        },
        Action(id: "previous_track", description: "Go back to the previous song or track", label: "Previous track", icon: "backward.fill") { _, _ in
            MusicManager.shared.previousTrack()
        },
        Action(id: "open_app", description: "Open, launch or switch to an application", label: "Opened", icon: "app.badge") { app, _ in
            guard let app else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: config)
        },
        Action(id: "dark_mode", description: "Switch between dark mode and light mode", label: "Toggled dark mode", icon: "circle.lefthalf.filled") { _, _ in
            await AgentManager.shared.runShell(#"osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode'"#)
        },
        Action(id: "sleep_display", description: "Turn off / sleep the display right now", label: "Display asleep", icon: "moon.fill") { _, _ in
            await AgentManager.shared.runShell("pmset displaysleepnow")
        },
        Action(id: "screenshot", description: "Take a screenshot of the whole screen", label: "Screenshot saved to Desktop", icon: "camera.viewfinder") { _, _ in
            await AgentManager.shared.runShell(#"screencapture -x ~/Desktop/"Screenshot $(date +%Y-%m-%d\ at\ %H.%M.%S).png""#)
        },
        Action(id: "play_music", description: "Play a specific song, artist, album, playlist or liked songs (music, Spotify)", label: "Playing", icon: "music.note") { _, _ in },
        Action(id: "spotify_shuffle", description: "Turn shuffle on or off", label: "Shuffle", icon: "shuffle", dynamicRun: {
            guard let on = await SpotifyClient.shared.toggleShuffle() else { return nil }
            return on ? "Shuffle on" : "Shuffle off"
        }) { _, _ in },
        Action(id: "like_song", description: "Like, save or heart the song that is playing now", label: "Liked", icon: "heart.fill", dynamicRun: {
            guard let name = await SpotifyClient.shared.likeCurrentTrack() else { return nil }
            return "Liked \(name)"
        }) { _, _ in },
        Action(id: "now_playing", description: "Tell what song is playing right now", label: "Now playing", icon: "music.note", dynamicRun: {
            let music = MusicManager.shared
            guard !music.songTitle.isEmpty else { return "Nothing is playing" }
            return music.artistName.isEmpty ? music.songTitle : "\(music.songTitle) — \(music.artistName)"
        }) { _, _ in },
        Action(id: "add_reminder", description: "Create a reminder or to-do, optionally at a time or date", label: "Reminder", icon: "checklist") { _, _ in },
        Action(id: "add_event", description: "Add an event or block time on the calendar at a date/time", label: "Event", icon: "calendar.badge.plus") { _, _ in },
        Action(id: "set_timer", description: "Start a countdown timer for a length of time", label: "Timer", icon: "timer") { _, _ in },
        Action(id: "cancel_timer", description: "Stop or cancel the running timer", label: "Timer cancelled", icon: "timer", dynamicRun: {
            AgentTimers.shared.cancelNext()
        }) { _, _ in },
        Action(id: "run_shortcut", description: "Run one of the user's Shortcuts (Shortcuts app) by name", label: "Ran shortcut", icon: "square.stack.3d.up.fill") { _, _ in },
        Action(id: "open_downloads", description: "Open the Downloads folder", label: "Opened Downloads", icon: "arrow.down.circle") { _, _ in
            await AgentManager.shared.runShell("open ~/Downloads")
        },
    ]

    // MARK: - Music

    private static let musicKinds: [(String, String)] = [
        ("track", "A specific song"),
        ("artist", "Music by an artist (no specific song)"),
        ("album", "An album"),
        ("my_playlist", "One of the user's own playlists (\"my ... playlist\")"),
        ("playlist", "A public playlist, genre or mood playlist"),
        ("liked_songs", "The user's liked or saved songs"),
        ("none", "Not a request to play music"),
    ]

    private func playMusic(request: String, kind: String) async -> (label: String, icon: String)? {
        let (query, artist) = RequestParsing.musicQuery(from: request)
        let spotify = SpotifyClient.shared
        guard kind != "none", !query.isEmpty || kind == "liked_songs" else { return nil }

        guard spotify.isConnected else {
            // Without a login we can still open the search in Spotify.
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            guard let url = URL(string: "spotify:search:\(encoded)") else { return nil }
            NSWorkspace.shared.open(url)
            return ("Searching Spotify for “\(query)”", "magnifyingglass")
        }

        var choice: SpotifyItem?
        switch kind {
        case "liked_songs":
            if let uri = spotify.likedSongsURI { choice = SpotifyItem(uri: uri, name: "Liked Songs", subtitle: "") }
        case "my_playlist":
            choice = await pickBest(request: request, query: query, from: await spotify.myPlaylists(),
                                    question: "Which of the user's playlists does the request mean?")
            if choice == nil {
                choice = await pickBest(request: request, query: query, from: await spotify.search(query, kind: "playlist"),
                                        question: "Which playlist best matches the request?")
            }
        default:
            let type = ["track", "artist", "album", "playlist"].contains(kind) ? kind : "track"
            var q = query
            if let artist, type == "track" || type == "album" { q = "\(type):\(query) artist:\(artist)" }
            choice = await pickBest(request: request, query: query, from: await spotify.search(q, kind: type),
                                    question: "Which result best matches what the user asked to play?")
        }
        guard let choice, await spotify.play(uri: choice.uri) else { return nil }
        log.notice("ran play_music kind=\(kind, privacy: .public)")
        let label = choice.subtitle.isEmpty ? "Playing \(choice.name)" : "Playing \(choice.name) — \(choice.subtitle)"
        return (label, "music.note")
    }

    /// Takes an exact name match when there is one; otherwise lets Jev choose among the candidates.
    private func pickBest(request: String, query: String, from items: [SpotifyItem], question: String) async -> SpotifyItem? {
        guard !items.isEmpty else { return nil }
        let q = query.lowercased()
        if let exact = items.first(where: { $0.name.lowercased() == q }) { return exact }
        if items.count == 1 { return items[0] }
        let candidates = Array(items.prefix(250))
        var options = candidates.enumerated().map { ("r\($0.offset)", $0.element.subtitle.isEmpty ? $0.element.name : "\($0.element.name) — \($0.element.subtitle)") }
        options.append(("none", "None of these match"))
        guard let result = await DecisionEngine.shared.decide(
            state: ["request": request], questions: [("pick", .choice(question, options))], timeout: 1.5
        ), let id = result["pick"]?.choice else { return candidates.first }
        if id == "none" { return nil }
        guard let index = Int(id.dropFirst()), candidates.indices.contains(index) else { return candidates.first }
        return (result["pick"]?.confidence ?? 0) >= 0.3 ? candidates[index] : candidates.first
    }

    /// Level words for set_volume / set_brightness. Ids are "p_<percent>". Explicit numbers are
    /// parsed from the text instead (see `statedPercent`).
    private static let levelOptions: [(String, String)] = [
        ("p_0", "Off, silent, zero or muted"),
        ("p_10", "Very low, barely audible"),
        ("p_25", "A quarter, low"),
        ("p_50", "Half, medium, halfway"),
        ("p_75", "Three quarters, fairly high"),
        ("p_100", "Max, maximum, full, all the way up"),
        ("none", "No level is stated in words"),
    ]

    private var appCache: [(id: String, name: String, url: URL)] = []
    private var appCacheDate = Date.distantPast

    /// Returns a label/icon for the action that was performed, or nil if the agent should handle it.
    func tryHandle(_ request: String) async -> (label: String, icon: String)? {
        guard Defaults[.jevInstantActions], request.count <= 80 else { return nil }
        guard DecisionEngine.shared.jevAvailable else {
            log.notice("skipped: Jev unavailable (key saved: \(DecisionEngine.shared.hasJevKey, privacy: .public), last error: \(DecisionEngine.shared.lastJevError ?? "none", privacy: .public))")
            return nil
        }

        let apps = installedApps()
        if shortcuts.isEmpty || Date().timeIntervalSince(shortcutsFetchedAt) > 600 {
            Task { await refreshShortcuts() }
        }
        var actionOptions = actions.map { action -> (String, String) in
            // Name the user's shortcuts so "morning routine" routes here without the word "run".
            if action.id == "run_shortcut", !shortcuts.isEmpty {
                return (action.id, action.description + ", e.g. " + shortcuts.prefix(25).joined(separator: ", "))
            }
            return (action.id, action.description)
        }
        actionOptions.append(("agent", "Anything else: questions, multi-step tasks, files, calendar, reminders, messages, or anything needing text, names, numbers or times"))
        var appOptions = apps.map { ($0.id, $0.name) }
        appOptions.append(("none", "No application is mentioned"))

        guard let result = await DecisionEngine.shared.decide(
            state: ["request": request],
            questions: [
                ("action", .choice("Which single action does this request ask for?", actionOptions)),
                ("app", .choice("Which application, if any, does the request name?", appOptions)),
                ("level", .choice("What level (percent) does the request state, if any?", Self.levelOptions)),
                ("music_kind", .choice("If this is a request to play music, what should be played?", Self.musicKinds)),
                ("specifics", .noul("The request needs a specific time, date, message, file or amount other than an application name, a volume/brightness level, or music to play; or it asks for more than one thing")),
            ],
            fallback: .none,
            timeout: 1.5
        ) else {
            log.notice("no decision for \(request, privacy: .private): \(DecisionEngine.shared.lastJevError ?? "unknown", privacy: .public)")
            return nil
        }
        let summary = "action=\(result["action"]?.choice ?? "-")@\(result["action"]?.confidence ?? 0) " +
            "app=\(result["app"]?.choice ?? "-") level=\(result["level"]?.choice ?? "-")@\(result["level"]?.confidence ?? 0) " +
            "specifics=\(result["specifics"]?.probability ?? -1) \(Int(result.latency * 1000))ms"
        log.notice("decision: \(summary, privacy: .public)")

        guard let actionID = result["action"]?.choice, actionID != "agent",
              (result["action"]?.confidence ?? 0) >= 0.75,
              let action = actions.first(where: { $0.id == actionID }) else { return nil }
        // Actions whose whole point is a specific time, text or name skip the "specifics" guard.
        switch action.id {
        case "play_music":
            return await playMusic(request: request, kind: result["music_kind"]?.choice ?? "track")
        case "add_reminder":
            return await InstantPlanning.addReminder(from: request).map { ($0, action.icon) }
        case "add_event":
            return await InstantPlanning.addEvent(from: request).map { ($0, action.icon) }
        case "set_timer":
            guard let seconds = RequestParsing.duration(in: request) else { return nil }
            return (AgentTimers.shared.start(seconds, label: RequestParsing.timerLabel(from: request)), action.icon)
        case "run_shortcut":
            return await runShortcut(request: request).map { ($0, action.icon) }
        default:
            break
        }
        guard (result["specifics"]?.probability ?? 1) < 0.5 else { return nil }
        if let dynamicRun = action.dynamicRun {
            guard let label = await dynamicRun() else { return nil }
            log.notice("ran \(action.id, privacy: .public)")
            return (label, action.icon)
        }

        var level: Float = 0
        if action.usesLevel {
            // Numbers are read in code (exact); Jev only resolves words like "max" or "half".
            if let number = RequestParsing.statedPercent(in: request) {
                level = number / 100
            } else {
                guard let raw = result["level"]?.choice, let percent = Float(raw.dropFirst(2)),
                      (result["level"]?.confidence ?? 0) >= 0.7 else { return nil }
                level = percent / 100
            }
        }

        var appURL: URL?
        var label = action.label
        if action.id == "open_app" {
            guard let appID = result["app"]?.choice, appID != "none",
                  (result["app"]?.confidence ?? 0) >= 0.7,
                  let app = apps.first(where: { $0.id == appID }) else { return nil }
            appURL = app.url
            label = "Opened \(app.name)"
        }
        if action.usesLevel { label += " to \(Int(level * 100))%" }
        await action.run(appURL, level)
        log.notice("ran \(action.id, privacy: .public)")
        return (label, action.icon)
    }

    /// Words the speech recognizer should expect: app names and music names.
    func vocabulary() -> [String] {
        var words = installedApps().map(\.name)
        words += ["Spotify", "Notch", "dark mode", "Downloads"]
        words += SpotifyClient.shared.cachedPlaylistNames
        words += shortcuts
        return Array(Set(words)).sorted()
    }

    // MARK: - Shortcuts

    private var shortcuts: [String] = []
    private var shortcutsFetchedAt = Date.distantPast

    func refreshShortcuts() async {
        let names = await XPCHelperClient.shared.listShortcuts()
        guard !names.isEmpty else { return }
        shortcuts = names
        shortcutsFetchedAt = Date()
    }

    private func runShortcut(request: String) async -> String? {
        if shortcuts.isEmpty { await refreshShortcuts() }
        guard !shortcuts.isEmpty else { return nil }
        let query = request.lowercased()
            .replacingOccurrences(of: #"^(hey\s+)?(notch[,\s]+)?(please\s+)?(run|start|do|trigger|launch)\s+(my\s+|the\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+shortcut[.!?]*$|[.!?]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var name = shortcuts.first { $0.lowercased() == query }
        if name == nil {
            var options = shortcuts.prefix(250).enumerated().map { ("s\($0.offset)", $0.element) }
            options.append(("none", "None of these"))
            if let result = await DecisionEngine.shared.decide(
                state: ["request": request],
                questions: [("shortcut", .choice("Which of the user's Shortcuts does the request mean?", options))],
                timeout: 1.5
            ), let id = result["shortcut"]?.choice, id != "none", (result["shortcut"]?.confidence ?? 0) >= 0.5,
               let index = Int(id.dropFirst()), shortcuts.indices.contains(index) {
                name = shortcuts[index]
            }
        }
        guard let name, await XPCHelperClient.shared.runShortcut(name) else { return nil }
        log.notice("ran shortcut")
        return "Ran \(name)"
    }

    // MARK: - Installed apps

    private func installedApps() -> [(id: String, name: String, url: URL)] {
        if Date().timeIntervalSince(appCacheDate) < 600, !appCache.isEmpty { return appCache }
        var home = NSHomeDirectory()
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { home = String(cString: dir) }
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"]
        var seen = Set<String>()
        var found: [(String, URL)] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                let display = String(name.dropLast(4))
                guard seen.insert(display.lowercased()).inserted else { continue }
                found.append((display, URL(fileURLWithPath: root).appendingPathComponent(name)))
            }
        }
        found.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        // Jev allows up to 255 options per question; leave room for "none".
        appCache = found.prefix(250).enumerated().map { ("app_\($0.offset)", $0.element.0, $0.element.1) }
        appCacheDate = Date()
        return appCache
    }
}
