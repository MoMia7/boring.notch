//
//  WhistleMatching.swift
//  boringNotch
//
//  Pure signal code for the whistle trigger: pitch tracking (a whistle is close to a pure
//  tone, so one FFT peak is enough), cutting the stream into phrases, and comparing a
//  phrase's pitch contour to the user's pattern. Matching is by shape, not absolute pitch
//  or exact tempo. Foundation + Accelerate only so it can be unit tested with `swift test`.
//

import Accelerate
import Foundation

/// A whistled phrase: pitch in semitones (MIDI numbers) every `step` seconds, nil where silent.
struct WhistleContour: Codable, Equatable {
    static let step: Double = 0.05
    var pitches: [Float?]

    var duration: Double { Double(pitches.count) * Self.step }
    var voicedDuration: Double { Double(pitches.compactMap { $0 }.count) * Self.step }
}

/// The user's trigger: a few takes of the same phrase and how far a new phrase may stray.
struct WhistlePattern: Codable, Equatable {
    var takes: [WhistleContour]
    var threshold: Float
    var isCustom = true
}

enum WhistleMatching {

    // MARK: Pitch

    static let frameSize = 2048
    static let hopSize = 1024
    /// Quieter than this is ignored (RMS, full scale = 1).
    static let minLevel: Float = 0.002
    /// Share of the band's energy that must sit in the peak; whistles ≈ 0.9, speech ≈ 0.3.
    static let minTonality: Float = 0.6

