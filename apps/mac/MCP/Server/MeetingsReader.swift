import Foundation

/// the meetings on this mac, read for an agent: the saved ones by their
/// files and the one recording by its live feed. read-only by construction:
/// nothing here opens a file for writing, creates a folder or deletes
/// anything, and it keeps no word anywhere but in memory.
///
/// quick on hundreds of files: a list reads the top of each file once and
/// remembers it until the file changes; a search looks through a file's text
/// for the words before it parses the file; a meeting is read only when it
/// is asked for.
///
/// every answer is an `OrderedJSON`, so the tools say it and a test reads it.
final class MeetingsReader {
    /// one saved meeting: its id is the name of its file, without `.md`.
    struct Entry: Equatable {
        let id: String
        let url: URL
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    static let defaultLimit = 20
    static let listLimit = 200
    static let searchLimit = 100
    /// how much of a turn a search result quotes.
    static let quoteLimit = 1_200
    /// lines of the live meeting in one answer.
    static let liveLines = 500
    /// enough for any front matter a meeting has had; a file that needs more
    /// is read whole.
    private static let headSize = 32 * 1_024

    private let locations: MCPLocations
    private let fileManager: FileManager
    private let isAlive: (Int32) -> Bool
    private var headers: [String: (stamp: Date, header: MeetingTranscriptFile.Header)] = [:]

    init(
        locations: MCPLocations,
        fileManager: FileManager = .default,
        isAlive: @escaping (Int32) -> Bool = MeetingsReader.processIsAlive
    ) {
        self.locations = locations
        self.fileManager = fileManager
        self.isAlive = isAlive
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - saved meetings

    /// every `.md` under `meetings/` that is not the folder's own note, by
    /// the names alone.
    func entries() -> [Entry] {
        let folder = locations.meetingsFolder
        guard let walker = fileManager.enumerator(atPath: folder.path) else { return [] }
        var found: [Entry] = []
        for case let relative as String in walker where relative.hasSuffix(".md") {
            let name = (relative as NSString).lastPathComponent
            guard !name.hasPrefix("."), name != MeetingTranscriptFile.noteName,
                  !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") })
            else { continue }
            found.append(Entry(
                id: String(name.dropLast(".md".count)),
                url: folder.appendingPathComponent(relative, isDirectory: false)))
        }
        return found
    }

    /// the meetings with a front matter, newest first.
    func meetings() -> [(entry: Entry, header: MeetingTranscriptFile.Header)] {
        entries().compactMap { entry in
            header(of: entry.url).map { (entry, $0) }
        }
        .sorted { $0.header.started > $1.header.started }
    }

    private func header(of url: URL) -> MeetingTranscriptFile.Header? {
        let stamp = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let stamp, let cached = headers[url.path], cached.stamp == stamp {
            return cached.header
        }
        guard let head = readHead(of: url) else { return nil }
        var header = try? MeetingTranscriptFile.header(parsing: head.text, url: url)
        if header == nil, head.truncated, let whole = try? String(contentsOf: url, encoding: .utf8) {
            header = try? MeetingTranscriptFile.header(parsing: whole, url: url)
        }
        if let header, let stamp { headers[url.path] = (stamp, header) }
        return header
    }

    private func readHead(of url: URL) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.headSize) else { return nil }
        return (String(decoding: data, as: UTF8.self), data.count == Self.headSize)
    }

    func listMeetings(limit: Int?, since: Date?, query: String?) -> OrderedJSON {
        let cap = min(max(limit ?? Self.defaultLimit, 1), Self.listLimit)
        let terms = Self.terms(of: query)
        var matched = meetings()
        if let since { matched = matched.filter { $0.header.started >= since } }
        if !terms.isEmpty {
            matched = matched.filter { found in
                let haystack = ([Self.title(found.header), found.header.app]
                    + found.header.participants + found.header.speakers
                    + found.header.voices.map(\.name)).joined(separator: "\n")
                return Self.contains(haystack, terms)
            }
        }
        return .object([
            ("meetings", .array(matched.prefix(cap).map { summary($0.entry, $0.header) })),
            ("count", .int(min(matched.count, cap))),
            ("total", .int(matched.count)),
            ("more", .bool(matched.count > cap)),
        ])
    }

