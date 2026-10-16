import Foundation

/// a transcript cut into the rows the window draws: a heading where a
/// session begins, and one row per paragraph with what the row needs to be
/// drawn without looking at its neighbours (does a new speaker begin here,
/// which colour is theirs). pure, so a recorded file and the live lines of a
/// meeting being recorded are laid out by the same rules.
enum MeetingTranscriptBlocks {
    struct Item: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// `17 oct 2026 · 09:30`, where a session after the first begins.
            case session(String)
            case turn(Turn)
        }

        let id: String
        let kind: Kind
    }

    struct Turn: Equatable, Sendable {
        let at: Duration
        let speaker: String
        let text: String
        /// the speaker changed (or a session began) here: the row says who.
        /// the rows after it, by the same speaker, carry a bar in their colour.
        let beginsRun: Bool
        /// where in `MeetingTranscriptBlocks.palette` this speaker's colour
        /// is, or nil for `you`, who is always the gold.
        let colour: Int?
        /// live lines still being guessed at are drawn dimmer.
        let isConfirmed: Bool
    }

    /// how many colours other speakers cycle through.
    static let palette = 4

    static let you = "you"

    /// a recorded meeting. headings only when there is more than one session,
    /// because the clock restarts in each and one heading alone says nothing.
    static func items(for document: MeetingDocument) -> [Item] {
        let speakers = document.speakers
        var items: [Item] = []
        let several = document.sessions.count > 1
        for (s, session) in document.sessions.enumerated() {
            if several {
                items.append(Item(
                    id: "session-\(s)",
                    kind: .session(heading(session.started, document.header.timeZone))))
            }
            var previous: String?
            for (t, line) in session.turns.enumerated() {
                items.append(Item(
                    id: "turn-\(s)-\(t)",
                    kind: .turn(Turn(
                        at: line.at, speaker: line.speaker, text: line.text,
                        beginsRun: line.speaker != previous,
                        colour: colour(of: line.speaker, in: speakers),
                        isConfirmed: true))))
                previous = line.speaker
            }
        }
        return items
    }

    /// the lines of a meeting being recorded now, to follow a transcript
    /// that is already on screen: the speakers it knows keep their colours.
    static func items(
        live lines: [LiveLine], knownSpeakers: [String] = [], idPrefix: String = "live"
    ) -> [Item] {
        var speakers = knownSpeakers
        for line in lines {
            let label = label(line.speaker)
            if !speakers.contains(label) { speakers.append(label) }
        }
        var previous: String?
        return lines.map { line in
            let label = label(line.speaker)
            defer { previous = label }
            return Item(
                id: "\(idPrefix)-\(line.id.uuidString)",
                kind: .turn(Turn(
                    at: line.at, speaker: label, text: line.text,
                    beginsRun: label != previous,
                    colour: colour(of: label, in: speakers),
                    isConfirmed: line.isConfirmed)))
        }
    }

    static func label(_ speaker: LiveLine.Speaker) -> String {
        switch speaker {
        case .you: you
        case .them: "them"
        }
    }

    /// the first of the other speakers has the first colour, whoever spoke
    /// before them: `you` does not use one up.
    static func colour(of speaker: String, in speakers: [String]) -> Int? {
        guard speaker != you else { return nil }
        let others = speakers.filter { $0 != you }
        guard let index = others.firstIndex(of: speaker) else { return nil }
        return index % palette
    }

    private static func heading(_ date: Date, _ timeZone: TimeZone) -> String {
        // the file's own heading, without the markdown that makes it one.
        String(MeetingTranscriptFile.heading(for: date, in: timeZone).dropFirst(3))
    }
}

/// finding words in what the window shows. matches are counted per row, in
/// reading order, so "3 of 12" and "next" are arithmetic.
enum MeetingTranscriptFind {
    struct Match: Equatable, Sendable {
        let itemID: String
        /// which occurrence in that row, counting from 0.
        let occurrence: Int
    }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func matches(in items: [MeetingTranscriptBlocks.Item], for query: String) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var found: [Match] = []
        for item in items {
            guard case let .turn(turn) = item.kind else { continue }
            for occurrence in 0..<ranges(of: needle, in: turn.text).count {
                found.append(Match(itemID: item.id, occurrence: occurrence))
            }
        }
        return found
    }

    /// every place `needle` is in `text`, none overlapping.
    static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let range = text.range(of: needle, options: options, range: from..<text.endIndex) {
            found.append(range)
            from = range.upperBound
        }
        return found
    }

    /// the match after `index`, wrapping from the last to the first; the
    /// one before, wrapping the other way.
    static func step(_ index: Int, by delta: Int, of count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}
