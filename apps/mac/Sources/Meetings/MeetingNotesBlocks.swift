import Foundation

/// a model's notes cut into the pieces the window draws: headings, points,
/// checkboxes and prose. the notes are markdown, but only the handful of
/// shapes the templates ask for, so this reads those line by line instead of
/// pulling in a renderer: each piece keeps its inline markdown (bold, italic,
/// code) as text for the view to style. pure, so what the window will show
/// for a given answer can be argued with in a test.
enum MeetingNotesBlocks {
    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        /// `- point`, or `- [ ] task` / `- [x] task` when `checked` is set.
        /// `depth` is how far in it was written, one step per two spaces.
        case bullet(text: String, depth: Int, checked: Bool?)
        /// `1. point`.
        case numbered(number: Int, text: String, depth: Int)
        case quote(String)
        case paragraph(String)
        /// the model's answer for a section with nothing in it.
        case noneNoted
    }

    static func blocks(_ markdown: String) -> [Block] {
        var found: [Block] = []
        for raw in markdown.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let block = block(raw, line) { found.append(block) }
        }
        return found
    }

    private static func block(_ raw: String, _ line: String) -> Block? {
        if line == "None noted." { return .noneNoted }
        // a rule between sections says nothing the headings do not.
        if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), line.count >= 3 {
            return nil
        }
        if line.hasPrefix("#") {
            let hashes = line.prefix { $0 == "#" }.count
            let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            // markdown wants a space after the hashes: `#hashtag` is a word.
            if (1...6).contains(hashes), !text.isEmpty,
               line.dropFirst(hashes).first == " " {
                return .heading(level: hashes, text: text)
            }
        }
        let depth = indent(of: raw) / 2
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            var text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            var checked: Bool?
            for (box, state) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)]
            where text.hasPrefix(box) {
                text = String(text.dropFirst(box.count))
                checked = state
                break
            }
            // a bare `- [ ]` with nothing after it is still a box.
            if text == "[ ]" { text = ""; checked = false }
            return .bullet(text: text, depth: min(depth, 3), checked: checked)
        }
        if let dot = line.firstIndex(of: "."),
           let number = Int(line[..<dot]),
           line[line.index(after: dot)...].hasPrefix(" ") {
            let text = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            return .numbered(number: number, text: text, depth: min(depth, 3))
        }
        if line.hasPrefix(">") {
            return .quote(line.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        return .paragraph(line)
    }

    private static func indent(of raw: String) -> Int {
        var width = 0
        for character in raw {
            if character == " " { width += 1 } else if character == "\t" { width += 2 } else { break }
        }
        return width
    }
}
