import Foundation
import CoreML
import NaturalLanguage
import Accelerate

/// How much text one passage of the meaning index holds.
enum PassageSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Characters a passage should reach before it closes at the next sentence end.
    var target: Int { self == .small ? 30 : self == .medium ? 60 : 120 }
    /// A single sentence longer than this is split, so nothing is cut off by the model's limit.
    var longest: Int { tokens - 4 }
    /// Tokens the language model reads per passage, and passages per batch.
    var tokens: Int { self == .small ? 48 : self == .medium ? 96 : 160 }
    var batch: Int { self == .small ? 64 : self == .medium ? 32 : 16 }
    var explanation: String {
        switch self {
        case .small: return "a sentence or two (about 30 characters)"
        case .medium: return "a few sentences (about 60 characters)"
        case .large: return "a short paragraph (about 120 characters)"
        }
    }
}

/// Turns passages into unit vectors whose dot product measures closeness in meaning.
protocol TextEmbedder: AnyObject {
    var key: String { get }         // sub-folder name for stored vectors
    var label: String { get }       // shown to the user
    var dim: Int { get }
    /// Called once before use; `samples` supplies representative passages if calibration is needed.
    func prepare(dir: URL, samples: () -> [String], status: (String) -> Void) -> Bool
    func embed(_ texts: [String], size: PassageSize) -> [[Float]?]
}

func unitVector(_ v: [Float]) -> [Float] {
    var out = v
    var norm: Float = 0
    vDSP_svesq(out, 1, &norm, vDSP_Length(out.count))
    norm = norm.squareRoot()
    if norm > 0 { var d = norm; vDSP_vsdiv(out, 1, &d, &out, 1, vDSP_Length(out.count)) }
    return out
}

// MARK: - Apple's built-in model (fallback)

final class AppleEmbedder: TextEmbedder {
    let key = "apple"
    let label = "the Mac's built-in language model"
    let dim = 512
    private var pool: [NLContextualEmbedding] = []
    private var mean: [Float]?

    static var available: Bool { NLContextualEmbedding(language: .traditionalChinese) != nil }

    private func make() -> NLContextualEmbedding? {
        guard let e = NLContextualEmbedding(language: .traditionalChinese) else { return nil }
        if !e.hasAvailableAssets {
            let sem = DispatchSemaphore(value: 0)
            e.requestAssets { _, _ in sem.signal() }
            sem.wait()
        }
        do { try e.load() } catch { return nil }
        return e
    }

    private func raw(_ e: NLContextualEmbedding, _ s: String) -> [Float]? {
        guard !s.isEmpty, let r = try? e.embeddingResult(for: s, language: .traditionalChinese) else { return nil }
        var acc = [Double](repeating: 0, count: dim)
        var n = 0
        r.enumerateTokenVectors(in: s.startIndex..<s.endIndex) { v, _ in
            if v.count == self.dim { for i in 0..<v.count { acc[i] += v[i] }; n += 1 }
            return true
        }
        guard n > 0 else { return nil }
        return acc.map { Float($0 / Double(n)) }
    }

    private func rawBatch(_ texts: [String]) -> [[Float]?] {
        var out = [[Float]?](repeating: nil, count: texts.count)
        let l = NSLock()
        var next = 0
        DispatchQueue.concurrentPerform(iterations: pool.count) { w in
            while true {
                l.lock(); let i = next; next += 1; l.unlock()
                if i >= texts.count { break }
                let v = raw(pool[w], texts[i])
                l.lock(); out[i] = v; l.unlock()
            }
        }
        return out
    }

