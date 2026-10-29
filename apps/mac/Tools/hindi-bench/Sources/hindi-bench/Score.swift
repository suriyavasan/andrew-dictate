import Foundation

func loadRun(_ path: String) throws -> RunFile {
    try JSONDecoder().decode(RunFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

/// per-word first-appearance and settled times against a character-proportional
/// estimate of when each word ended (no word timings exist for FLEURS).
func wordLatencies(_ r: UnitResult) -> (first: [Double], settled: [Double]) {
    let finalWords = TextTools.words(r.finalText)
    guard finalWords.count >= 3, r.spanEnd > r.spanStart else { return ([], []) }
    let lens = finalWords.map { Double(max(1, $0.count)) }
    let total = lens.reduce(0, +)
    var cum = 0.0
    var firsts: [Double] = [], settleds: [Double] = []
    let caps = r.captions
    let wordsPer = caps.map { TextTools.words($0.text) }
    for (k, w) in finalWords.enumerated() {
        cum += lens[k]
        let ended = r.spanStart + (cum / total) * (r.spanEnd - r.spanStart)
        // first moment any caption had at least k+1 words
        if let i = wordsPer.firstIndex(where: { $0.count > k }) { firsts.append(caps[i].wall - ended) }
        // settled: after the last caption in which word k was missing or different
        var lastBad = -1
        for (i, ws) in wordsPer.enumerated() where !(ws.count > k && ws[k] == w) { lastBad = i }
        let idx = lastBad + 1
        if idx < caps.count { settleds.append(caps[idx].wall - ended) }
    }
    return (firsts, settleds)
}

func score(paths: [String], limit: Int?, only: String?) throws {
    for path in paths {
        let run = try loadRun(path)
        var results = run.results
        if let only { results = results.filter { $0.unit.id.hasPrefix(only) } }
        if let limit { results = Array(results.prefix(limit)) }
        guard !results.isEmpty else { continue }
        let audio = results.map { $0.unit.seconds }.reduce(0, +)
        let compute = results.map(\.compute).reduce(0, +)
        var we = 0, wn = 0, ce = 0, cn = 0
        var firstAll: [Double] = [], settledAll: [Double] = []
        var firstCaption: [Double] = [], endLag: [Double] = []
        var arabicLines = 0, devaLines = 0, latinChars = 0, devaChars = 0, arabicChars = 0
        var latinWords = 0, allWords = 0
        for r in results {
            if let ref = r.unit.refHi {
                let w = TextTools.wer(ref: ref, hyp: r.finalText); we += w.0; wn += w.1
                let c = TextTools.cer(ref: ref, hyp: r.finalText); ce += c.0; cn += c.1
            }
            let lat = wordLatencies(r)
            firstAll += lat.first; settledAll += lat.settled
            if let c = r.captions.first(where: { !$0.text.isEmpty }) { firstCaption.append(c.wall - r.spanStart) }
            if let l = r.captions.last, !l.text.isEmpty { endLag.append(l.wall - r.spanEnd) }
            let a = TextTools.arabicScriptCount(r.finalText), d = TextTools.devanagariCount(r.finalText)
            if a > 0 { arabicLines += 1 }
            if d > 0 { devaLines += 1 }
            arabicChars += a; devaChars += d; latinChars += TextTools.latinCount(r.finalText)
            for w in TextTools.words(r.finalText) { allWords += 1; if TextTools.latinCount(w) > 0 { latinWords += 1 } }
        }
        print("== \(run.engine)  [\(run.set), clock \(run.clock)]  units \(results.count), audio \(f(audio / 60, 1)) min")
        if wn > 0 { print("   WER \(f(100 * Double(we) / Double(wn), 1)) %   CER \(f(100 * Double(ce) / Double(cn), 1)) %   (\(wn) ref words)") }
        print("   word first-appears  median \(f(percentile(firstAll, 0.5))) s   p90 \(f(percentile(firstAll, 0.9))) s   (\(firstAll.count) words)")
        print("   word settled        median \(f(percentile(settledAll, 0.5))) s   p90 \(f(percentile(settledAll, 0.9))) s")
        print("   first caption after speech onset: median \(f(percentile(firstCaption, 0.5))) s  p90 \(f(percentile(firstCaption, 0.9))) s;  final text after speech end: median \(f(percentile(endLag, 0.5))) s  p90 \(f(percentile(endLag, 0.9))) s")
        print("   real-time factor \(f(compute / audio, 3))  (compute \(f(compute, 0)) s for \(f(audio, 0)) s of audio)   peak resident \(f(run.peakMB, 0)) MB   model \(f(run.modelMB, 0)) MB on disk")
        print("   lines with Arabic/Urdu script \(arabicLines)/\(results.count) (\(arabicChars) chars), with Devanagari \(devaLines)/\(results.count); Latin words \(latinWords)/\(allWords)")
        // language
        var langCount: [String: Int] = [:]
        for r in results { langCount[r.language ?? "-", default: 0] += 1 }
        print("   language per unit: \(langCount.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        // flips between consecutive units of one clip (real clips only)
        var flips = 0, hiUr = 0, transitions = 0
        var lastByClip: [String: String] = [:]
        for r in results where r.unit.start > 0 || r.unit.id.contains("-") && !r.unit.id.hasPrefix("fleurs") {
            guard let l = r.language else { continue }
            if let prev = lastByClip[r.unit.clip] {
                transitions += 1
                if prev != l { flips += 1; if Set([prev, l]) == ["hi", "ur"] { hiUr += 1 } }
            }
            lastByClip[r.unit.clip] = l
        }
        if transitions > 0 { print("   language flips between consecutive stretches: \(flips)/\(transitions), of which hi<->ur \(hiUr)") }
    }
}
