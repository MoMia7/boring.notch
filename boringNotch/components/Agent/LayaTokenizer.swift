//
//  LayaTokenizer.swift
//  boringNotch
//
//  Byte-level BPE (GPT-2 style, NFC-normalised, no prefix space) read from the model's
//  tokenizer.json, matching Hugging Face `tokenizers`: added tokens (whitespace runs such as
//  "  " and "   ", and the special tokens) are split out first, leftmost-longest, and the text
//  between them goes through the regex pre-tokenizer and BPE.
//

import Foundation

final class LayaTokenizer {
    private let vocab: [String: Int]
    private let ranks: [Pair: Int]
    private let byteToChar: [Character]
    /// Added tokens by first byte, longest first.
    private let added: [UInt8: [(bytes: [UInt8], id: Int)]]
    private var cache: [String: [Int]] = [:]
    private let lock = NSLock()

    // GPT-2's pre-tokenizer pattern, as used by ByteLevel(use_regex: true)
    private static let pattern = try! NSRegularExpression(
        pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
    )

    private struct Pair: Hashable {
        let a: String
        let b: String
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Int],
              let merges = model["merges"] as? [Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.vocab = vocab
        var ranks: [Pair: Int] = [:]
        for (rank, merge) in merges.enumerated() {
            // tokenizers writes merges either as "a b" or as ["a", "b"]
            if let s = merge as? String {
                let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 { ranks[Pair(a: parts[0], b: parts[1])] = rank }
            } else if let p = merge as? [String], p.count == 2 {
                ranks[Pair(a: p[0], b: p[1])] = rank
            }
        }
        self.ranks = ranks
        self.byteToChar = Self.bytesToUnicode()
        var added: [UInt8: [(bytes: [UInt8], id: Int)]] = [:]
        for token in json["added_tokens"] as? [[String: Any]] ?? [] {
            guard let content = token["content"] as? String, let id = token["id"] as? Int, !content.isEmpty else { continue }
            let bytes = Array(content.utf8)
            added[bytes[0], default: []].append((bytes, id))
        }
        self.added = added.mapValues { $0.sorted { $0.bytes.count > $1.bytes.count } }
    }

    func encode(_ text: String) -> [Int] {
        let bytes = Array(text.precomposedStringWithCanonicalMapping.utf8)
        var ids: [Int] = []
        var segmentStart = 0
        var i = 0
        while i < bytes.count {
            if let candidates = added[bytes[i]],
               let hit = candidates.first(where: { i + $0.bytes.count <= bytes.count && bytes[i..<(i + $0.bytes.count)].elementsEqual($0.bytes) }) {
                ids += encodeSegment(bytes[segmentStart..<i])
                ids.append(hit.id)
                i += hit.bytes.count
                segmentStart = i
            } else {
                i += 1
            }
        }
        ids += encodeSegment(bytes[segmentStart..<bytes.count])
        return ids
    }

    /// Plain text between added tokens: regex pre-tokenizer, then BPE per piece.
    private func encodeSegment(_ slice: ArraySlice<UInt8>) -> [Int] {
        guard !slice.isEmpty, let text = String(bytes: slice, encoding: .utf8) else { return [] }
        let ns = text as NSString
        var ids: [Int] = []
        for match in Self.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: match.range)
            ids += encodeWord(String(piece.utf8.map { byteToChar[Int($0)] }))
        }
        return ids
    }

    private func encodeWord(_ word: String) -> [Int] {
        lock.lock()
        if let hit = cache[word] { lock.unlock(); return hit }
        lock.unlock()

        var parts = word.map { String($0) }
        while parts.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(parts.count - 1) {
                if let r = ranks[Pair(a: parts[i], b: parts[i + 1])], r < (best?.rank ?? .max) {
                    best = (r, i)
                }
            }
            guard let (_, i) = best else { break }
            let a = parts[i], b = parts[i + 1]
            // merge every occurrence of this pair, left to right
            var merged: [String] = []
            var j = 0
            while j < parts.count {
                if j < parts.count - 1, parts[j] == a, parts[j + 1] == b {
                    merged.append(a + b)
                    j += 2
                } else {
                    merged.append(parts[j])
                    j += 1
                }
            }
            parts = merged
        }
        let ids = parts.compactMap { vocab[$0] }

        lock.lock()
        if cache.count > 20_000 { cache.removeAll() }
        cache[word] = ids
        lock.unlock()
        return ids
    }

    /// GPT-2's reversible byte -> printable character table.
    private static func bytesToUnicode() -> [Character] {
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bs, cs) {
            table[b] = Character(Unicode.Scalar(c)!)
        }
        return table
    }
}
