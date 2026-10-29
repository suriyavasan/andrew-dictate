import Foundation

/// a json value that keeps its keys in the order they were written, and
/// writes itself on one line. `JSONSerialization` sorts or shuffles a
/// dictionary's keys; a feed line an agent reads by eye, and a tool result
/// it reads first-thing-first, are better with `meeting` before `text`.
/// small and pure, and shared by the live feed that writes lines and the
/// mcp server that writes answers, so the two never escape a string two ways.
indirect enum OrderedJSON: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        lhs.rendered == rhs.rendered
    }

    /// a string, or null when there is none.
    static func orNull(_ value: String?) -> OrderedJSON {
        value.map { .string($0) } ?? .null
    }

    /// one line, no spaces after `:` or `,`.
    var rendered: String {
        var out = ""
        write(to: &out)
        return out
    }

    /// indented, for a tool result a model reads; keys in order.
    var pretty: String {
        var out = ""
        write(to: &out, indent: 0)
        return out
    }

    private func write(to out: inout String, indent: Int? = nil) {
        switch self {
        case .string(let value): out += Self.quoted(value)
        case .int(let value): out += String(value)
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                Self.newline(&out, indent.map { $0 + 1 })
                item.write(to: &out, indent: indent.map { $0 + 1 })
            }
            Self.newline(&out, indent)
            out += "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { out += "{}"; return }
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                Self.newline(&out, indent.map { $0 + 1 })
                out += Self.quoted(pair.key) + (indent == nil ? ":" : ": ")
                pair.value.write(to: &out, indent: indent.map { $0 + 1 })
            }
            Self.newline(&out, indent)
            out += "}"
        }
    }

    private static func newline(_ out: inout String, _ indent: Int?) {
        guard let indent else { return }
        out += "\n" + String(repeating: "  ", count: indent)
    }

    /// json's escapes, and nothing more: a slash is left alone, and so is
    /// any character that is not a control one (names and words are not
    /// always ascii). the line separators a few readers choke on are
    /// escaped, so a line is one line wherever it is read.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F
                || scalar.value == 0x2028 || scalar.value == 0x2029:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