    private static let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(frameSize))), radix: .radix2, ofType: DSPSplitComplex.self)!
    private static let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)

    /// Pitch of one `frameSize` frame in semitones, or nil if it isn't a whistle.
    static func pitch(of frame: [Float], sampleRate: Double) -> Float? {
        let n = frameSize
        guard frame.count == n, vDSP.rootMeanSquare(frame) >= minLevel else { return nil }
        let windowed = vDSP.multiply(frame, window)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        power[0] = 0  // DC (and the packed Nyquist term)

        let binHz = sampleRate / Double(n)
        let bandLow = max(1, Int(200 / binHz)), bandHigh = min(Int(8000 / binHz), n / 2 - 1)
        let peakLow = max(bandLow + 2, Int(400 / binHz)), peakHigh = min(Int(4500 / binHz), bandHigh - 2)
        guard peakLow < peakHigh else { return nil }
        var peak = peakLow
        for k in peakLow...peakHigh where power[k] > power[peak] { peak = k }

        let total = power[bandLow...bandHigh].reduce(0, +)
        guard total > 0, power[(peak - 2)...(peak + 2)].reduce(0, +) / total >= minTonality else { return nil }

        // Parabolic interpolation between bins for sub-bin accuracy.
        let a = log(power[peak - 1] + 1e-12), b = log(power[peak] + 1e-12), c = log(power[peak + 1] + 1e-12)
        let denominator = a - 2 * b + c
        let offset = denominator == 0 ? 0 : 0.5 * (a - c) / denominator
        let frequency = (Double(peak) + Double(offset)) * binHz
        return Float(69 + 12 * log2(frequency / 440))
    }

    /// Bins tracked frames into a contour, trimmed to the first and last whistled frame.
    static func contour(from frames: [(time: Double, pitch: Float?)]) -> WhistleContour? {
        guard let start = frames.first(where: { $0.pitch != nil })?.time,
              let end = frames.last(where: { $0.pitch != nil })?.time else { return nil }
        let step = WhistleContour.step
        let count = Int((end - start) / step) + 1
        var bins = Array(repeating: [Float?](), count: count)
        for frame in frames where frame.time >= start && frame.time <= end {
            bins[min(count - 1, Int((frame.time - start) / step))].append(frame.pitch)
        }
        return WhistleContour(pitches: bins.map { bin in
            let voiced = bin.compactMap { $0 }.sorted()
            guard !voiced.isEmpty, voiced.count * 2 >= bin.count else { return nil }
            return voiced[voiced.count / 2]
        })
    }

    // MARK: Matching

    /// Phrases whose lengths differ more than this never match.
    static let maxTempoRatio = 2.2
    /// Takes that differ more than this from each other can't form a pattern.
    static let maxTakeSpread: Float = 1.0
    /// Both phrases are stretched to this many points before comparing...
    private static let compareLength = 24
    /// ...and then may only shift locally by this many points (≈17%) to line up.
    private static let warpBand = 4

    /// Average per-point difference in semitones once both phrases are stretched to the same
    /// length, centred on their own median pitch, and lined up with a little local slack
    /// (banded DTW). 0 = identical shape; a different shape is well above 1.
    static func distance(_ a: WhistleContour, _ b: WhistleContour) -> Float {
        let x = centred(a), y = centred(b)
        guard !x.isEmpty, !y.isEmpty,
              Double(max(x.count, y.count)) / Double(min(x.count, y.count)) <= maxTempoRatio else { return .infinity }
        let p = stretched(x), q = stretched(y)
        let n = compareLength, width = n + 1
        var cost = [Float](repeating: .infinity, count: width * width)
        var steps = [Int](repeating: 0, count: width * width)
        cost[0] = 0
        for i in 1...n {
            for j in max(1, i - warpBand)...min(n, i + warpBand) {
                let diagonal = (i - 1) * width + j - 1, up = (i - 1) * width + j, left = i * width + j - 1
                var best = diagonal
                if cost[up] < cost[best] { best = up }
                if cost[left] < cost[best] { best = left }
                cost[i * width + j] = cost[best] + pointCost(p[i - 1], q[j - 1])
                steps[i * width + j] = steps[best] + 1
            }
        }
        return cost[n * width + n] / Float(steps[n * width + n])
    }

    /// Best distance to any take, and whether that's within the pattern's threshold.
    static func match(_ contour: WhistleContour, against pattern: WhistlePattern) -> (matched: Bool, distance: Float) {
        let best = pattern.takes.map { distance(contour, $0) }.min() ?? .infinity
        // A steady note must not pass for a small slide: the phrase has to move about as much.
        let expected = pattern.takes.map(range).reduce(0, +) / Float(max(1, pattern.takes.count))
        let moved = range(contour)
        let similarRange = moved >= expected * 0.5 && moved <= max(expected * 2.5, 2)
        return (best <= pattern.threshold && similarRange, best)
    }

    /// The closest pattern by distance relative to its threshold; matches always beat non-matches.
    /// Returned even when nothing matched, for diagnostics.
    static func bestMatch(_ contour: WhistleContour, among patterns: [WhistlePattern]) -> (index: Int, matched: Bool, distance: Float)? {
        var best: (index: Int, matched: Bool, distance: Float, score: Float)?
        for (index, pattern) in patterns.enumerated() {
            let result = match(contour, against: pattern)
            let score = (result.matched ? 0 : 1000) + result.distance / pattern.threshold
            if best == nil || score < best!.score { best = (index, result.matched, result.distance, score) }
        }
        return best.map { ($0.index, $0.matched, $0.distance) }
    }

    /// Whether two patterns are close enough that one could set off the other.
    static func overlaps(_ a: WhistlePattern, _ b: WhistlePattern) -> Bool {
        a.takes.contains { match($0, against: b).matched } || b.takes.contains { match($0, against: a).matched }
    }

    /// Pitch span in semitones.
    static func range(_ contour: WhistleContour) -> Float {
        let voiced = contour.pitches.compactMap { $0 }
        guard let low = voiced.min(), let high = voiced.max() else { return 0 }
        return high - low
    }

    enum PatternError: Error, Equatable {
        case tooFewTakes
        /// The takes don't sound like the same phrase.
        case inconsistent
        /// One steady note: any whistle or kettle would trigger it.
        case tooPlain
    }

    /// Builds a pattern from recorded takes; the threshold adapts to how consistent they were.
    static func makePattern(from takes: [WhistleContour]) -> Result<WhistlePattern, PatternError> {
        guard takes.count >= 2 else { return .failure(.tooFewTakes) }
        guard takes.allSatisfy(isDistinctive) else { return .failure(.tooPlain) }
        var spread: Float = 0
        for i in takes.indices {
            for j in takes.indices where j > i { spread = max(spread, distance(takes[i], takes[j])) }
        }
        guard spread <= maxTakeSpread else { return .failure(.inconsistent) }
        return .success(WhistlePattern(takes: takes, threshold: min(max(spread * 1.5 + 0.3, 0.8), 1.2)))
    }

    /// Changes pitch by at least two semitones, or has more than one note.
    static func isDistinctive(_ contour: WhistleContour) -> Bool {
        range(contour) >= 2 || noteCount(contour) >= 2
    }

    static func noteCount(_ contour: WhistleContour) -> Int {
        var notes = 0, previousVoiced = false
        for pitch in contour.pitches {
            if pitch != nil && !previousVoiced { notes += 1 }
            previousVoiced = pitch != nil
        }
        return notes
    }

    /// Built-in pattern until the user records one: a slide down and back up (about 0.7 s).
    static let downUp: WhistlePattern = {
        let down = (0..<7).map { Float?(-Float($0) * 5 / 6) }
        let up = (0..<7).map { Float?(-5 + Float($0) * 5 / 6) }
        return WhistlePattern(takes: [WhistleContour(pitches: down + up)], threshold: 1.0, isCustom: false)
    }()

    private static func centred(_ contour: WhistleContour) -> [Float?] {
        let voiced = contour.pitches.compactMap { $0 }.sorted()
        guard !voiced.isEmpty else { return [] }
        let median = voiced[voiced.count / 2]
        return contour.pitches.map { $0.map { $0 - median } }
    }

    private static func stretched(_ pitches: [Float?]) -> [Float?] {
        (0..<compareLength).map { i in
            pitches[min(pitches.count - 1, Int((Double(i) + 0.5) * Double(pitches.count) / Double(compareLength)))]
        }
    }

    private static func pointCost(_ a: Float?, _ b: Float?) -> Float {
        switch (a, b) {
        case let (a?, b?): return min(abs(a - b), 6)
        case (nil, nil): return 0
        default: return 3
        }
    }
}

