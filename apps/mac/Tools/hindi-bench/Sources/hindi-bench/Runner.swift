import Foundation

func dirSizeMB(_ url: URL?) -> Double? {
    guard let url else { return nil }
    var total = 0
    if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let u as URL in e { total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    }
    return Double(total) / 1_048_576
}

func save(_ run: RunFile, to path: String) throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try enc.encode(run).write(to: URL(fileURLWithPath: path))
}

func runStreaming(engine: LiveEngine, units: [Unit], set: String, out: String, modelMB: Double?) async throws {
    let t0 = now()
    try await engine.prepare()
    let load = now() - t0
    print("\(engine.name): loaded in \(f(load, 1)) s, resident \(f(residentMB(), 0)) MB; \(units.count) units, clock \(engine.clock)")
    var results: [UnitResult] = []
    let wall0 = now()
    for (i, unit) in units.enumerated() {
        let samples = try unit.samples()
        let span = speechSpan(samples)
        let r = try await engine.run(samples)
        let finalText = r.captions.last?.text ?? ""
        results.append(UnitResult(unit: unit, captions: r.captions, finalText: finalText, language: r.language,
                                  compute: r.compute, spanStart: span.0, spanEnd: span.1, translated: nil))
        if i % 10 == 0 || i == units.count - 1 {
            print("  [\(i + 1)/\(units.count)] \(finalText.prefix(70))")
            try save(RunFile(engine: engine.name, set: set, clock: engine.clock, peakMB: peakResidentMB(), modelMB: modelMB,
                             loadSeconds: load, wallSeconds: now() - wall0, results: results), to: out)
        }
    }
    try save(RunFile(engine: engine.name, set: set, clock: engine.clock, peakMB: peakResidentMB(), modelMB: modelMB,
                     loadSeconds: load, wallSeconds: now() - wall0, results: results), to: out)
    print("done; peak resident \(f(peakResidentMB(), 0)) MB; wrote \(out)")
}

/// stretch engines (whisper): a stretch is decoded when the VAD knows it is over
/// (its speech end plus the 0.5 s pause the app waits for), one decoder, in order,
/// per clip. the clock is simulated from the measured decode times.
func runStretch(engine: WhisperEngine, units: [Unit], set: String, out: String, translate: Bool) async throws {
    let t0 = now()
    try await engine.prepare()
    let load = now() - t0
    print("\(engine.name): loaded in \(f(load, 1)) s, resident \(f(residentMB(), 0)) MB; \(units.count) units, clock sim")
    var results: [UnitResult] = []
    var busyUntil: [String: Double] = [:] // per clip, clip seconds
    let wall0 = now()
    for (i, unit) in units.enumerated() {
        let samples = try unit.samples()
        let span = speechSpan(samples)
        let ready = unit.start + span.1 + 0.5 + 0.128
        let startDecode = max(ready, busyUntil[unit.clip] ?? 0)
        let d = try await engine.decode(samples)
        busyUntil[unit.clip] = startDecode + d.seconds
        let wall = startDecode + d.seconds - unit.start
        var translated: String?
        if translate { translated = try await engine.decode(samples, translate: true).text }
        results.append(UnitResult(unit: unit, captions: [Caption(wall: wall, text: d.text, final: true)], finalText: d.text,
                                  language: d.language, compute: d.seconds, spanStart: span.0, spanEnd: span.1, translated: translated))
        if i % 10 == 0 || i == units.count - 1 {
            print("  [\(i + 1)/\(units.count)] [\(d.language ?? "?")] \(d.text.prefix(70))")
            try save(RunFile(engine: engine.name, set: set, clock: "sim", peakMB: peakResidentMB(), modelMB: dirSizeMB(engine.folder),
                             loadSeconds: load, wallSeconds: now() - wall0, results: results), to: out)
        }
    }
    try save(RunFile(engine: engine.name, set: set, clock: "sim", peakMB: peakResidentMB(), modelMB: dirSizeMB(engine.folder),
                     loadSeconds: load, wallSeconds: now() - wall0, results: results), to: out)
    print("done; peak resident \(f(peakResidentMB(), 0)) MB; wrote \(out)")
}
