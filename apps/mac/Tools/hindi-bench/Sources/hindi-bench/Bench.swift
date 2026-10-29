import Foundation
import Speech

func usage() -> Never {
    print("""
    usage: hindi-bench <command> [options]
      probe                                  what each engine and Translation can do on this mac
      cut    [--seconds 180]                 cut the real clips in /tmp/hindi-bench/real into VAD stretches
      run    --engine apple|nemo|whisper --set fleurs|real --out run.json
             [--n 150] [--seconds 180] [--chunk-ms 2240] [--lang hi-IN|auto] [--mode auto|hi|hien] [--translate]
      score  run.json ... [--limit N] [--only prefix]
      install-translation                    ask macOS for the Hindi to English pack (a window with a Download sheet)
      translate --from run.json|fleurs --out translate.json [--n 150]
    """)
    exit(2)
}

@main struct Main {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage() }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "probe": try await probe()
            case "cut":
                let o = try Options(rest)
                try await Units.cut(seconds: o.double("seconds", default: 180))
            case "run": try await runCommand(rest)
            case "score":
                var files: [String] = []
                var flagArgs: [String] = []
                var i = 0
                while i < rest.count { if rest[i].hasPrefix("--") { flagArgs += [rest[i], rest[i + 1]]; i += 2 } else { files.append(rest[i]); i += 1 } }
                let o = try Options(flagArgs)
                try score(paths: files, limit: o.string("limit").flatMap(Int.init), only: o.string("only"))
            case "translate": try await translateCommand(rest)
            case "install-translation": await MainActor.run { installTranslation() }
            default: usage()
            }
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
}

func probe() async throws {
    print("--- Apple Speech")
    let dictation = await DictationTranscriber.supportedLocales
    let speech = await SpeechTranscriber.supportedLocales
    func hasHindi(_ l: [Locale]) -> [String] { l.map { $0.identifier(.bcp47) }.filter { $0.hasPrefix("hi") }.sorted() }
    print("DictationTranscriber supported locales: \(dictation.count), Hindi among them: \(hasHindi(dictation))")
    print("SpeechTranscriber supported locales:    \(speech.count), Hindi among them: \(hasHindi(speech))")
    print("DictationTranscriber installed hi-IN:", await DictationTranscriber.installedLocales.contains { $0.identifier(.bcp47) == "hi-IN" })
    print("--- Apple Translation hi -> en:", await Translator.status())
    print("--- Nemotron prompt ids are read from the model's metadata.json")
}

func runCommand(_ args: [String]) async throws {
    let o = try Options(args, flags: ["translate"])
    let set = try o.require("set"), out = try o.require("out")
    let units: [Unit]
    switch set {
    case "fleurs": units = try Units.fleurs(limit: o.int("n", default: 150))
    case "real": units = try Units.real(seconds: o.double("seconds", default: 180))
    default: throw BenchError("--set fleurs or real")
    }
    switch try o.require("engine") {
    case "apple":
        try await runStreaming(engine: AppleEngine(), units: units, set: set, out: out, modelMB: nil)
    case "nemo":
        let e = NemotronEngine(chunkMs: o.int("chunk-ms", default: 2240), language: o.string("lang") ?? "hi-IN")
        try await runStreaming(engine: e, units: units, set: set, out: out, modelMB: nil)
    case "whisper":
        let mode = WhisperMode(rawValue: o.string("mode") ?? "auto") ?? .auto
        try await runStretch(engine: WhisperEngine(mode: mode), units: units, set: set, out: out, translate: o.has("translate"))
    default: throw BenchError("--engine apple, nemo or whisper")
    }
}

func translateCommand(_ args: [String]) async throws {
    let o = try Options(args)
    let out = try o.require("out")
    let from = o.string("from") ?? "fleurs"
    var rows: [(id: String, hi: String, ref: String?)] = []
    if from == "fleurs" {
        rows = try Units.fleurs(limit: o.int("n", default: 150)).map { ($0.id, $0.refHi ?? "", $0.refEn) }
    } else {
        rows = try loadRun(from).results.prefix(o.int("n", default: 150)).map { ($0.unit.id, $0.finalText, $0.unit.refEn) }
    }
    let result = try await translateRun(rows: rows)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try enc.encode(result).write(to: URL(fileURLWithPath: out))
    let lat = result.map(\.seconds)
    print("translated \(result.count): per sentence median \(f(percentile(lat, 0.5), 3)) s, p90 \(f(percentile(lat, 0.9), 3)) s; six-word prefix median \(f(percentile(result.compactMap(\.prefixSeconds), 0.5), 3)) s")
    let f1 = result.compactMap(\.f1)
    if !f1.isEmpty { print("unigram F1 vs reference English: mean \(f(f1.reduce(0, +) / Double(f1.count), 3))") }
}
