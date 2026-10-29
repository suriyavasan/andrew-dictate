import AVFoundation
import Foundation

let sampleRate = 16_000

struct BenchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// a 16 kHz mono wav, whole, as floats.
func readMono(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == Double(sampleRate) else {
        throw BenchError("\(url.lastPathComponent) is \(file.processingFormat.sampleRate) Hz, not \(sampleRate)")
    }
    let frames = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
        throw BenchError("could not allocate \(frames) frames")
    }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// `--name value` pairs and bare flags, in whatever order.
struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String], flags known: Set<String> = []) throws {
        var rest = arguments[...]
        while let key = rest.popFirst() {
            guard key.hasPrefix("--") else { throw BenchError("unexpected argument '\(key)'") }
            let name = String(key.dropFirst(2))
            if known.contains(name) {
                flags.insert(name)
            } else {
                guard let value = rest.popFirst() else { throw BenchError("--\(name) needs a value") }
                values[name] = value
            }
        }
    }

    func string(_ name: String) -> String? { values[name] }
    func require(_ name: String) throws -> String {
        guard let value = values[name] else { throw BenchError("--\(name) is required") }
        return value
    }
    func int(_ name: String, default fallback: Int) -> Int { values[name].flatMap(Int.init) ?? fallback }
    func double(_ name: String, default fallback: Double) -> Double { values[name].flatMap(Double.init) ?? fallback }
    func has(_ name: String) -> Bool { flags.contains(name) }
}

// MARK: - clocks and memory

func now() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

/// peak resident set size of this process so far, in megabytes.
func peakResidentMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576 // bytes on macOS
}

/// resident set size now, in megabytes.
func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    let rank = p * Double(s.count - 1)
    let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
    return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
}

func f(_ v: Double?, _ digits: Int = 2) -> String {
    guard let v else { return "-" }
    return String(format: "%.\(digits)f", v)
}

// MARK: - text: normalisation, error rates, scripts

enum TextTools {
    /// Devanagari-aware normalisation for WER/CER: NFC, lowercase, nukta dropped,
    /// chandrabindu folded to anusvara, joiners dropped, Devanagari digits to
    /// ASCII, punctuation and symbols (including the danda) removed, spaces collapsed.
    static func normalise(_ s: String) -> String {
        var out = ""
        for scalar in s.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x093C, 0x200C, 0x200D, 0x200B, 0xFEFF: continue // nukta, ZWNJ, ZWJ, ZWSP, BOM
            case 0x0901: out.unicodeScalars.append(UnicodeScalar(0x0902)!) // candrabindu -> anusvara
            case 0x0966...0x096F: out.unicodeScalars.append(UnicodeScalar(0x30 + scalar.value - 0x0966)!)
            default:
                let cat = scalar.properties.generalCategory
                switch cat {
                case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                     .initialPunctuation, .finalPunctuation, .otherPunctuation,
                     .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                    out.append(" ")
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        let lowered = out.precomposedStringWithCanonicalMapping.lowercased()
        return lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// (errors, reference length) for word and character error rate.
    static func wer(ref: String, hyp: String) -> (Int, Int) {
        let r = words(normalise(ref)), h = words(normalise(hyp))
        return (editDistance(r, h), r.count)
    }

    static func cer(ref: String, hyp: String) -> (Int, Int) {
        let r = Array(normalise(ref).filter { !$0.isWhitespace }), h = Array(normalise(hyp).filter { !$0.isWhitespace })
        return (editDistance(r, h), r.count)
    }

    static func arabicScriptCount(_ s: String) -> Int {
        s.unicodeScalars.filter {
            (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value)
                || (0xFB50...0xFDFF).contains($0.value) || (0xFE70...0xFEFF).contains($0.value)
        }.count
    }

    static func devanagariCount(_ s: String) -> Int {
        s.unicodeScalars.filter { (0x0900...0x097F).contains($0.value) }.count
    }

    static func latinCount(_ s: String) -> Int {
        s.unicodeScalars.filter { ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) }.count
    }

    /// unigram F1 against a reference, a crude stand-in for translation quality.
    static func unigramF1(ref: String, hyp: String) -> Double {
        let r = words(normalise(ref)), h = words(normalise(hyp))
        guard !r.isEmpty, !h.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for w in r { counts[w, default: 0] += 1 }
        var overlap = 0
        for w in h where (counts[w] ?? 0) > 0 { overlap += 1; counts[w]! -= 1 }
        guard overlap > 0 else { return 0 }
        let p = Double(overlap) / Double(h.count), q = Double(overlap) / Double(r.count)
        return 2 * p * q / (p + q)
    }
}
