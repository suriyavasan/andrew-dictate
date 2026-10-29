import AVFoundation
import Foundation
import Speech

/// candidate A: Apple's DictationTranscriber, hi-IN, volatile results, on a
/// SpeechAnalyzer. paced on the wall clock because the recogniser is a system
/// service whose own timing is what is being measured.
final class AppleEngine: LiveEngine, @unchecked Sendable {
    let name = "apple-dictation-hi-IN"
    let clock = "real"
    let locale = Locale(identifier: "hi-IN")
    /// seconds of silence fed after the speech so the recogniser can settle (the same for every engine).
    let tail = 1.0

    private func makeTranscriber() -> DictationTranscriber {
        DictationTranscriber(
            locale: locale, contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
    }

    func prepare() async throws {
        let t = makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            print("installing the hi-IN dictation asset ...")
            try await request.downloadAndInstall()
        }
        let installed = await DictationTranscriber.installedLocales
        print("dictation installed locales include hi-IN:", installed.contains { $0.identifier(.bcp47) == "hi-IN" })
    }

    func run(_ samples: [Float]) async throws -> (captions: [Caption], language: String?, compute: Double) {
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw BenchError("no audio format for hi-IN dictation")
        }
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: format) else { throw BenchError("no converter to \(format)") }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let box = AppleBox()
        let t0 = now()

        let collector = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                box.add(text, final: result.isFinal, at: now() - t0)
            }
        }

        try await analyzer.start(inputSequence: stream)
        let total = samples.count + Int(tail * 16_000)
        var offset = 0
        while offset < total {
            // real-time pace: this chunk is complete at (offset + n) / 16000 seconds.
            let n = min(chunkSamples, total - offset)
            let due = t0 + Double(offset + n) / 16_000
            let wait = due - now()
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            let dst = buffer.floatChannelData![0]
            for k in 0..<n { dst[k] = offset + k < samples.count ? samples[offset + k] : 0 }
            let outCapacity = AVAudioFrameCount(Double(n) * format.sampleRate / 16_000) + 64
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity)!
            nonisolated(unsafe) var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            continuation.yield(AnalyzerInput(buffer: out))
            offset += n
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await collector.value
        let compute = now() - t0
        return (box.snapshot(), "hi-IN", compute)
    }
}

/// the finished lines plus the line still being revised, as one caption per result.
final class AppleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var captions: [Caption] = []
    private var settled: [String] = []
    func add(_ text: String, final: Bool, at: Double) {
        lock.lock(); defer { lock.unlock() }
        if final {
            if !text.isEmpty { settled.append(text) }
            captions.append(Caption(wall: at, text: settled.joined(separator: " "), final: true))
        } else {
            captions.append(Caption(wall: at, text: (settled + [text]).joined(separator: " "), final: false))
        }
    }
    func snapshot() -> [Caption] { lock.lock(); defer { lock.unlock() }; return captions }
}
