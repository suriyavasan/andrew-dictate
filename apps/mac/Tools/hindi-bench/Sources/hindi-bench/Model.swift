import Foundation

/// what is on screen at one moment: the whole current line, and whether it is settled.
struct Caption: Codable, Sendable {
    /// seconds after the unit's first sample was fed (real or simulated clock, see README).
    var wall: Double
    var text: String
    var final: Bool
}

/// one unit of audio: a FLEURS utterance, or a VAD stretch of a real clip.
struct Unit: Codable, Sendable {
    var id: String
    var clip: String
    /// seconds into the clip (0 for FLEURS).
    var start: Double
    var seconds: Double
    var refHi: String?
    var refEn: String?
    var wav: String
    /// for a stretch: the sample range inside the clip's wav.
    var from: Int?
    var to: Int?

    func samples() throws -> [Float] {
        let all = try readMono(URL(fileURLWithPath: wav))
        if let from, let to { return Array(all[min(from, all.count)..<min(to, all.count)]) }
        return all
    }
}

struct UnitResult: Codable, Sendable {
    var unit: Unit
    var captions: [Caption]
    var finalText: String
    /// whisper's detected language per unit; Nemotron auto reports its tag.
    var language: String?
    /// seconds of compute the engine spent on this unit.
    var compute: Double
    /// the speech span found in the audio, seconds from unit start.
    var spanStart: Double
    var spanEnd: Double
    /// whisper's task=translate text for the same audio, when asked for.
    var translated: String?
}

struct RunFile: Codable, Sendable {
    var engine: String
    var set: String
    var clock: String
    var peakMB: Double
    var modelMB: Double?
    var loadSeconds: Double
    var wallSeconds: Double
    var results: [UnitResult]
}

/// a streaming engine: audio goes in 100 ms at a time, captions come out.
protocol LiveEngine: AnyObject {
    var name: String { get }
    /// "real" when the engine is paced on the wall clock, "sim" when the clock is
    /// virtual: audio arrives at its real-time moment and compute is measured.
    var clock: String { get }
    func prepare() async throws
    func run(_ samples: [Float]) async throws -> (captions: [Caption], language: String?, compute: Double)
}

let chunkSamples = 1_600 // 100 ms at 16 kHz, like MeetingAudioChunk

/// where the speech is inside a unit: first and last 20 ms frame well above the noise.
func speechSpan(_ s: [Float]) -> (Double, Double) {
    let frame = 320
    guard s.count >= frame else { return (0, Double(s.count) / 16_000) }
    var rms: [Float] = []
    var i = 0
    while i + frame <= s.count {
        var sum: Float = 0
        for k in i..<i + frame { sum += s[k] * s[k] }
        rms.append((sum / Float(frame)).squareRoot())
        i += frame
    }
    let sorted = rms.sorted()
    let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
    let threshold = max(0.003, 0.15 * p90)
    let first = rms.firstIndex { $0 > threshold } ?? 0
    let last = rms.lastIndex { $0 > threshold } ?? rms.count - 1
    return (Double(first * frame) / 16_000, Double((last + 1) * frame) / 16_000)
}
