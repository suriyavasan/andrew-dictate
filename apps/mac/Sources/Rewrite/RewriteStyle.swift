import Foundation

/// where a style sits on the tone pad: figma's two axes, casual to
/// professional across and concise to expanded down, five steps each. a
/// step is a word the model is handed ("a little more formal"), not a
/// number it is asked to hit, so five is as fine as the words can tell
/// apart.
struct TonePosition: Codable, Hashable, Sendable {
    static let steps = -2...2

    /// -2 casual … +2 professional.
    var formality: Int
    /// -2 concise … +2 expanded.
    var length: Int

    static let center = TonePosition(formality: 0, length: 0)

    init(formality: Int, length: Int) {
        self.formality = formality.clamped(to: Self.steps)
        self.length = length.clamped(to: Self.steps)
    }

    var formalityWords: String? {
        switch formality {
        case ...(-2): "casual, the way you would text a friend"
        case -1: "relaxed and friendly"
        case 0: nil
        case 1: "polished"
        default: "professional and formal"
        }
    }

    /// the place on the pad in a few words, for VoiceOver and the style
    /// list: what you would say, not what the model is told.
    var summary: String {
        let formality = switch formality {
        case ...(-2): "casual"
        case -1: "a little casual"
        case 0: "as said"
        case 1: "a little formal"
        default: "professional"
        }
        let length = switch length {
        case ...(-2): "concise"
        case -1: "a little shorter"
        case 0: "same length"
        case 1: "a little longer"
        default: "expanded"
        }
        return "\(formality), \(length)"
    }

    var lengthWords: String? {
        switch length {
        case ...(-2): "as short as it can be without losing a point"
        case -1: "a little tighter than it was said"
        case 0: nil
        case 1: "a little fuller, where a point needs it"
        default: "expanded, with each point spelled out"
        }
    }
}

/// one way a rewrite can go. three ship with the app and cannot be removed;
/// the rest are yours, made on the tone pad in settings, and each is a
/// button on the picker.
struct RewriteStyle: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    /// nil is `auto`: the tone the words already have, cleaned up.
    var tone: TonePosition?
    /// anything the pad cannot say: "end with a question", "no emoji".
    var notes: String

    init(id: String, name: String, tone: TonePosition?, notes: String = "") {
        self.id = id
        self.name = name
        self.tone = tone
        self.notes = notes
    }

    static func custom(
        name: String,
        tone: TonePosition = .center,
        notes: String = ""
    ) -> RewriteStyle {
        RewriteStyle(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: name,
            tone: tone,
            notes: notes
        )
    }

    var isBuiltIn: Bool {
        Self.builtIn.contains { $0.id == id }
    }

    static let auto = RewriteStyle(id: "auto", name: "auto", tone: nil)
    static let professional = RewriteStyle(
        id: "professional",
        name: "professional",
        tone: TonePosition(formality: 2, length: 0)
    )
    static let casual = RewriteStyle(
        id: "casual",
        name: "casual",
        tone: TonePosition(formality: -2, length: 0)
    )

    static let builtIn: [RewriteStyle] = [.auto, .professional, .casual]

    /// the picker holds nine, one per digit key; the built-ins take three.
    static let maximumCustom = 6
}

/// figma's four tone presets: a place on the pad and a word of flavour the
/// pad cannot carry. a starting point for a style of your own, nothing more.
struct TonePreset: Hashable, Identifiable, Sendable {
    let name: String
    let tone: TonePosition
    let notes: String

    var id: String { name }

    static let all: [TonePreset] = [
        TonePreset(
            name: "executive",
            tone: TonePosition(formality: 2, length: -2),
            notes: "lead with the point. no hedging, no warm-up."
        ),
        TonePreset(
            name: "technical",
            tone: TonePosition(formality: 1, length: 1),
            notes: "precise terms. keep every name, number and piece of code exactly as said."
        ),
        TonePreset(
            name: "basic",
            tone: TonePosition(formality: -1, length: -1),
            notes: "plain, everyday words a twelve-year-old would follow."
        ),
        TonePreset(
            name: "educational",
            tone: TonePosition(formality: 0, length: 2),
            notes: "explain it the way you would to someone learning it."
        ),
    ]
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
