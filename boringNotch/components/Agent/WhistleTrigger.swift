//
//  WhistleTrigger.swift
//  boringNotch
//
//  Whistle a short pattern to start listening hands-free, then say the request ("mute").
//  Whistle commands skip the talking: each is a pattern bound to a request it stands for.
//  While enabled the microphone stays open, but only pitch is measured (see
//  WhistleMatching); nothing is transcribed, stored or sent until the pattern matches.
//  Pauses while a Bluetooth headset is the input, since opening its mic drops it to
//  call-quality audio, and while the display sleeps or the screen is locked: an open
//  input keeps a "prevent idle sleep" assertion that would stop the Mac from sleeping.
//

import AppKit
import AVFoundation
import CoreAudio
import Defaults
import OSLog

private let log = Logger(subsystem: "io.otron.notch", category: "whistle")

extension WhistlePattern: Defaults.Serializable {}

/// A pattern that runs a request directly, as if it had been said ("mute", "next song").
struct WhistleCommand: Codable, Identifiable, Equatable, Defaults.Serializable {
    var id = UUID()
    var text: String
    var pattern: WhistlePattern
}

extension Defaults.Keys {
    static let whistleTrigger = Key<Bool>("whistleTrigger", default: false)
    static let whistlePattern = Key<WhistlePattern?>("whistlePattern", default: nil)
    static let whistleCommands = Key<[WhistleCommand]>("whistleCommands", default: [])
}

@MainActor
final class WhistleTrigger: ObservableObject {
    static let shared = WhistleTrigger()

    static let takesNeeded = 3

    struct Heard: Equatable {
        /// What it was closest to: "listen" or a command's text.
        let label: String
        let matched: Bool
        let distance: Float
        let threshold: Float
    }

    enum RecordingTarget: Equatable {
        case trigger
        case command(String)
    }

    @Published private(set) var isRunning = false
    @Published private(set) var pausedForBluetooth = false
    /// Takes recorded so far while recording a new pattern; nil when not recording.
    @Published private(set) var takes: [WhistleContour]?
    @Published private(set) var recordingTarget: RecordingTarget?
    @Published private(set) var message: String?
    /// The last phrase heard while not recording, for tuning in Settings.
    @Published private(set) var lastHeard: Heard?

    var pattern: WhistlePattern { Defaults[.whistlePattern] ?? WhistleMatching.downUp }
    var isRecording: Bool { takes != nil }