    private func summary(_ entry: Entry, _ header: MeetingTranscriptFile.Header) -> OrderedJSON {
        var pairs: [(key: String, value: OrderedJSON)] = [
            ("id", .string(entry.id)),
            ("title", .string(Self.title(header))),
            ("app", .string(header.app)),
            ("started", .string(Self.iso(header.started, header.timeZone))),
            ("duration_s", .int(Int(header.duration.components.seconds))),
            ("duration", .string(header.duration.spoken)),
            ("participants", .array(header.participants.map { .string($0) })),
            ("speakers", .array(header.speakers.map { .string($0) })),
            ("words", .int(header.words)),
            ("complete", .bool(header.complete)),
        ]
        if header.sessions > 1 { pairs.append(("sessions", .int(header.sessions))) }
        return .object(pairs)
    }

    /// the file for an id: matched against the names found, never joined
    /// onto a path, so no id reaches outside `meetings/`, and only a file
    /// that is a transcript (a front matter) is a meeting. `.md` and a month
    /// folder in front are forgiven.
    func entry(id raw: String) -> Entry? {
        var id = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        if id.hasSuffix(".md") { id.removeLast(".md".count) }
        guard !id.isEmpty else { return nil }
        let matches = entries().filter { $0.id == id && header(of: $0.url) != nil }
        // a name used twice (a file copied into another month) is the newest.
        return matches.max { $0.url.path < $1.url.path }
    }

    func getMeeting(id: String, turns: Bool) throws -> String {
        guard let entry = entry(id: id) else {
            throw Failure(message: "no meeting called “\(id)”. list_meetings gives the ids.")
        }
        guard let text = try? String(contentsOf: entry.url, encoding: .utf8) else {
            throw Failure(message: "the meeting “\(entry.id)” could not be read.")
        }
        guard turns else { return text }
        guard let document = try? MeetingTranscriptFile.document(parsing: text, url: entry.url) else {
            throw Failure(message: "the meeting “\(entry.id)” is not a transcript this server can read; ask for the markdown instead.")
        }
        return Self.turns(of: document, id: entry.id).pretty
    }

    static func turns(of document: MeetingDocument, id: String) -> OrderedJSON {
        let header = document.header
        var pairs: [(key: String, value: OrderedJSON)] = [
            ("id", .string(id)),
            ("title", .string(document.displayTitle)),
            ("app", .string(header.app)),
            ("started", .string(iso(header.started, header.timeZone))),
            ("duration_s", .int(Int(header.duration.components.seconds))),
            ("participants", .array(header.participants.map { .string($0) })),
        ]
        if let notes = document.summary { pairs.append(("notes", .string(notes))) }
        var turns: [OrderedJSON] = []
        for (n, session) in document.sessions.enumerated() {
            for turn in session.turns {
                var fields: [(key: String, value: OrderedJSON)] = [
                    ("at", .string(turn.at.stamp)),
                    ("speaker", .string(turn.speaker)),
                    ("text", .string(turn.text)),
                ]
                if document.sessions.count > 1 { fields.insert(("session", .int(n + 1)), at: 0) }
                turns.append(.object(fields))
            }
        }
        pairs.append(("turns", .array(turns)))
        return .object(pairs)
    }

    // MARK: - search

