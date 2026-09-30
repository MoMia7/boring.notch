//
//  VoiceInput.swift
//  boringNotch
//
//  On-device speech-to-text for the agent using macOS 26's SpeechAnalyzer /
//  SpeechTranscriber (runs on the Neural Engine, no network, no GPU contention
//  with the local LLM). Audio is streamed while the push-to-talk key is held.
//

import AVFoundation
import Foundation
import OSLog
import Speech

private let log = Logger(subsystem: "io.otron.notch", category: "voice")

@MainActor
final class VoiceInput: ObservableObject {
    static let shared = VoiceInput()

    enum State: Equatable {
        case idle
        case listening
        case finishing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Finalized text plus the current volatile guess, for live display.
    @Published private(set) var transcript = ""
    /// 0…1 microphone level for the waveform.
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var session: AnyObject?  // VoiceSession (macOS 26+)
    private var startedAt = Date()

    private init() {}

    var isActive: Bool { state == .listening || state == .finishing }

    /// Loads the speech model ahead of time so the first utterance is fast.
    func warmUp() {
        guard #available(macOS 26, *) else { return }
        Task.detached(priority: .utility) {
            _ = try? await VoiceSession.ensureAssets()
        }
    }

    func begin() {
        guard state != .listening, state != .finishing else { return }
        guard #available(macOS 26, *) else {
            state = .failed("Voice input needs macOS 26")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            state = .failed("Allow microphone access, then hold the key again")
            return
        default:
            state = .failed("Microphone access is off — enable it in System Settings → Privacy")
            return
        }

        transcript = ""
        level = 0
        startedAt = Date()
        state = .listening
        let newSession = VoiceSession(engine: engine, vocabulary: QuickActions.shared.vocabulary()) { [weak self] text in
            Task { @MainActor in
                guard let self, self.state == .listening || self.state == .finishing else { return }
                self.transcript = text
            }
        } onLevel: { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        session = newSession
        Task {
            do {
                try await newSession.start()
            } catch {
                log.error("voice start failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                session = nil
            }
        }
    }

    /// Stops listening and returns the final transcript (empty if nothing was said).
    func end() async -> String {
        guard state == .listening, #available(macOS 26, *), let current = session as? VoiceSession else {
            if state == .listening { state = .idle }
            return ""
        }
        state = .finishing
        let text = await current.finish()
        session = nil
        state = .idle
        level = 0
        log.notice("voice: \(Int(Date().timeIntervalSince(self.startedAt) * 1000))ms held, \(text.count) chars")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Discards the current utterance (e.g. the key turned out to be part of a shortcut).
    func cancel() {
        guard #available(macOS 26, *), let current = session as? VoiceSession else {
            state = .idle
            return
        }
        session = nil
        state = .idle
        transcript = ""
        level = 0
        Task { await current.cancel() }
    }

    func clearError() {
        if case .failed = state { state = .idle }
    }
}

/// One utterance: microphone tap → format conversion → SpeechAnalyzer → text.
@available(macOS 26, *)
private final class VoiceSession: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let vocabulary: [String]
    private let onText: @Sendable (String) -> Void
    private let onLevel: @Sendable (Float) -> Void

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""

    init(engine: AVAudioEngine, vocabulary: [String], onText: @escaping @Sendable (String) -> Void, onLevel: @escaping @Sendable (Float) -> Void) {
        self.engine = engine
        self.vocabulary = vocabulary
        self.onText = onText
        self.onLevel = onLevel
    }

    static func locale() async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en_US")
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [])
    }

    @discardableResult
    static func ensureAssets() async throws -> SpeechTranscriber {
        let transcriber = makeTranscriber(locale: await locale())
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    func start() async throws {
        // Start capturing immediately so the first word isn't clipped; buffers queue in the stream.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        var pending: [AVAudioPCMBuffer] = []
        var analyzerFormat: AVAudioFormat?

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel(Self.rms(buffer))
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let format = analyzerFormat else {
                pending.append(buffer)  // analyzer still getting ready
                return
            }
            if let converted = self.convert(buffer, to: format) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        engine.prepare()
        try engine.start()

        let transcriber = try await Self.ensureAssets()
        self.transcriber = transcriber
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat)
            ?? inputFormat
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        // Bias recognition toward names it would otherwise mishear ("Arc" → "oc").
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(vocabulary.prefix(300))
            try? await analyzer.setContext(context)
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    self.lock.lock()
                    if result.isFinal {
                        self.finalized += text
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    let combined = self.finalized + self.volatile
                    self.lock.unlock()
                    self.onText(combined)
                }
            } catch {
                log.error("voice results error: \(error.localizedDescription, privacy: .public)")
            }
        }

        try await analyzer.start(inputSequence: stream)

        // Flush audio captured while the analyzer was starting.
        lock.lock()
        analyzerFormat = format
        for buffer in pending {
            if let converted = convert(buffer, to: format) { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
        pending.removeAll()
        lock.unlock()
    }

    func finish() async -> String {
        stopAudio()
        continuation?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            log.error("voice finalize error: \(error.localizedDescription, privacy: .public)")
        }
        await resultsTask?.value
        lock.lock()
        defer { lock.unlock() }
        return finalized + volatile
    }

    func cancel() async {
        stopAudio()
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // Map roughly -50 dB…-10 dB to 0…1.
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 40))
    }
}
