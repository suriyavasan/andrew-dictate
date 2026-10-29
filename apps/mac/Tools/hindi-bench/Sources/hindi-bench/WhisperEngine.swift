import Foundation
import WhisperKit

enum WhisperMode: String {
    /// as the app runs it today: language nil, detection on.
    case auto
    /// the language forced to Hindi.
    case hi
    /// detection restricted to {hi, en}: argmax of whisper's language probabilities over those two.
    case hien
}

/// candidate C and C': WhisperKit large-v3 on one VAD stretch at a time, decoded
/// the way `WhisperMeetingTranscriber` does (temperature 0, timestamps on).
final class WhisperEngine: @unchecked Sendable {
    let name: String
    let mode: WhisperMode
    private var whisper: WhisperKit!
    var folder: URL!

    init(mode: WhisperMode) {
        self.mode = mode
        self.name = "whisper-large-v3-\(mode.rawValue)"
    }

    static func modelBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/whisperkit", isDirectory: true)
    }

    func prepare() async throws {
        let variant = "openai_whisper-large-v3"
        let base = Self.modelBase()
        folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path) else {
            throw BenchError("\(variant) is not on this mac (\(folder.path)); this tool never downloads whisper")
        }
        whisper = try await WhisperKit(WhisperKitConfig(
            model: variant, downloadBase: base, modelFolder: folder.path,
            verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
        // warm every path the run will use on real speech, so the first measured decode does not pay for CoreML specialisation
        if let warm = try? Units.fleurs(limit: 1).first?.samples() {
            for _ in 0..<2 {
                _ = try await decode(warm)
                _ = try await decode(warm, translate: true)
            }
        }
    }

    private func options(language: String?, detect: Bool, translate: Bool) -> DecodingOptions {
        var o = DecodingOptions()
        o.task = translate ? .translate : .transcribe
        o.language = language
        o.detectLanguage = detect
        o.usePrefillPrompt = true
        o.skipSpecialTokens = true
        o.withoutTimestamps = false
        o.temperature = 0
        // HINDI_BENCH_NO_FALLBACK=1 turns off whisper's temperature fallback, to see how much of the time it is.
        if ProcessInfo.processInfo.environment["HINDI_BENCH_NO_FALLBACK"] == "1" { o.temperatureFallbackCount = 0 }
        return o
    }

    /// returns the text, the language that was used or detected, and the seconds the decode took.
    func decode(_ samples: [Float], translate: Bool = false) async throws -> (text: String, language: String?, seconds: Double) {
        let t = now()
        var language: String?
        var detect = true
        switch mode {
        case .auto:
            language = nil
        case .hi:
            language = "hi"; detect = false
        case .hien:
            let (_, probs) = try await whisper.detectLangauge(audioArray: samples)
            let hi = probs["hi"] ?? -Float.infinity, en = probs["en"] ?? -Float.infinity
            language = hi >= en ? "hi" : "en"
            detect = false
        }
        var o = options(language: language, detect: detect, translate: translate)
        if samples.count > 30 * sampleRate { o.chunkingStrategy = .vad }
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: o)
        let text = results.flatMap(\.segments)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (text, results.first?.language ?? language, now() - t)
    }
}
