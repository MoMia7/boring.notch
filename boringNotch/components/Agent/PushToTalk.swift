//
//  PushToTalk.swift
//  boringNotch
//
//  Hold a single modifier key (Right Option by default) to talk to the agent.
//  Audio starts on key-down so the first word isn't clipped; if another key is
//  pressed within the hold threshold, it was a shortcut and the audio is discarded.
//

import AppKit
import Defaults
import OSLog
import SwiftUI

private let log = Logger(subsystem: "io.otron.notch", category: "voice")

enum PushToTalkKey: String, CaseIterable, Defaults.Serializable, Identifiable {
    case rightOption
    case rightCommand
    case rightControl
    case fn
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "Fn / Globe"
        case .off: return "Off"
        }
    }

    var shortName: String {
        switch self {
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        case .fn: return "fn"
        case .off: return ""
        }
    }

    fileprivate var keyCode: UInt16? {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        case .off: return nil
        }
    }

    fileprivate var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        case .off: return []
        }
    }
}

extension Defaults.Keys {
    static let pushToTalkKey = Key<PushToTalkKey>("pushToTalkKey", default: .rightOption)
    static let pushToTalkDucking = Key<Bool>("pushToTalkDucking", default: true)
}

extension Notification.Name {
    static let agentVoiceStarted = Notification.Name("agentVoiceStarted")
}

@MainActor
final class PushToTalk {
    static let shared = PushToTalk()

    /// Holds shorter than this are treated as taps/shortcuts and ignored.
    private let holdThreshold: TimeInterval = 0.1

    private var monitors: [Any] = []
    private var pressedAt: Date?
    private var confirmed = false
    private var confirmTask: Task<Void, Never>?
    /// Volume before ducking, restored when the key is released.
    private var duckedFrom: Float32?

    private init() {}

    func start() {
        guard monitors.isEmpty else { return }
        VoiceInput.shared.warmUp()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in PushToTalk.shared.handle(event) }
        }) {
            monitors.append(global)
        }
        // Also see events while the notch panel itself has keyboard focus.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in PushToTalk.shared.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        let key = Defaults[.pushToTalkKey]
        guard let code = key.keyCode else { return }

        switch event.type {
        case .keyDown:
            // Another key during the threshold means it's a shortcut (e.g. ⌥-letter).
            if pressedAt != nil && !confirmed { abort() }
        case .flagsChanged where event.keyCode == code:
            let isDown = event.modifierFlags.contains(key.flag)
            if isDown {
                // Only start when the key is pressed on its own.
                let others = event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).subtracting(key.flag)
                guard others.isEmpty, pressedAt == nil else { return }
                keyDown()
            } else {
                keyUp()
            }
        case .flagsChanged:
            // A different modifier joined in before we confirmed: it's a chord, not push-to-talk.
            if pressedAt != nil && !confirmed { abort() }
        default:
            break
        }
    }

    private func keyDown() {
        pressedAt = Date()
        confirmed = false
        VoiceInput.shared.begin()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.holdThreshold ?? 0.1))
            guard let self, !Task.isCancelled, self.pressedAt != nil else { return }
            self.confirmed = true
            self.duck()
            NotificationCenter.default.post(name: .agentVoiceStarted, object: nil)
        }
    }

    private func keyUp() {
        guard pressedAt != nil else { return }
        pressedAt = nil
        confirmTask?.cancel()
        guard confirmed else {
            VoiceInput.shared.cancel()
            return
        }
        confirmed = false
        // Restore before running the command, so "volume to 75" isn't undone by the restore.
        restoreVolume()
        Task {
            let text = await VoiceInput.shared.end()
            guard !text.isEmpty else { return }
            log.notice("push-to-talk sending \(text.count) chars")
            AgentManager.shared.send(text, showResult: true)
        }
    }

    /// Halves the output volume while listening if something is playing, so you don't have to shout.
    private func duck() {
        guard Defaults[.pushToTalkDucking], MusicManager.shared.isPlaying, duckedFrom == nil else { return }
        let volume = VolumeManager.shared.currentVolume
        guard volume > 0.05 else { return }
        duckedFrom = volume
        VolumeManager.shared.setAbsoluteQuietly(volume * 0.5)
    }

    private func restoreVolume() {
        guard let volume = duckedFrom else { return }
        duckedFrom = nil
        VolumeManager.shared.setAbsoluteQuietly(volume)
    }

    private func abort() {
        restoreVolume()
        pressedAt = nil
        confirmed = false
        confirmTask?.cancel()
        VoiceInput.shared.cancel()
    }
}

struct PushToTalkKeyPicker: View {
    @Default(.pushToTalkKey) private var key

    var body: some View {
        Picker("Hold to talk:", selection: $key) {
            ForEach(PushToTalkKey.allCases) { option in
                Text(option.title).tag(option)
            }
        }
    }
}
