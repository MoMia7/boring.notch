import XCTest
@testable import RequestParsing

/// Synthesized whistles: a pitch glide per segment, with optional silence and noise.
private enum Synth {
    static let rate = 48_000.0

    /// Segments of (start Hz, end Hz, seconds); 0 Hz is silence.
    static func whistle(_ segments: [(Double, Double, Double)], amplitude: Float = 0.1, noise: Float = 0.001) -> [Float] {
        var out: [Float] = []
        var phase = 0.0
        var generator = SystemRandomNumberGenerator()
        for (from, to, seconds) in segments {
            let count = Int(seconds * rate)
            for i in 0..<count {
                let f = from + (to - from) * Double(i) / Double(count)
                phase += 2 * .pi * f / rate
                let tone = from == 0 ? 0 : amplitude * Float(sin(phase))
                out.append(tone + Float.random(in: -noise...noise, using: &generator))
            }
        }
        return out
    }

    /// Runs audio through the tracker and phraser like the live detector does; returns phrases.
    static func phrases(_ samples: [Float]) -> [WhistleContour] {
        var tracker = PitchTracker()
        var phraser = WhistlePhraser()
        var time = 0.0
        var found: [WhistleContour] = []
        let padded = samples + [Float](repeating: 0, count: Int(rate))  // trailing quiet ends the phrase
        for chunk in stride(from: 0, to: padded.count, by: 4800) {
            let slice = Array(padded[chunk..<min(chunk + 4800, padded.count)])
            let pitches = slice.withUnsafeBufferPointer { tracker.push($0, sampleRate: rate) }
            for pitch in pitches {
                time += Double(WhistleMatching.hopSize) / rate
                if let contour = phraser.push(time: time, pitch: pitch) { found.append(contour) }
            }
        }
        return found
    }

    static func phrase(_ segments: [(Double, Double, Double)]) -> WhistleContour? {
        phrases(whistle(segments)).first
    }
}

final class WhistlePitchTests: XCTestCase {
    func testPureToneIsMeasuredAccurately() {
        let frame = Array(Synth.whistle([(1000, 1000, 0.1)]).prefix(WhistleMatching.frameSize))
        let pitch = WhistleMatching.pitch(of: frame, sampleRate: Synth.rate)
        XCTAssertNotNil(pitch)
        XCTAssertEqual(pitch ?? 0, 83.21, accuracy: 0.1)  // 1 kHz ≈ MIDI 83.21
    }

    func testNoiseAndSilenceAreNotWhistles() {
        let noise = Synth.whistle([(0, 0, 0.1)], noise: 0.2)
        XCTAssertNil(WhistleMatching.pitch(of: Array(noise.prefix(WhistleMatching.frameSize)), sampleRate: Synth.rate))
        let silence = [Float](repeating: 0, count: WhistleMatching.frameSize)
        XCTAssertNil(WhistleMatching.pitch(of: silence, sampleRate: Synth.rate))
    }

    func testHarmonicRichSoundIsNotAWhistle() {
        // A voice-like buzz: 150 Hz with many equal harmonics.
        let frame = (0..<WhistleMatching.frameSize).map { i -> Float in
            (1...30).reduce(0) { $0 + 0.02 * Float(sin(2 * .pi * 150 * Double($1) * Double(i) / Synth.rate)) }
        }
        XCTAssertNil(WhistleMatching.pitch(of: frame, sampleRate: Synth.rate))
    }
}

final class WhistlePhraseTests: XCTestCase {
    func testTwoWhistlesSeparatedByQuietAreTwoPhrases() {
        let audio = Synth.whistle([(1200, 1200, 0.4), (0, 0, 0.8), (900, 1400, 0.4)])
        XCTAssertEqual(Synth.phrases(audio).count, 2)
    }

    func testShortGapStaysOnePhraseWithTwoNotes() {
        let phrases = Synth.phrases(Synth.whistle([(1200, 1200, 0.3), (0, 0, 0.15), (1600, 1600, 0.3)]))
        XCTAssertEqual(phrases.count, 1)
        XCTAssertEqual(phrases.first.map(WhistleMatching.noteCount), 2)
    }

    func testBlipsAndEndlessTonesAreIgnored() {
        XCTAssertTrue(Synth.phrases(Synth.whistle([(1200, 1200, 0.08)])).isEmpty)
        XCTAssertTrue(Synth.phrases(Synth.whistle([(1200, 1300, 6)])).isEmpty)
    }
}

final class WhistleMatchTests: XCTestCase {
    /// ~1400 Hz down to ~1050 Hz and back: the default "down then up".
    private let downUp: [(Double, Double, Double)] = [(1400, 1050, 0.35), (1050, 1400, 0.35)]