    /// The raw vectors all point in a similar direction; subtracting the corpus
    /// average makes similarities far more discriminating.
    func prepare(dir: URL, samples: () -> [String], status: (String) -> Void) -> Bool {
        if pool.isEmpty { for _ in 0..<4 { if let e = make() { pool.append(e) } } }
        if pool.isEmpty { return false }
        if mean != nil { return true }
        let url = dir.appendingPathComponent("mean.f32")
        if let d = try? Data(contentsOf: url), d.count == dim * 4 {
            mean = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return true
        }
        status("Calibrating the language model…")
        var sum = [Double](repeating: 0, count: dim)
        var n = 0
        for v in rawBatch(samples()) { if let v = v { for k in 0..<dim { sum[k] += Double(v[k]) }; n += 1 } }
        guard n > 0 else { return false }
        let m = sum.map { Float($0 / Double(n)) }
        mean = m
        m.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: url) }
        return true
    }

    func embed(_ texts: [String], size: PassageSize) -> [[Float]?] {
        guard let m = mean else { return [[Float]?](repeating: nil, count: texts.count) }
        return rawBatch(texts.map { String($0.prefix(240)) }).map { v in
            guard var x = v else { return nil }
            for i in 0..<x.count { x[i] -= m[i] }
            return unitVector(x)
        }
    }
}

// MARK: - SentencePiece (unigram) tokenizer, as used by XLM-RoBERTa / BGE-M3

final class UnigramTokenizer {
    private var child: [UInt64: Int32] = [:]     // (node << 21 | scalar) -> node
    private var nodeId: [Int32] = [-1]
    private var nodeScore: [Float] = [0]
    private var unkScore: Float = -20
    let bos: Int32 = 0, pad: Int32 = 1, eos: Int32 = 2, unk: Int32 = 3

    init?(vocab url: URL) {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        var minScore: Float = 0
        var id: Int32 = 0
        child.reserveCapacity(1 << 20)
        // split on line feeds only: some pieces contain other Unicode line separators
        for sub in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { id += 1 }
            guard id > 3, let tab = sub.lastIndex(of: "\t"),
                  let score = Float(String(String.UnicodeScalarView(sub[sub.index(after: tab)...]))) else { continue }
            var node: Int32 = 0
            for s in sub[..<tab] {
                let k = UInt64(node) << 21 | UInt64(s.value)
                if let n = child[k] { node = n } else {
                    let n = Int32(nodeId.count)
                    nodeId.append(-1); nodeScore.append(0)
                    child[k] = n
                    node = n
                }
            }
            if node != 0 && nodeId[Int(node)] < 0 {
                nodeId[Int(node)] = id; nodeScore[Int(node)] = score
                if score < minScore { minScore = score }
            }
        }
        if id < 1000 { return nil }
        unkScore = minScore - 10
    }

    /// Token ids including the opening and closing markers, at most `maxLen` long.
    func encode(_ s: String, maxLen: Int) -> [Int32] {
        var out: [Int32] = [bos]
        let norm = s.precomposedStringWithCompatibilityMapping
        var word: [UInt32] = []
        func flush() {
            if word.isEmpty { return }
            viterbi([0x2581] + word, into: &out)
            word.removeAll(keepingCapacity: true)
        }
        for u in norm.unicodeScalars {
            if u.properties.isWhitespace || u.value < 0x20 || u.value == 0x7F || u.value == 0x200B || u.value == 0xFEFF {
                flush()
            } else {
                word.append(u.value)
            }
            if out.count >= maxLen { break }
        }
        flush()
        if out.count > maxLen - 1 { out.removeLast(out.count - (maxLen - 1)) }
        out.append(eos)
        return out
    }

    private func viterbi(_ w: [UInt32], into out: inout [Int32]) {
        let n = w.count
        var best = [Float](repeating: -.infinity, count: n + 1)
        var from = [Int32](repeating: 0, count: n + 1)
        var tok = [Int32](repeating: 3, count: n + 1)
        best[0] = 0
        for i in 0..<n {
            let base = best[i]
            if base == -.infinity { continue }
            var node: Int32 = 0
            var j = i
            var single = false
            while j < n, let nx = child[UInt64(node) << 21 | UInt64(w[j])] {
                node = nx
                j += 1
                let id = nodeId[Int(node)]
                if id >= 0 {
                    let sc = base + nodeScore[Int(node)]
                    if sc > best[j] { best[j] = sc; from[j] = Int32(i); tok[j] = id }
                    if j == i + 1 { single = true }
                }
            }
            if !single {
                let sc = base + unkScore
                if sc > best[i + 1] { best[i + 1] = sc; from[i + 1] = Int32(i); tok[i + 1] = unk }
            }
        }
        var rev: [Int32] = []
        var p = n
        while p > 0 { rev.append(tok[p]); p = Int(from[p]) }
        var lastUnk = false
        for t in rev.reversed() {
            if t == unk { if lastUnk { continue }; lastUnk = true } else { lastUnk = false }
            out.append(t)
        }
    }
}