    private let engine = AVAudioEngine()
    private let processor = WhistleProcessor()
    private var observers: [Any] = []
    private var inputListener: AudioObjectPropertyListenerBlock?
    /// Display asleep, screen locked or screensaver running.
    private var away = false

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            Task { @MainActor in WhistleTrigger.shared.restart() }
        })
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in WhistleTrigger.shared.restart() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name, isAway) in [
            (workspace, NSWorkspace.screensDidSleepNotification, true),
            (workspace, NSWorkspace.screensDidWakeNotification, false),
            (workspace, NSWorkspace.willSleepNotification, true),
            (workspace, NSWorkspace.didWakeNotification, false),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), true),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), false),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screensaver.didstart"), true),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screensaver.didstop"), false),
        ] as [(NotificationCenter, Notification.Name, Bool)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in WhistleTrigger.shared.setAway(isAway) }
            })
        }
        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        inputListener = listener
        Task { [weak self] in
            for await _ in Defaults.updates(.whistleTrigger, initial: true) { self?.refresh() }
        }
    }

    // MARK: Recording

    func beginRecording(_ target: RecordingTarget = .trigger) {
        takes = []
        recordingTarget = target
        message = nil
        lastHeard = nil
        refresh()
    }

    func cancelRecording() {
        takes = nil
        recordingTarget = nil
        message = nil
        refresh()
    }

    func useDefaultPattern() {
        if let clash = Defaults[.whistleCommands].first(where: { WhistleMatching.overlaps($0.pattern, WhistleMatching.downUp) }) {
            message = "The default is too close to the pattern for “\(clash.text)”. Delete that command first, or record your own."
            return
        }
        Defaults[.whistlePattern] = nil
        message = "Using the default: a slide down and back up."
    }

    func deleteCommand(_ id: WhistleCommand.ID) {
        Defaults[.whistleCommands].removeAll { $0.id == id }
    }

    // MARK: Engine

    private func setAway(_ isAway: Bool) {
        guard away != isAway else { return }
        away = isAway
        log.notice("whistle \(isAway ? "paused" : "resumed", privacy: .public): display/lock")
        refresh()
    }

    /// Runs the microphone only when the trigger is on (or a pattern is being recorded),
    /// and someone could be there to whistle.
    private func refresh() {
        let wanted = (Defaults[.whistleTrigger] || isRecording) && !away
        guard wanted else {
            stop()
            pausedForBluetooth = false
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in WhistleTrigger.shared.refresh() }
            }
            return
        default:
            message = "Microphone access is off — enable it in System Settings → Privacy."
            stop()
            return
        }
        pausedForBluetooth = Self.inputIsBluetooth()
        if pausedForBluetooth { stop() } else if !isRunning { run() }
    }

    private func restart() {
        stop()
        refresh()
    }

    private func run() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        processor.reset(sampleRate: format.sampleRate)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(processor))
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            log.notice("whistle listening at \(Int(format.sampleRate)) Hz")
        } catch {
            input.removeTap(onBus: 0)
            log.error("whistle start failed: \(error.localizedDescription, privacy: .public)")
            message = "Couldn't open the microphone: \(error.localizedDescription)"
        }
    }

    private func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    nonisolated private static func tapBlock(_ processor: WhistleProcessor) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let contour = processor.process(buffer) else { return }
            Task { @MainActor in WhistleTrigger.shared.heard(contour) }
        }
    }

    // MARK: Phrases

    private func heard(_ contour: WhistleContour) {
        // Whistling while already talking to the notch is just noise.
        guard !VoiceInput.shared.isActive else { return }

        if var recorded = takes {
            recorded.append(contour)
            guard recorded.count >= Self.takesNeeded else {
                takes = recorded
                return
            }
            finishRecording(recorded)
            return
        }

        guard Defaults[.whistleTrigger] else { return }
        // The listening pattern is index 0, commands follow.
        let commands = Defaults[.whistleCommands]
        let patterns = [pattern] + commands.map(\.pattern)
        guard let best = WhistleMatching.bestMatch(contour, among: patterns) else { return }
        let command = best.index > 0 ? commands[best.index - 1] : nil
        lastHeard = Heard(label: command?.text ?? "listen", matched: best.matched,
                          distance: best.distance, threshold: patterns[best.index].threshold)
        log.notice("whistle heard: closest=\(best.index) \(String(format: "%.2f", best.distance), privacy: .public)/\(String(format: "%.2f", patterns[best.index].threshold), privacy: .public) matched=\(best.matched, privacy: .public)")
        guard best.matched else { return }
        if let command {
            // Same path as a spoken request; capture "this" first like push-to-talk does.
            ContextCapture.shared.begin(allowCopyFallback: false)
            AgentManager.shared.send(command.text, showResult: true)
        } else {
            NSSound(named: "Tink")?.play()
            PushToTalk.shared.listenHandsFree()
        }
    }

    private func finishRecording(_ recorded: [WhistleContour]) {
        let target = recordingTarget ?? .trigger
        takes = nil
        recordingTarget = nil
        defer { refresh() }

        let pattern: WhistlePattern
        switch WhistleMatching.makePattern(from: recorded) {
        case .success(let made):
            pattern = made
        case .failure(.tooPlain):
            message = "That was one steady note, which any whistle could trigger. Try one that moves up or down, or has a few notes."
            return
        case .failure:
            message = "Those takes didn't sound alike. Try again, whistling it the same way each time."
            return
        }

        // Every pattern must be distinguishable from the others.
        var others: [(name: String, pattern: WhistlePattern)] = Defaults[.whistleCommands].map { ("“\($0.text)”", $0.pattern) }
        if case .command = target { others.append(("listening", self.pattern)) }
        if let clash = others.first(where: { WhistleMatching.overlaps($0.pattern, pattern) }) {
            message = "That's too close to the pattern for \(clash.name). Try something more different."
            return
        }

        switch target {
        case .trigger:
            Defaults[.whistlePattern] = pattern
            message = "Saved. Whistle it, then say what you want."
        case .command(let text):
            Defaults[.whistleCommands].append(WhistleCommand(text: text, pattern: pattern))
            message = "Saved. Whistle it to run “\(text)”."
        }
    }

    // MARK: Input device

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func inputIsBluetooth() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Audio-thread side: samples → pitches → phrases.
private final class WhistleProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = PitchTracker()
    private var phraser = WhistlePhraser()
    private var sampleRate = 48_000.0
    private var time = 0.0

    func reset(sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = sampleRate
        tracker.reset()
        phraser.reset()
        time = 0
    }

    func process(_ buffer: AVAudioPCMBuffer) -> WhistleContour? {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let hop = Double(WhistleMatching.hopSize) / sampleRate
        var found: WhistleContour?
        for pitch in tracker.push(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)), sampleRate: sampleRate) {
            time += hop
            if let contour = phraser.push(time: time, pitch: pitch) { found = contour }
        }
        return found
    }
}