    func testDefaultPatternMatchesDownUpInAnyKeyAndTempo() throws {
        for (scale, tempo) in [(1.0, 1.0), (0.7, 1.0), (1.4, 1.0), (1.0, 1.5), (1.0, 0.7)] {
            let segments = downUp.map { ($0.0 * scale, $0.1 * scale, $0.2 * tempo) }
            let contour = try XCTUnwrap(Synth.phrase(segments))
            let result = WhistleMatching.match(contour, against: WhistleMatching.downUp)
            XCTAssertTrue(result.matched, "scale \(scale) tempo \(tempo): \(result.distance)")
        }
    }

    func testDefaultPatternRejectsOtherShapes() throws {
        let others: [[(Double, Double, Double)]] = [
            [(1050, 1400, 0.35), (1400, 1050, 0.35)],  // up then down
            [(1200, 1200, 0.7)],                       // one steady note
            [(1000, 1600, 0.7)],                       // rising
        ]
        for segments in others {
            let contour = try XCTUnwrap(Synth.phrase(segments))
            XCTAssertFalse(WhistleMatching.match(contour, against: WhistleMatching.downUp).matched, "\(segments)")
        }
    }

    func testRecordedPatternMatchesItselfButNotOthers() throws {
        // Three notes: low, high, middle (with small variations between takes).
        func take(_ wobble: Double) -> WhistleContour? {
            Synth.phrase([(1000 * wobble, 1000 * wobble, 0.2), (0, 0, 0.1), (1500 * wobble, 1500 * wobble, 0.2),
                          (0, 0, 0.1), (1250 * wobble, 1250 * wobble, 0.3)])
        }
        let takes = try [1.0, 1.05, 0.96].map { try XCTUnwrap(take($0)) }
        let pattern = try WhistleMatching.makePattern(from: takes).get()
        XCTAssertTrue(WhistleMatching.match(try XCTUnwrap(take(1.1)), against: pattern).matched)

        let reversed = try XCTUnwrap(Synth.phrase([(1250, 1250, 0.3), (0, 0, 0.1), (1500, 1500, 0.2),
                                                   (0, 0, 0.1), (1000, 1000, 0.2)]))
        XCTAssertFalse(WhistleMatching.match(reversed, against: pattern).matched)
        XCTAssertFalse(WhistleMatching.match(try XCTUnwrap(Synth.phrase(downUp)), against: pattern).matched)
    }

    func testPatternRecordingRejectsPlainOrMismatchedTakes() throws {
        let flat = try XCTUnwrap(Synth.phrase([(1200, 1200, 0.6)]))
        XCTAssertEqual(WhistleMatching.makePattern(from: [flat, flat, flat]), .failure(.tooPlain))

        let a = try XCTUnwrap(Synth.phrase(downUp))
        let b = try XCTUnwrap(Synth.phrase([(1000, 1600, 0.7)]))
        XCTAssertEqual(WhistleMatching.makePattern(from: [a, a, b]), .failure(.inconsistent))
    }
}

final class WhistleCommandTests: XCTestCase {
    private func threeNotes(_ notes: [Double], wobble: Double = 1) -> WhistleContour? {
        var segments: [(Double, Double, Double)] = []
        for (index, hz) in notes.enumerated() {
            if index > 0 { segments.append((0, 0, 0.1)) }
            segments.append((hz * wobble, hz * wobble, 0.2))
        }
        return Synth.phrase(segments)
    }

    private func pattern(_ notes: [Double]) throws -> WhistlePattern {
        let takes = try [1.0, 1.04, 0.97].map { try XCTUnwrap(threeNotes(notes, wobble: $0)) }
        return try WhistleMatching.makePattern(from: takes).get()
    }

    func testBestMatchPicksTheRightCommand() throws {
        let rising = try pattern([1000, 1250, 1500])
        let falling = try pattern([1500, 1250, 1000])
        let patterns = [WhistleMatching.downUp, rising, falling]

        let a = try XCTUnwrap(threeNotes([1000, 1250, 1500], wobble: 1.08))
        XCTAssertEqual(WhistleMatching.bestMatch(a, among: patterns)?.index, 1)
        XCTAssertEqual(WhistleMatching.bestMatch(a, among: patterns)?.matched, true)

        let b = try XCTUnwrap(threeNotes([1500, 1250, 1000], wobble: 0.95))
        XCTAssertEqual(WhistleMatching.bestMatch(b, among: patterns)?.index, 2)

        let c = try XCTUnwrap(Synth.phrase([(1400, 1050, 0.35), (1050, 1400, 0.35)]))
        XCTAssertEqual(WhistleMatching.bestMatch(c, among: patterns)?.index, 0)

        let other = try XCTUnwrap(threeNotes([1250, 1000, 1500]))
        XCTAssertEqual(WhistleMatching.bestMatch(other, among: patterns)?.matched, false)
    }

    func testOverlapCatchesLookalikes() throws {
        let rising = try pattern([1000, 1250, 1500])
        XCTAssertTrue(WhistleMatching.overlaps(rising, try pattern([1050, 1310, 1580])))
        XCTAssertFalse(WhistleMatching.overlaps(rising, try pattern([1500, 1250, 1000])))
        XCTAssertFalse(WhistleMatching.overlaps(rising, WhistleMatching.downUp))
    }
}
