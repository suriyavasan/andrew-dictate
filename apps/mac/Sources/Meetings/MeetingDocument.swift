import Foundation

/// A meeting file read whole: the front matter, the notes if it has any, and
/// every session's turns. The history list reads only the top of a file
/// (`MeetingSummary`); this is what a window that shows the meeting reads.
/// Pure data, so what a window shows and what a summary is asked about can
/// be argued with in a test.
struct MeetingDocument: Equatable, Sendable {
    /// One paragraph of the file, as it was written: a speaker's turn, or
    /// what they said in a row, stamped with the first line's time.
    struct Line: Equatable, Sendable {
        let at: Duration
        /// The label the file uses: `you`, `them`, `them 2`.
        let speaker: String
        let text: String
    }

    /// One go at recording. A meeting recorded into again has several; the
    /// clock restarts at 00:00:00 in each.
    struct Session: Equatable, Sendable {
        let started: Date
        let turns: [Line]
    }

    let header: MeetingTranscriptFile.Header
    /// The notes between the summary comments, if there are any.
    let summary: String?
    /// Never empty: a file with no sessions marked has its one.
    let sessions: [Session]

    /// What the meeting is called in a list: its title, or the call app's
    /// name with "call" after it (`zoom call`), or just `meeting` when there
    /// was no call app.
    var displayTitle: String {
        header.title ?? Self.untitled(app: header.app)
    }

    /// what a meeting nobody named is called, for a list that has only
    /// read the top of its file.
    static func untitled(app: String) -> String {
        app == "meeting" ? "meeting" : "\(app) call"
    }

    /// Who spoke, in the order they first did, across every session.
    var speakers: [String] {
        var labels: [String] = []
        for session in sessions {
            for line in session.turns where !labels.contains(line.speaker) {
                labels.append(line.speaker)
            }
        }
        return labels
    }

    /// What the file calls you: the name it gave you, or `you` when it has
    /// not (every file from before names).
    var youLabel: String {
        header.voices.first { $0.label == MeetingTurn.Speaker.you.label }?.name
            ?? MeetingTurn.Speaker.you.label
    }

    /// Whether a label on a turn is the person who recorded, by either name.
    func isYou(_ speaker: String) -> Bool {
        speaker == MeetingTurn.Speaker.you.label || speaker == youLabel
    }

    /// `speakers`, with you as `you` whatever the file calls you: the one
    /// spelling the window gives its own colour to.
    var speakersWithYou: [String] {
        speakers.map { isYou($0) ? MeetingTurn.Speaker.you.label : $0 }
    }

    /// Whitespace-separated, over what was said: the same count the file's
    /// `words` key makes.
    var wordCount: Int {
        sessions.reduce(0) { count, session in
            session.turns.reduce(count) {
                $0 + $1.text.split(whereSeparator: \.isWhitespace).count
            }
        }
    }

    var hasWords: Bool {
        sessions.contains { $0.turns.contains { !$0.text.isEmpty } }
    }

    /// What the transcript's copy button copies, and what a summary is asked
    /// about: `[hh:mm:ss] speaker: text`, a blank line between paragraphs.
    /// A meeting with several sessions heads each with its date, because the
    /// times restart. No front matter, no comments, no notes.
    var transcriptText: String {
        var blocks: [String] = []
        for session in sessions {
            if sessions.count > 1 {
                blocks.append(
                    MeetingTranscriptFile.heading(
                        for: session.started, in: header.timeZone))
            }
            for line in session.turns {
                blocks.append("[\(line.at.stamp)] \(line.speaker): \(line.text)")
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// One line for a list row, about 140 characters: the first sentence of
    /// the notes if they have prose, else the first point they make, else
    /// the first thing anyone said. Never a heading, never "None noted.".
    var snippet: String {
        let notes = (summary ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "None noted." }
        let prose = notes.first { !Self.isListItem($0) && !$0.hasPrefix(">") }
        let point = notes.first(where: Self.isListItem).map(Self.withoutBullet)
        let said = sessions.lazy.flatMap(\.turns).first { !$0.text.isEmpty }?.text
        return Self.oneLine(prose ?? point ?? said ?? "", limit: 140)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ")
    }

    /// `- [ ] call the plumber` is `call the plumber`.
    private static func withoutBullet(_ line: String) -> String {
        var text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text = String(text.dropFirst(box.count))
        }
        return text
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return flat.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension MeetingTranscriptFile {
    static func document(at url: URL) throws -> MeetingDocument {
        try document(
            parsing: String(contentsOf: url, encoding: .utf8), url: url)
    }

    /// Every shape a file has been written in: from before the turns were
    /// merged into paragraphs, with or without a title, notes, or sessions
    /// after the first. A line it does not know is left out, not an error:
    /// people edit these files.
    static func document(parsing text: String, url: URL) throws -> MeetingDocument {
        let header = try header(parsing: text, url: url)
        guard let parts = split(text) else {
            throw Failure.noFrontMatter(url)
        }
        let body = readBody(parts.body, firstStarted: header.started)
        return MeetingDocument(
            header: header, summary: body.summary, sessions: body.sessions)
    }

    private static func readBody(
        _ lines: [String],
        firstStarted: Date
    ) -> (summary: String?, sessions: [MeetingDocument.Session]) {
        var summary: [String]?
        var sessions: [MeetingDocument.Session] = []
        var started = firstStarted
        var turns: [MeetingDocument.Line] = []
        // a line that is not a paragraph carries on the one just above it,
        // as long as nothing empty came between.
        var carriesOn = false
        let clock = iso8601(.current)

        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1

            if line == summaryOpen, summary == nil,
               let close = lines[index...].firstIndex(of: summaryClose) {
                summary = Array(lines[index..<close])
                index = close + 1
                carriesOn = false
                continue
            }
            if line.hasPrefix(sessionMarker), line.hasSuffix(" -->") {
                sessions.append(.init(started: started, turns: turns))
                let stamp = line.dropFirst(sessionMarker.count).dropLast(" -->".count)
                started = clock.date(from: String(stamp)) ?? started
                turns = []
                carriesOn = false
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                carriesOn = false
                continue
            }
            if line.hasPrefix(">") || line.hasPrefix("## ") || line.hasPrefix("<!--") {
                carriesOn = false
                continue
            }
            if let turn = paragraph(line) {
                turns.append(turn)
                carriesOn = true
            } else if carriesOn, let last = turns.last {
                turns[turns.count - 1] = .init(
                    at: last.at, speaker: last.speaker,
                    text: last.text + "\n" + line)
            }
        }
        sessions.append(.init(started: started, turns: turns))

        let notes = summary?.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (notes.flatMap { $0.isEmpty ? nil : $0 }, sessions)
    }

    /// `[00:12:04] them 2: let's move on.`
    private static func paragraph(_ line: String) -> MeetingDocument.Line? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else {
            return nil
        }
        let clock = line[line.index(after: line.startIndex)..<close]
            .split(separator: ":", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        guard clock.count == 3, clock.allSatisfy({ $0 >= 0 }) else { return nil }
        let rest = line[line.index(after: close)...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let speaker = rest[..<colon].trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty else { return nil }
        return .init(
            at: .seconds(clock[0] * 3_600 + clock[1] * 60 + clock[2]),
            speaker: speaker,
            text: rest[rest.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces))
    }
}