// MARK: - BGE-M3 through Core ML

final class BGEEmbedder: TextEmbedder {
    let key = "bge-m3"
    let label = "the BGE-M3 language model"
    let dim = 1024
    private let dir: URL
    private var models: [PassageSize: MLModel] = [:]
    private var tok: UnigramTokenizer?
    private let lock = NSLock()

    static func installed(in dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("bge-m3.mlmodelc").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("vocab.txt").path)
    }

    init?(dir: URL) {
        guard BGEEmbedder.installed(in: dir) else { return nil }
        self.dir = dir
    }

    func prepare(dir _: URL, samples: () -> [String], status: (String) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tok != nil { return true }
        status("Loading the language model (the first time can take a minute)…")
        guard let t = UnigramTokenizer(vocab: dir.appendingPathComponent("vocab.txt")) else { return false }
        tok = t
        return true
    }

    /// The model compiled for one passage size. The package holds one function
    /// per size (fixed input shapes run far faster on the GPU than flexible ones).
    private func model(for size: PassageSize) -> MLModel? {
        if let m = models[size] { return m }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU
        cfg.functionName = size.rawValue
        guard let m = try? MLModel(contentsOf: dir.appendingPathComponent("bge-m3.mlmodelc"), configuration: cfg) else { return nil }
        models[size] = m
        return m
    }


    func embed(_ texts: [String], size: PassageSize) -> [[Float]?] {
        var out = [[Float]?](repeating: nil, count: texts.count)
        guard let tok = tok, !texts.isEmpty else { return out }
        let maxLen = size.tokens
        var ids = [[Int32]](repeating: [], count: texts.count)
        ids.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            DispatchQueue.concurrentPerform(iterations: texts.count) { i in (base + i).pointee = tok.encode(texts[i], maxLen: maxLen) }
        }
        lock.lock(); defer { lock.unlock() }
        guard let model = model(for: size) else { return out }
        var k = 0
        while k < ids.count {
            let rows = Array(k..<min(k + size.batch, ids.count))
            if let vecs = run(model, rows.map { ids[$0] }, batch: size.batch, len: maxLen) {
                for (r, i) in rows.enumerated() { out[i] = vecs[r] }
            }
            k += rows.count
        }
        return out
    }

    private func run(_ model: MLModel, _ rows: [[Int32]], batch: Int, len: Int) -> [[Float]]? {
        guard let a = try? MLMultiArray(shape: [NSNumber(value: batch), NSNumber(value: len)], dataType: .int32),
              let m = try? MLMultiArray(shape: [NSNumber(value: batch), NSNumber(value: len)], dataType: .int32) else { return nil }
        let ap = a.dataPointer.bindMemory(to: Int32.self, capacity: batch * len)
        let mp = m.dataPointer.bindMemory(to: Int32.self, capacity: batch * len)
        for r in 0..<batch {
            // unused rows of a batch repeat the first passage
            let row = r < rows.count ? rows[r] : rows[0]
            for c in 0..<len {
                ap[r * len + c] = c < row.count ? row[c] : 1
                mp[r * len + c] = c < row.count ? 1 : 0
            }
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": a, "attention_mask": m]),
              let res = try? model.prediction(from: input),
              let e = res.featureValue(for: "embedding")?.multiArrayValue, e.count >= batch * dim else { return nil }
        var out: [[Float]] = []
        for r in 0..<rows.count {
            var v = [Float](repeating: 0, count: dim)
            if e.dataType == .float32 {
                let p = e.dataPointer.bindMemory(to: Float.self, capacity: e.count)
                for d in 0..<dim { v[d] = p[r * dim + d] }
            } else {
                for d in 0..<dim { v[d] = e[r * dim + d].floatValue }
            }
            out.append(unitVector(v))
        }
        return out
    }
}
