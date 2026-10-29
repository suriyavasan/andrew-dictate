import Foundation

/// who a label in a transcript stands for. the label is what the mic or the
/// diarizer called them (`you`, `them`, `them 2`); the name is what the file
/// says instead, once somebody is known. the pair is what the front matter's
/// `voices:` keeps, so a name can be taken back to the label it replaced.
struct SpeakerName: Equatable, Sendable {
    let label: String
    let name: String
}

/// the rules for names and labels, in one place and pure: a name goes into
/// `[hh:mm:ss] name: words` and into a front-matter line, so anything that
/// would end the name early or break either line cannot be in one.
enum SpeakerNames {
    static let nameLimit = 40

    /// what a person typed, as a name the file can hold: on one line, with
    /// no colon (it would end the name where the words begin), no comma or
    /// bracket (they end an item in `speakers: [...]`), and nothing at the
    /// front that a yaml reader would take for syntax. nil when nothing is
    /// left, and for `you`, `them` and `them 2`, which would make the name
    /// the label again, or another speaker's.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let replaced = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.newlines.contains($0)
                || unsafe.contains($0) ? " " : $0
        }))
        var name = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let first = name.unicodeScalars.first, leading.contains(first) {
            name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        name = String(name.prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isOriginal(name.lowercased()) else { return nil }
        return name
    }

    private static let unsafe = CharacterSet(charactersIn: ":,[]{}\"")
    private static let leading = CharacterSet(charactersIn: "-?*&!|>'%@`#")

    /// `you`, `them`, `them 2`: the labels this app writes before anybody
    /// is named. a label that is not one of these is somebody's name.
    static func isOriginal(_ label: String) -> Bool {
        number(of: label) != nil
    }

    /// where a label sorts among the others in `voices:`: you, then the far
    /// side in the order of its numbers. names (and anything else) after.
    static func rank(_ label: String) -> Int {
        number(of: label) ?? Int.max
    }

    private static func number(of label: String) -> Int? {
        if label == "you" { return 0 }
        if label == "them" { return 1 }
        guard label.hasPrefix("them "),
              let n = Int(label.dropFirst("them ".count)), n > 0
        else { return nil }
        return 1 + n
    }
}
