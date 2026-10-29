import FluidAudio
import Foundation

/// candidate B: NVIDIA Nemotron 3.5 ASR streaming 0.6B as FluidAudio 0.18 ships it
/// (CoreML, the full-vocabulary "multilingual" bundle, language chosen by prompt id).
/// the clock is simulated: 100 ms chunks arrive at their real-time moment, the
/// time each call takes is measured, and a call that starts late (the engine
/// was still busy) delays what follows.
final class NemotronEngine: LiveEngine, @unchecked Sendable {
    let name: String
    let clock = "sim"
    let chunkMs: Int
    let language: String
    private let manager = StreamingNemotronMultilingualAsrManager()
    private let box = Box()
    var modelDirectory: URL?

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var captions: [Caption] = []
        var origin = 0.0
        var offset = 0.0 // virtual seconds of the call in progress
        func add(_ text: String, final: Bool) {
            lock.lock(); defer { lock.unlock() }
            captions.append(Caption(wall: offset + (now() - origin), text: text, final: final))
        }
        func reset() { lock.lock(); captions = []; lock.unlock() }
        func begin(at virtual: Double) { lock.lock(); offset = virtual; origin = now(); lock.unlock() }
        func snapshot() -> [Caption] { lock.lock(); defer { lock.unlock() }; return captions }
    }

    init(chunkMs: Int, language: String) {
        self.chunkMs = chunkMs
        self.language = language
        self.name = "nemotron-3.5-\(language)-\(chunkMs)ms"
    }

    func prepare() async throws {
        let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(languageCode: language, chunkMs: chunkMs)
        modelDirectory = dir
        try await manager.loadModels(from: dir)
        await manager.setLanguage(language)
        let box = self.box
        await manager.setPartialCallback { text in box.add(text, final: false) }
        // warm up with a second of silence
        _ = try await manager.process(samples: [Float](repeating: 0, count: 16_000))
        _ = try await manager.finish()
        await manager.reset()
    }

    func run(_ samples: [Float]) async throws -> (captions: [Caption], language: String?, compute: Double) {
        await manager.reset()
        box.reset()
        let total = samples.count + 16_000 // one second of silence after the speech, like every engine
        var busyUntil = 0.0
        var compute = 0.0
        var offset = 0
        while offset < total {
            let n = min(chunkSamples, total - offset)
            var chunk = [Float](repeating: 0, count: n)
            for k in 0..<n where offset + k < samples.count { chunk[k] = samples[offset + k] }
            let arrival = Double(offset + n) / 16_000
            let start = max(arrival, busyUntil)
            box.begin(at: start)
            let t = now()
            _ = try await manager.process(samples: chunk)
            let d = now() - t
            compute += d
            busyUntil = start + d
            offset += n
        }
        let endArrival = Double(total) / 16_000
        let start = max(endArrival, busyUntil)
        box.begin(at: start)
        let t = now()
        let text = try await manager.finish()
        compute += now() - t
        box.add(text.trimmingCharacters(in: .whitespacesAndNewlines), final: true)
        let detected = await manager.detectedLanguage()
        return (box.snapshot(), detected, compute)
    }
}
