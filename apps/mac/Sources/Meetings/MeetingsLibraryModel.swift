import Foundation

/// the meetings window's list: every meeting on disk, read as far as a row
/// and a search need, grouped by when it happened. no views in here, so what
/// the window lists and finds can be argued with in a test.
///
/// the top of each file (`MeetingSummary`) comes from `load`; the whole of it
/// (`MeetingDocument`) from `files.read`, off the main actor and kept until
/// the file changes under it. a row needs the document for its title and its
/// snippet, and a search needs the words, so the documents are read as the
/// list is shown, newest first, and the list fills in as they arrive.
/// nothing here logs or keeps a word anywhere but in memory.
@MainActor
final class MeetingsLibraryModel: ObservableObject {
    /// what is selected: a meeting on disk, or the one being recorded, which
    /// has no file yet.
    enum Selection: Hashable, Sendable {
        case recording
        case meeting(URL)
    }

    /// when a meeting happened, as the list groups it. a meeting from the
    /// future (a clock that was wrong) is today's.
    enum Group: Int, CaseIterable, Sendable {
        case today, yesterday, thisWeek, earlier

        var title: String {
            switch self {
            case .today: "today"
            case .yesterday: "yesterday"
            case .thisWeek: "this week"
            case .earlier: "earlier"
            }
        }