    /// turns that say every word of `query` (any case, any accent), newest
    /// meeting first, optionally only by one speaker.
    func searchMeetings(query: String, speaker: String?, limit: Int?) -> OrderedJSON {
        let cap = min(max(limit ?? Self.defaultLimit, 1), Self.searchLimit)
        let terms = Self.terms(of: query)
        let who = speaker?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var hits: [OrderedJSON] = []
        var more = false
        var searched = 0
        search: for (entry, header) in meetings() {
            guard let text = try? String(contentsOf: entry.url, encoding: .utf8) else { continue }
            // before the file is parsed: most of them have nothing to find.
            guard Self.contains(text, terms), who.map({ Self.contains(text, [$0]) }) ?? true,
                  let document = try? MeetingTranscriptFile.document(parsing: text, url: entry.url)
            else { continue }
            searched += 1
            let labels = who.map { Self.labels(for: $0, in: header) } ?? []
            for (n, session) in document.sessions.enumerated() {
                for turn in session.turns {
                    if let who, !Self.speaker(turn.speaker, is: who, labels: labels, in: document) { continue }
                    guard Self.contains(turn.text, terms) else { continue }
                    if hits.count == cap { more = true; break search }
                    var fields: [(key: String, value: OrderedJSON)] = [
                        ("meeting", .string(entry.id)),
                        ("title", .string(document.displayTitle)),
                        ("started", .string(Self.iso(header.started, header.timeZone))),
                        ("at", .string(turn.at.stamp)),
                        ("wall", .string(Self.iso(
                            session.started.addingTimeInterval(turn.at.totalSeconds), header.timeZone))),
                        ("speaker", .string(turn.speaker)),
                        ("text", .string(Self.quote(turn.text))),
                    ]
                    if document.sessions.count > 1 { fields.insert(("session", .int(n + 1)), at: 5) }
                    hits.append(.object(fields))
                }
            }
        }
        return .object([
            ("matches", .array(hits)),
            ("count", .int(hits.count)),
            ("more", .bool(more)),
        ])
    }

    /// what a speaker filter may mean in one file: the name asked for, and
    /// the label that name replaced (`them 2` for `Priya`), so a search for
    /// a label finds the person it became and the other way round.
    private static func labels(for who: String, in header: MeetingTranscriptFile.Header) -> [String] {
        var labels = [who]
        for voice in header.voices {
            if voice.name.caseInsensitiveCompare(who) == .orderedSame { labels.append(voice.label) }
            if voice.label.caseInsensitiveCompare(who) == .orderedSame { labels.append(voice.name) }
        }
        return labels
    }