/// Streaming audio → per-hop pitches.
struct PitchTracker {
    private var buffer: [Float] = []

    mutating func push(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> [Float?] {
        buffer.append(contentsOf: samples)
        var pitches: [Float?] = []
        while buffer.count >= WhistleMatching.frameSize {
            pitches.append(WhistleMatching.pitch(of: Array(buffer.prefix(WhistleMatching.frameSize)), sampleRate: sampleRate))
            buffer.removeFirst(WhistleMatching.hopSize)
        }
        return pitches
    }

    mutating func reset() { buffer.removeAll() }
}

/// Cuts per-hop pitches into phrases: a phrase ends after `endSilence` without whistling.
/// Sounds longer than `maxLength` (music, a kettle) are dropped until it's quiet again.
struct WhistlePhraser {
    static let endSilence = 0.4
    static let maxLength = 4.0
    static let minVoiced = 0.2

    private var frames: [(time: Double, pitch: Float?)] = []
    private var start: Double = 0
    private var lastVoiced: Double?
    private var tooLong = false

    mutating func push(time: Double, pitch: Float?) -> WhistleContour? {
        if pitch != nil {
            if lastVoiced == nil {
                frames = []
                start = time
            }
            lastVoiced = time
            if time - start > Self.maxLength { tooLong = true }
            if !tooLong { frames.append((time, pitch)) }
            return nil
        }
        guard let last = lastVoiced else { return nil }
        if !tooLong { frames.append((time, nil)) }
        guard time - last >= Self.endSilence else { return nil }
        lastVoiced = nil
        defer { frames = []; tooLong = false }
        guard !tooLong, let contour = WhistleMatching.contour(from: frames),
              contour.voicedDuration >= Self.minVoiced else { return nil }
        return contour
    }

    mutating func reset() {
        frames = []
        lastVoiced = nil
        tooLong = false
    }
}