        private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
                return false
            }
            return calendar.isDate(date, inSameDayAs: yesterday)
        }

        static func of(_ date: Date, now: Date, calendar: Calendar) -> Group {
            if date >= now || calendar.isDate(date, inSameDayAs: now) { return .today }
            if isYesterday(date, now: now, calendar: calendar) { return .yesterday }
            if let week = calendar.dateInterval(of: .weekOfYear, for: now), week.contains(date) {
                return .thisWeek
            }
            return .earlier
        }
    }

    /// one meeting as a row shows it.
    struct Entry: Identifiable, Equatable, Sendable {
        let summary: MeetingSummary
        /// its title, or the call app's name with "call" after it.
        let title: String
        let speakers: [String]
        /// one line about it: the notes' first sentence, else what was first
        /// said. empty until the document has been read.
        let snippet: String
        let hasNotes: Bool
        let hasWords: Bool

        var id: URL { summary.fileURL }
    }

    /// an entry in a result list, with the words around a hit in the notes
    /// or the transcript when that is why it is there.
    struct Item: Identifiable, Equatable, Sendable {
        let entry: Entry
        let hit: String?

        var id: URL { entry.id }
    }

    struct Section: Identifiable, Equatable, Sendable {
        let group: Group
        let items: [Item]

        var id: Group { group }
    }

    enum Copy: Sendable {
        case summary, transcript, both
    }

    /// the file operations, handed in so a test keeps the meetings in memory.
    /// they run off the main actor: a meeting file can be megabytes.
    struct Files: Sendable {
        var read: @Sendable (URL) throws -> MeetingDocument
        /// when the file last changed: what a cached document is checked against.
        var stamp: @Sendable (URL) -> Date?
        var setTitle: @Sendable (_ title: String?, URL) throws -> Void
        /// names a speaker, as the file shows them (`them 2`), or puts the
        /// label back when the name is nil.
        var nameSpeaker: @Sendable (_ shown: String, _ name: String?, URL) throws -> Void = { _, _, _ in }
        /// the names to suggest for a speaker: the people the mac remembers.
        var knownNames: @Sendable () -> [String] = { [] }

        static let onDisk = onDisk(naming: .live)

        static func onDisk(naming: SpeakerNaming) -> Files {
            Files(
                read: { try MeetingTranscriptFile.document(at: $0) },
                stamp: {
                    (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate]
                        as? Date
                },
                setTitle: { try MeetingTranscriptFile.setTitle($0, at: $1) },
                nameSpeaker: { try naming.rename($0, to: $1, at: $2) },
                knownNames: { naming.knownNames() })
        }
    }

    @Published private(set) var entries: [Entry] = []
    /// the entries a search leaves, in groups, newest first. every entry,
    /// when there is no search.
    @Published private(set) var sections: [Section] = []
    @Published var selection: Selection?
    /// what the search field holds.
    @Published var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    /// the folder has been read at least once: before that, an empty list is
    /// not yet an empty folder.
    @Published private(set) var hasLoaded = false
    /// nil while all is well; otherwise a sentence to show as it is.
    @Published private(set) var failure: String?

    /// told after a file was changed here (a rename, a delete): for whatever
    /// else lists them to read them again.
    var onChange: ((URL) -> Void)?

    private struct Loaded: Sendable {
        let document: MeetingDocument
        let stamp: Date?
        /// title, notes and words in one string, for a search to look through,
        /// folded the way a search folds: a search is then a plain look
        /// through it, and not a fold of every meeting on every keystroke.
        let haystack: String
        /// what its row shows, worked out when the file is read: each walks
        /// the whole document, and the list is laid out again often.
        let speakers: [String]
        let snippet: String
    }

    /// where the meetings come from; the owner may point it somewhere else
    /// (the folder was changed in settings) before the next `reload`.
    var load: @Sendable () -> [MeetingSummary]
    private let files: Files
    private let delete: @MainActor (URL) throws -> Void
    private let now: () -> Date
    private let calendar: Calendar

    private var summaries: [MeetingSummary] = []
    private var loaded: [URL: Loaded] = [:]
    private var generation = 0

    init(
        load: @escaping @Sendable () -> [MeetingSummary],
        files: Files = .onDisk,
        delete: @escaping @MainActor (URL) throws -> Void,
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.load = load
        self.files = files
        self.delete = delete
        self.now = now
        self.calendar = calendar
    }

    // MARK: - reading

    /// reads the folder again, and then the documents of whatever is new or
    /// changed since. what is on the list is published as soon as the tops of
    /// the files are read, and again as documents arrive; the call returns
    /// when the last has. a second call replaces a first still going.
    func reload() async {
        generation += 1
        let mine = generation
        let load = load
        let files = files

        let top = await Task.detached { () -> (found: [MeetingSummary], stamps: [URL: Date]) in
            let found = load()
            var stamps: [URL: Date] = [:]
            for summary in found {
                stamps[summary.fileURL] = files.stamp(summary.fileURL)
            }
            return (found, stamps)
        }.value
        guard mine == generation else { return }

        summaries = top.found.sorted { $0.started > $1.started }
        let present = Set(summaries.map(\.fileURL))
        loaded = loaded.filter { present.contains($0.key) }
        hasLoaded = true
        rebuild()

        let stale = summaries.map(\.fileURL).filter { url in
            guard let cached = loaded[url] else { return true }
            return cached.stamp != top.stamps[url]
        }
        await readDocuments(stale, mine)
    }

    /// reads these documents four at a time, publishing after each batch so
    /// the list fills in from the top.
    private func readDocuments(_ urls: [URL], _ mine: Int) async {
        let files = files
        var next = urls[...]
        while !next.isEmpty {
            let batch = Array(next.prefix(8))
            next = next.dropFirst(batch.count)
            let results = await withTaskGroup(of: (URL, Loaded?).self) { group in
                for url in batch {
                    group.addTask { (url, Self.read(url, with: files)) }
                }
                var all: [URL: Loaded] = [:]
                for await (url, result) in group {
                    if let result { all[url] = result }
                }
                return all
            }
            guard mine == generation else { return }
            for (url, result) in results { loaded[url] = result }
            rebuild()
        }
    }

    private nonisolated static func read(_ url: URL, with files: Files) -> Loaded? {
        let stamp = files.stamp(url)
        guard let document = try? files.read(url) else { return nil }
        let haystack = [
            document.displayTitle, document.summary ?? "", document.sessions
                .flatMap(\.turns).map(\.text).joined(separator: "\n"),
        ].joined(separator: "\n")
        return Loaded(
            document: document, stamp: stamp, haystack: folded(haystack),
            speakers: document.speakersWithYou, snippet: document.snippet)
    }

    /// reads one file again, now: after a change made here.
    private func refresh(_ url: URL) async {
        let files = files
        let result = await Task.detached { Self.read(url, with: files) }.value
        if let result { loaded[url] = result }
        rebuild()
    }

    // MARK: - what the list shows

    func document(for url: URL) -> MeetingDocument? {
        loaded[url]?.document
    }

    func entry(for url: URL) -> Entry? {
        entries.first { $0.id == url }
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// every meeting the list shows, top to bottom.
    var visible: [Entry] {
        sections.flatMap { $0.items.map(\.entry) }
    }

    /// published only when it changed: every publish lays the window out
    /// again, and a reload that found nothing new is most of them.
    private func rebuild() {
        let rebuilt = summaries.map(makeEntry)
        if rebuilt != entries { entries = rebuilt }
        refilter()
    }

    private func makeEntry(_ summary: MeetingSummary) -> Entry {
        guard let cached = loaded[summary.fileURL] else {
            return Entry(
                summary: summary, title: MeetingDocument.untitled(app: summary.app),
                speakers: [], snippet: "", hasNotes: false, hasWords: true)
        }
        let document = cached.document
        return Entry(
            summary: summary, title: document.displayTitle, speakers: cached.speakers,
            snippet: cached.snippet, hasNotes: document.summary != nil,
            hasWords: document.hasWords)
    }

    private func refilter() {
        let needle = trimmedQuery
        let items: [Item]
        if needle.isEmpty {
            items = entries.map { Item(entry: $0, hit: nil) }
        } else {
            let foldedNeedle = Self.folded(needle)
            items = entries.compactMap { match($0, needle, folded: foldedNeedle) }
        }
        let today = now()
        let grouped = Dictionary(grouping: items) {
            Group.of($0.entry.summary.started, now: today, calendar: calendar)
        }
        let regrouped = Group.allCases.compactMap { group in
            grouped[group].map { Section(group: group, items: $0) }
        }
        if regrouped != sections { sections = regrouped }
    }

    /// a meeting is a hit when its title, notes or words have the query in
    /// them, ignoring case and accents. one not read yet can only be found
    /// by its call app's name.
    private func match(_ entry: Entry, _ needle: String, folded foldedNeedle: String) -> Item? {
        guard let cached = loaded[entry.id] else {
            return Self.contains(entry.title, needle) ? Item(entry: entry, hit: nil) : nil
        }
        guard cached.haystack.contains(foldedNeedle) else { return nil }
        if Self.contains(entry.title, needle) { return Item(entry: entry, hit: nil) }
        let document = cached.document
        if let notes = document.summary, let hit = Self.excerpt(of: notes, for: needle) {
            return Item(entry: entry, hit: hit)
        }
        for session in document.sessions {
            for turn in session.turns {
                if let hit = Self.excerpt(of: turn.text, for: needle) {
                    return Item(entry: entry, hit: hit)
                }
            }
        }
        return Item(entry: entry, hit: nil)
    }

    /// `text` as a search sees it: case and accents gone, as
    /// `MeetingTranscriptFind.options` ignores them.
    private nonisolated static func folded(_ text: String) -> String {
        text.folding(options: MeetingTranscriptFind.options, locale: nil)
    }

    private static func contains(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: MeetingTranscriptFind.options) != nil
    }

    /// the words around the first place `needle` is in `text`, on one line.
    static func excerpt(of text: String, for needle: String) -> String? {
        guard let range = text.range(of: needle, options: MeetingTranscriptFind.options) else {
            return nil
        }
        let before = text.index(range.lowerBound, offsetBy: -32, limitedBy: text.startIndex)
        let after = text.index(range.upperBound, offsetBy: 64, limitedBy: text.endIndex)
        let start = before ?? text.startIndex
        let end = after ?? text.endIndex
        let flat = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (before == nil ? "" : "…") + flat + (after == nil ? "" : "…")
    }

    // MARK: - changing a meeting

    /// gives the meeting a name, or takes its name away when `title` is
    /// blank, so it goes by its call app again. the file sanitises it.
    @discardableResult
    func rename(_ url: URL, to title: String) async -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = files
        do {
            try await Task.detached { try files.setTitle(name.isEmpty ? nil : name, url) }.value
        } catch {
            failure = "couldn’t rename that one."
            return false
        }
        failure = nil
        await refresh(url)
        onChange?(url)
        return true
    }

    /// gives a speaker a name everywhere in the meeting, or puts their label
    /// back when `name` is blank. a name that cannot be written is not an
    /// error: it is refused by the file and the speaker stays as they were.
    @discardableResult
    func nameSpeaker(_ shown: String, as name: String, in url: URL) async -> Bool {
        let files = files
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await Task.detached { try files.nameSpeaker(shown, typed.isEmpty ? nil : typed, url) }.value
        } catch {
            failure = "couldn’t name that speaker."
            return false
        }
        failure = nil
        await refresh(url)
        onChange?(url)
        return true
    }

    /// the people to suggest when naming a speaker.
    func knownNames() -> [String] {
        files.knownNames()
    }

    /// throws the meeting away (to the trash, with its audio), and selects
    /// the one beside it. a delete that did not happen is said, and the row
    /// stays.
    @discardableResult
    func remove(_ url: URL) -> Bool {
        let order = visible.map(\.id)
        do {
            try delete(url)
        } catch {
            // SPEC §4: a delete that did not happen must not look like one
            // that did.
            failure = "couldn’t delete that one — it’s still on disk."
            return false
        }
        failure = nil
        summaries.removeAll { $0.fileURL == url }
        loaded[url] = nil
        if selection == .meeting(url) {
            selection = Self.neighbour(of: url, in: order).map(Selection.meeting)
        }
        rebuild()
        onChange?(url)
        return true
    }

    func dismissFailure() {
        failure = nil
    }

    /// the one below, else the one above, once `url` is gone.
    static func neighbour(of url: URL, in order: [URL]) -> URL? {
        guard let index = order.firstIndex(of: url) else { return nil }
        if index + 1 < order.count { return order[index + 1] }
        return index > 0 ? order[index - 1] : nil
    }

    /// the arrow keys: one step through the list, stopping at its ends. with
    /// nothing selected, down picks the first and up the last.
    static func stepped(
        _ current: Selection?, by delta: Int, in order: [Selection]
    ) -> Selection? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return delta > 0 ? order.first : order.last
        }
        return order[min(max(index + delta, 0), order.count - 1)]
    }

    // MARK: - copying

    /// what a copy button puts on the pasteboard, as plain text. the notes
    /// as the file keeps them (markdown); the transcript as the summary was
    /// asked about it; both under one title.
    static func text(_ copy: Copy, of document: MeetingDocument) -> String {
        switch copy {
        case .summary:
            return document.summary ?? ""
        case .transcript:
            return document.transcriptText
        case .both:
            var parts = ["# \(document.displayTitle)"]
            if let notes = document.summary { parts.append("## summary\n\(notes)") }
            parts.append("## transcript\n\(document.transcriptText)")
            return parts.joined(separator: "\n\n")
        }
    }
}
