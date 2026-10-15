//
//  LayaEngine.swift
//  boringNotch
//
//  On-device decisions with Laya, a small encoder distilled from Jev. It answers the same typed
//  questions in one forward pass of a Core ML model; nothing leaves the Mac.
//
//  The input format mirrors laya_distill's "packed" layout exactly (laya-distill repo):
//      [CLS] <q1 block> <q2 block> ... state [SEP]
//      block = "<type> question: <instructions>" [SEP] [MASK] opt0 [MASK] opt1 ... [SEP]
//  Each [MASK] is an option marker; the model scores every token and we read the markers.
//

import CoreML
import Foundation
import OSLog

private let log = Logger(subsystem: "io.otron.notch", category: "laya")

/// Constants written next to the model by laya_distill.export_coreml (laya.json).
struct LayaFormat: Decodable {
    let format: Int
    let max_len: Int
    let head_max_len: Int
    let option_tokens: Int
    let question_tokens: Int
    let qtypes: [String: Int]
    let none_type: Int
    let cls: Int
    let sep: Int
    let mask: Int
    let mask_token: String
    let temperatures: [String: Double]
}

actor LayaEngine {
    static let shared = LayaEngine()

    private var model: MLModel?
    private var tokenizer: LayaTokenizer?
    private var format: LayaFormat?
    private var loadedFrom: URL?
    private var lastUse = Date.distantPast
    private var loading: Task<Void, Error>?

    /// Unload after this long without a question; reloading takes a few seconds.
    private let idleUnload: TimeInterval = 30 * 60

    var isLoaded: Bool { model != nil }

    /// Loads (compiling on first use) the model in `dir`; cheap when it is already loaded.
    func load(from dir: URL) async throws {
        if model != nil, loadedFrom == dir { return }
        if let loading { return try await loading.value }
        let task = Task {
            let started = Date()
            let format = try JSONDecoder().decode(LayaFormat.self, from: Data(contentsOf: dir.appendingPathComponent("laya.json")))
            let tokenizer = try LayaTokenizer(url: dir.appendingPathComponent("tokenizer.json"))
            let compiled = try await Self.compiledModel(in: dir)
            let config = MLModelConfiguration()
            // GPU, not the Neural Engine: the ANE recompiles for every new input length (seconds each)
            config.computeUnits = .cpuAndGPU
            let model = try MLModel(contentsOf: compiled, configuration: config)
            self.finishLoad(model: model, tokenizer: tokenizer, format: format, dir: dir)
            log.notice("laya loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
        }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func finishLoad(model: MLModel, tokenizer: LayaTokenizer, format: LayaFormat, dir: URL) {
        self.model = model
        self.tokenizer = tokenizer
        self.format = format
        self.loadedFrom = dir
        lastUse = Date()
        scheduleIdleUnload()
    }

    func unload() {
        model = nil
        tokenizer = nil
        format = nil
        loadedFrom = nil
    }

    private func scheduleIdleUnload() {
        Task {
            try? await Task.sleep(for: .seconds(idleUnload + 5))
            if model != nil, Date().timeIntervalSince(lastUse) >= idleUnload {
                log.notice("laya unloaded after idle")
                unload()
            }
        }
    }

    /// Compiles Laya.mlpackage once and keeps the .mlmodelc next to it.
    private static func compiledModel(in dir: URL) async throws -> URL {
        let target = dir.appendingPathComponent("Laya.mlmodelc")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let temp = try await MLModel.compileModel(at: dir.appendingPathComponent("Laya.mlpackage"))
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    // MARK: - Deciding

    /// - Parameter stateText: the state as `LayaJSON.serialize` writes it.
    func decide(stateText: String, questions: [(String, DecisionQuestion)]) throws -> DecisionResult? {
        guard let model, let tokenizer, let format else { return nil }
        let started = Date()
        lastUse = Date()

        let stateIDs = tokenizer.encode(stateText.replacingOccurrences(of: format.mask_token, with: " "))

        // Question blocks, packed greedily into sequences of at most head_max_len tokens.
        var blocks: [Block] = []
        for (id, question) in questions {
            let block = Self.block(id: id, question: question, tokenizer: tokenizer, format: format)
            // As in training: a question whose block alone is too long is skipped.
            if block.tokens.count <= format.head_max_len { blocks.append(block) }
        }
        var groups: [[Block]] = []
        var current: [Block] = []
        var used = 0
        for block in blocks {
            if !current.isEmpty, used + block.tokens.count > format.head_max_len {
                groups.append(current)
                current = []
                used = 0
            }
            current.append(block)
            used += block.tokens.count
        }
        if !current.isEmpty { groups.append(current) }

        var answers: [String: DecisionAnswer] = [:]
        for group in groups {
            var ids = [format.cls]
            var types = [format.none_type]
            var markers: [(Block, [Int])] = []
            for block in group {
                let start = ids.count
                ids += block.tokens
                types += Array(repeating: block.qtype, count: block.tokens.count)
                markers.append((block, block.markers.map { start + $0 }))
            }
            let room = max(0, format.max_len - ids.count - 1)
            ids += stateIDs.prefix(room)
            ids.append(format.sep)
            types += Array(repeating: format.none_type, count: ids.count - types.count)

            let scores = try Self.predict(model: model, ids: ids, types: types)
            for (block, positions) in markers {
                let logits = positions.map { Double(scores[$0]) }
                answers[block.id] = Self.answer(block: block, logits: logits, format: format)
            }
        }
        return DecisionResult(answers: answers, source: .laya, latency: Date().timeIntervalSince(started))
    }

    private struct Block {
        let id: String
        let question: DecisionQuestion
        let optionIDs: [String]
        let qtypeName: String
        let qtype: Int
        let tokens: [Int]
        let markers: [Int]
    }

    private static func block(id: String, question: DecisionQuestion, tokenizer: LayaTokenizer, format: LayaFormat) -> Block {
        let typeName: String
        let instructions: String
        let optionIDs: [String]
        let optionTexts: [String]
        switch question {
        case .choice(let ins, let options):
            typeName = "choice"
            instructions = ins
            optionIDs = options.map(\.0)
            optionTexts = options.map { $0.1.isEmpty ? $0.0 : "\($0.0): \($0.1)" }
        case .score(let ins, let levels):
            typeName = "score"
            instructions = ins
            optionIDs = levels.indices.map(String.init)
            optionTexts = levels.enumerated().map { "level \($0.offset): \($0.element)" }
        case .noul(let ins):
            typeName = "noul"
            instructions = ins
            optionIDs = ["false", "true"]
            optionTexts = ["false: no, the statement does not hold", "true: yes, the statement holds"]
        }
        let mask = format.mask_token
        let head = Array(tokenizer.encode("\(typeName) question: \(instructions.replacingOccurrences(of: mask, with: " "))")
            .prefix(format.question_tokens))
        var body: [Int] = []
        var markers: [Int] = []
        for text in optionTexts {
            markers.append(head.count + 1 + body.count)
            body.append(format.mask)
            body += tokenizer.encode(" " + text.replacingOccurrences(of: mask, with: " ")).prefix(format.option_tokens)
        }
        return Block(id: id, question: question, optionIDs: optionIDs, qtypeName: typeName,
                     qtype: format.qtypes[typeName] ?? 0, tokens: head + [format.sep] + body + [format.sep], markers: markers)
    }

    private static func predict(model: MLModel, ids: [Int], types: [Int]) throws -> [Float] {
        let n = ids.count
        let idArray = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let typeArray = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let idPtr = idArray.dataPointer.bindMemory(to: Int32.self, capacity: n)
        let typePtr = typeArray.dataPointer.bindMemory(to: Int32.self, capacity: n)
        for i in 0..<n {
            idPtr[i] = Int32(ids[i])
            typePtr[i] = Int32(types[i])
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": idArray, "tok_type": typeArray])
        let output = try model.prediction(from: input)
        guard let scores = output.featureValue(for: "scores")?.multiArrayValue else {
            throw CocoaError(.featureUnsupported)
        }
        return (0..<n).map { scores[[0, NSNumber(value: $0)]].floatValue }
    }

    private static func answer(block: Block, logits: [Double], format: LayaFormat) -> DecisionAnswer {
        let k = logits.count
        let size = k <= 2 ? "2" : k <= 5 ? "3-5" : k <= 10 ? "6-10" : "11+"
        let temperature = format.temperatures["\(block.qtypeName):\(size)"] ?? format.temperatures[block.qtypeName] ?? 1
        let scaled = logits.map { $0 / max(1e-3, temperature) }
        let top = scaled.max() ?? 0
        let exps = scaled.map { exp($0 - top) }
        let total = exps.reduce(0, +)
        let probs = exps.map { $0 / total }
        let best = probs.indices.max(by: { probs[$0] < probs[$1] }) ?? 0
        switch block.question {
        case .noul:
            let p = probs[1]
            return DecisionAnswer(probability: p, confidence: max(p, 1 - p))
        case .choice:
            return DecisionAnswer(choice: block.optionIDs[best], confidence: probs[best])
        case .score:
            return DecisionAnswer(score: Double(best), confidence: probs[best])
        }
    }
}

/// JSON text exactly as Python's json.dumps(value, ensure_ascii=False) writes it, which is what
/// Laya was trained on. Keys are sorted: Swift dictionaries have no order to preserve.
enum LayaJSON {
    static func serialize(_ value: Any) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: Any, into out: inout String) {
        switch value {
        case let s as String:
            writeString(s, into: &out)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out += n.boolValue ? "true" : "false"
            } else if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                out += d.isFinite ? pythonFloat(d) : (d.isNaN ? "NaN" : (d > 0 ? "Infinity" : "-Infinity"))
            } else {
                out += n.stringValue
            }
        case let b as Bool:
            out += b ? "true" : "false"
        case let i as Int:
            out += String(i)
        case let d as Double:
            out += pythonFloat(d)
        case let dict as [String: Any]:
            out += "{"
            for (i, key) in dict.keys.sorted().enumerated() {
                if i > 0 { out += ", " }
                writeString(key, into: &out)
                out += ": "
                write(dict[key]!, into: &out)
            }
            out += "}"
        case let list as [Any]:
            out += "["
            for (i, item) in list.enumerated() {
                if i > 0 { out += ", " }
                write(item, into: &out)
            }
            out += "]"
        case is NSNull:
            out += "null"
        default:
            writeString(String(describing: value), into: &out)
        }
    }

    /// Python's float repr. Swift's description is also the shortest round-trip form ("0.1",
    /// "100.0", "1e-05", "1e+16"), so the two agree for finite values.
    private static func pythonFloat(_ d: Double) -> String {
        "\(d)"
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