    private static func speaker(
        _ label: String, is who: String, labels: [String], in document: MeetingDocument
    ) -> Bool {
        if who.caseInsensitiveCompare(MeetingTurn.Speaker.you.label) == .orderedSame,
           document.isYou(label) { return true }
        return labels.contains { label.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private static func quote(_ text: String) -> String {
        text.count > quoteLimit ? text.prefix(quoteLimit) + "…" : text
    }

    // MARK: - the live meeting

    /// whether a meeting is recording, and what has been said in it after
    /// `afterSeq` (all of it, up to the last `liveLines`, when that is nil).
    func liveMeeting(afterSeq: Int?) -> OrderedJSON {
        let current = locations.liveDirectory.appendingPathComponent(LiveFeed.currentName)
        guard let feed = readFeed(at: current) else {
            return .object([
                ("recording", .bool(false)),
                ("last_meeting", last()),
                ("note", .string("no meeting is recording on this mac now.")),
            ])
        }
        let alive = feed.pid.map(isAlive) ?? true
        guard feed.end == nil, alive else {
            // a feed that ended, or that its app died without ending.
            return .object([
                ("recording", .bool(false)),
                ("last_meeting", feed.summary(crashed: feed.end == nil)),
                ("note", .string("no meeting is recording on this mac now.")),
            ])
        }
        var lines = feed.lines.filter { $0.seq > (afterSeq ?? 0) }
        var more = false
        var skipped = false
        if lines.count > Self.liveLines {
            if afterSeq == nil {
                skipped = true
                lines = Array(lines.suffix(Self.liveLines))
            } else {
                more = true
                lines = Array(lines.prefix(Self.liveLines))
            }
        }
        let named = feed.speakers.filter { !SpeakerNames.isOriginal($0) }
        return .object([
            ("recording", .bool(true)),
            ("meeting", .orNull(feed.meeting)),
            ("app", .orNull(feed.app)),
            ("started", .orNull(feed.started)),
            ("you", .orNull(feed.you)),
            ("participants", .array(named.map { .string($0) })),
            ("last_seq", .int(feed.lines.last?.seq ?? 0)),
            ("lines", .array(lines.map(\.json))),
            ("more", .bool(more)),
            ("earlier_lines_left_out", .bool(skipped)),
            ("note", .string("the far side is “them” while the meeting records; its people are named in the saved transcript. call again with after_seq set to last_seq for what came since.")),
        ])
    }

    /// the newest feed that is not recording: how the last meeting ended,
    /// and where its transcript went.
    private func last() -> OrderedJSON {
        let names = (try? fileManager.contentsOfDirectory(atPath: locations.liveDirectory.path)) ?? []
        let newest = names
            .filter { $0.hasSuffix(".\(LiveFeed.fileExtension)") && $0 != LiveFeed.currentName }
            .max()
        guard let newest,
              let feed = readFeed(at: locations.liveDirectory.appendingPathComponent(newest))
        else { return .null }
        return feed.summary(crashed: feed.end == nil && !(feed.pid.map(isAlive) ?? false))
    }

    struct Feed {
        struct Line {
            let seq: Int
            let json: OrderedJSON
        }

        var meeting: String?
        var app: String?
        var started: String?
        var you: String?
        var pid: Int32?
        var end: [String: Any]?
        var lines: [Line] = []
        var speakers: [String] = []

        func summary(crashed: Bool) -> OrderedJSON {
            let saved = end?["saved"] as? String
            return .object([
                ("meeting", .orNull(meeting)),
                ("app", .orNull(app)),
                ("started", .orNull(started)),
                ("ended", .orNull(end?["ended"] as? String)),
                ("saved", .orNull(saved)),
                ("saved_id", .orNull(saved.map {
                    (($0 as NSString).lastPathComponent as NSString).deletingPathExtension
                })),
                ("interrupted", .bool(crashed)),
            ])
        }
    }

    /// a feed, line by line: a line that is cut off (the app is writing it
    /// now) or is not json is passed over.
    func readFeed(at url: URL) -> Feed? {
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        var feed = Feed()
        var started = false
        for slice in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(slice))) as? [String: Any]
            else { continue }
            switch object["event"] as? String {
            case "start":
                started = true
                feed.meeting = object["meeting"] as? String
                feed.app = object["app"] as? String
                feed.started = object["started"] as? String
                feed.you = object["you"] as? String
                feed.pid = (object["pid"] as? Int).map(Int32.init(truncatingIfNeeded:))
            case "end":
                feed.end = object
            case nil:
                guard let seq = object["seq"] as? Int, let text = object["text"] as? String else { continue }
                let speaker = object["speaker"] as? String ?? ""
                if !speaker.isEmpty, !feed.speakers.contains(speaker) { feed.speakers.append(speaker) }
                feed.lines.append(Feed.Line(seq: seq, json: .object([
                    ("seq", .int(seq)),
                    ("at", .orNull(object["at"] as? String)),
                    ("wall", .orNull(object["wall"] as? String)),
                    ("side", .orNull(object["side"] as? String)),
                    ("speaker", .string(speaker)),
                    ("text", .string(text)),
                ])))
            default:
                continue
            }
        }
        return started || !feed.lines.isEmpty ? feed : nil
    }

    // MARK: - small helpers

    static func title(_ header: MeetingTranscriptFile.Header) -> String {
        header.title ?? MeetingDocument.untitled(app: header.app)
    }

    static func iso(_ date: Date, _ timeZone: TimeZone) -> String {
        MeetingTranscriptFile.iso8601(timeZone).string(from: date)
    }

    private static func terms(of query: String?) -> [String] {
        (query ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// every term in `text`, in any case and with or without accents.
    private static func contains(_ text: String, _ terms: [String]) -> Bool {
        terms.allSatisfy {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// `2026-10-29`, or a full time with an offset.
    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: trimmed) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: trimmed) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: trimmed)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
