import FluidAudio
import Foundation

let dataRoot = "/tmp/hindi-bench"

enum Units {
    static func fleurs(limit: Int) throws -> [Unit] {
        struct Row: Decodable { var id: Int; var wav: String; var hi: String; var en: String; var seconds: Double }
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(dataRoot)/fleurs/refs.json"))
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.prefix(limit).map {
            Unit(id: "fleurs-\($0.id)", clip: "fleurs-\($0.id)", start: 0, seconds: $0.seconds,
                 refHi: $0.hi, refEn: $0.en, wav: $0.wav, from: nil, to: nil)
        }
    }

    static func real(seconds: Double) throws -> [Unit] {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(dataRoot)/real/stretches.json"))
        let all = try JSONDecoder().decode([Unit].self, from: data)
        return all.filter { $0.start + $0.seconds <= seconds }
    }

    /// VAD-cut every clip in /tmp/hindi-bench/real into stretches (cap 25 s, as the app cuts for whisper),
    /// keeping only the first `seconds` of each clip.
    static func cut(seconds: Double) async throws {
        let dir = URL(fileURLWithPath: "\(dataRoot)/real")
        let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let vad = try await VadManager()
        var units: [Unit] = []
        for wav in wavs {
            let audio = try readMono(wav)
            let limit = min(audio.count, Int(seconds * 16_000))
            let head = Array(audio[..<limit])
            let name = wav.deletingPathExtension().lastPathComponent
            let stretches = try await Stretching.cut(head, vad: vad, settings: Segmenter.Settings(cap: 25))
            for (i, s) in stretches.enumerated() {
                let a = max(0, Int(s.start * 16_000)), b = min(limit, Int(s.end * 16_000))
                units.append(Unit(id: "\(name)-\(i)", clip: name, start: s.start, seconds: Double(b - a) / 16_000,
                                  refHi: nil, refEn: nil, wav: wav.path, from: a, to: b))
            }
            print("\(name): \(stretches.count) stretches, \(String(format: "%.0f", stretches.map(\.seconds).reduce(0, +))) s of speech in \(Int(Double(limit) / 16_000)) s")
        }
        let out = URL(fileURLWithPath: "\(dataRoot)/real/stretches.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try enc.encode(units).write(to: out)
        print("wrote \(units.count) stretches to \(out.path)")
    }
}
