import Foundation

/// naming a speaker in a file that is already written: `them 2` becomes
/// `Priya` on every turn of every session and in the front matter, and
/// `Priya` can become `Priya Nair`, or `them 2` again. the `voices:` list in
/// the front matter is what makes it undoable: it remembers which label a
/// name replaced.
extension MeetingTranscriptFile {
    /// the labels a shown speaker stands for: the ones `voices:` lists
    /// under that name (a person two voices were found for stands for
    /// both), or the speaker itself when it is still a label of the app's.
    /// empty for a name that was typed into the file by hand.
    static func origins(of shown: String, in voices: [SpeakerName]) -> [String] {
        let listed = voices.filter { $0.name == shown }.map(\.label)
        if !listed.isEmpty { return listed }
        return SpeakerNames.isOriginal(shown) ? [shown] : []
    }

    /// the file's text with `shown` (a label, or a name given before) now
    /// going by `name`; blank, or nil, puts the label back. nil for text
    /// with no front matter. text it has nothing to do to comes back as it
    /// was: you are not renamed here (that is a setting), a name that
    /// cannot be written is refused, and a name with no label behind it
    /// cannot be taken back.
    static func renamingSpeaker(_ shown: String, to requested: String?, in text: String) -> String? {
        guard let parts = split(text) else { return nil }
        let front = FrontLines(parts.front)
        let voices = parts.front.compactMap(voice(_:))
        let you = MeetingTurn.Speaker.you.label
        let yourName = voices.first { $0.label == you }?.name ?? you
        guard shown != you, shown != yourName else { return text }

        let origins = origins(of: shown, in: voices)
        let target: String
        if let typed = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
            guard let name = SpeakerNames.clean(typed) else { return text }
            target = name
        } else {
            guard let label = origins.first else { return text }
            target = label
        }
        guard target != shown else { return text }

        // the voices: a name replaces the labels it stands for; a label
        // put back takes them out.
        var named = voices
        if SpeakerNames.isOriginal(target) {
            named.removeAll { $0.name == shown }
        } else {
            for label in origins {
                if let at = named.firstIndex(where: { $0.label == label }) {
                    named[at] = SpeakerName(label: label, name: target)
                } else {
                    named.append(SpeakerName(label: label, name: target))
                }
            }
        }
        named.sort { SpeakerNames.rank($0.label) < SpeakerNames.rank($1.label) }

        var lines = front
        if let speakers = list(lines.value(of: "speakers")) {
            var out: [String] = []
            for label in speakers.map({ $0 == shown ? target : $0 }) where !out.contains(label) {
                out.append(label)
            }
            lines.set("speakers", to: ["speakers: [\(out.joined(separator: ", "))]"], after: "engine")
        }
        let written = nameLines(named)
        lines.set("participants", to: written.isEmpty ? nil : [written[0]], after: "speakers")
        lines.set(
            "voices", to: written.isEmpty ? nil : Array(written.dropFirst()),
            after: "participants")

        let body = renaming(shown, to: target, inBody: parts.body, alsoInNotes: !SpeakerNames.isOriginal(target))
        return join(lines.lines, body)
    }

    /// the file renamed on disk, whole or not at all.
    static func renameSpeaker(
        _ shown: String, to name: String?, at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { throw Failure.gone(url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let renamed = renamingSpeaker(shown, to: name, in: text) else {
            throw Failure.noFrontMatter(url)
        }
        guard renamed != text else { return }
        try store(renamed, at: url, fileManager: fileManager)
    }

    // MARK: - the body

    /// every paragraph said by `shown`, and, when a `them 2` is named, the
    /// places the notes call them that. a paragraph is `[hh:mm:ss] who: …`;
    /// the words after the colon are never touched.
    private static func renaming(
        _ shown: String, to target: String, inBody body: [String], alsoInNotes: Bool
    ) -> [String] {
        var inNotes = false
        let notesPattern = alsoInNotes && shown.hasPrefix("them ")
            ? try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: shown) + "\\b")
            : nil
        return body.map { line in
            if line == summaryOpen { inNotes = true; return line }
            if line == summaryClose { inNotes = false; return line }
            if inNotes {
                guard let notesPattern else { return line }
                let range = NSRange(line.startIndex..., in: line)
                return notesPattern.stringByReplacingMatches(
                    in: line, range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: target))
            }
            return speaking(line, as: shown, now: target)
        }
    }

    /// the line with `shown` before its colon replaced, if it is a paragraph
    /// by them.
    private static func speaking(_ line: String, as shown: String, now target: String) -> String {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        let clock = line[line.index(after: line.startIndex)..<close]
            .split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3, clock.allSatisfy({ Int($0) != nil }) else { return line }
        let who = line.index(after: close)
        let prefix = " " + shown + ":"
        guard line[who...].hasPrefix(prefix) else { return line }
        return String(line[..<who]) + " " + target + ":" + line[line.index(who, offsetBy: prefix.count)...]
    }
}
