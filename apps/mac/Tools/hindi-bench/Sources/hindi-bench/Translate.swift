import Foundation
import Translation

/// Apple's on-device Translation framework, Hindi to English.
enum Translator {
    static let hi = Locale.Language(identifier: "hi")
    static let en = Locale.Language(identifier: "en")

    static func status() async -> String {
        let s = await LanguageAvailability().status(from: hi, to: en)
        switch s {
        case .installed: return "installed"
        case .supported: return "supported (the Hindi pack is not installed)"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }

    static func installed() async -> Bool {
        await LanguageAvailability().status(from: hi, to: en) == .installed
    }
}

struct TranslationRow: Codable {
    var id: String
    var hi: String
    var machine: String
    var reference: String?
    var seconds: Double
    var prefixSeconds: Double?
    var prefixHi: String?
    var prefixMachine: String?
    var f1: Double?
}

func translateRun(rows: [(id: String, hi: String, ref: String?)]) async throws -> [TranslationRow] {
    guard await Translator.installed() else {
        throw BenchError("Hindi to English translation is \(await Translator.status()). Install it in System Settings > General > Language & Region > Translation Languages.")
    }
    let session = TranslationSession(installedSource: Translator.hi, target: Translator.en)
    try await session.prepareTranslation()
    _ = try await session.translate("नमस्ते") // warm
    var out: [TranslationRow] = []
    for row in rows {
        let t = now()
        let r = try await session.translate(row.hi)
        let d = now() - t
        // the growing partial: translate only the first six words, as a live caption would
        let prefix = TextTools.words(row.hi).prefix(6).joined(separator: " ")
        let t2 = now()
        let p = try await session.translate(prefix)
        let d2 = now() - t2
        out.append(TranslationRow(
            id: row.id, hi: row.hi, machine: r.targetText, reference: row.ref, seconds: d,
            prefixSeconds: d2, prefixHi: prefix, prefixMachine: p.targetText,
            f1: row.ref.map { TextTools.unigramF1(ref: $0, hyp: r.targetText) }))
    }
    return out
}
