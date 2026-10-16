import XCTest

/// a meeting from the first word to the second morning, with the real pieces
/// side by side and fakes only where the mac would be touched: the audio, the
/// speech model, the speaker split and the provider. it is the file that
/// carries it all — the coordinator writes it, the summaries add the notes and
/// a name, the reader and the window's list read it back, and recording into
/// it again changes what each of them says.
///
/// no word of any of it is real; the folder is a temp one.
@MainActor
final class MeetingsEndToEndTests: XCTestCase {
    private var dir: URL!
    private var source: E2ESource!
    private var transcriber: E2ETranscriber!
    private var events: [MeetingEvent] = []

    /// 2026-08-23 06:13:20 UTC, and the next day.
    private let firstDay = Date(timeIntervalSince1970: 1_787_000_000)
    private let nextDay = Date(timeIntervalSince1970: 1_787_086_400)

    // the words each piece of the file is looked for by.
    private let transcriptWord = "gizmo"
    private let firstNotes = "they agreed to ship the kestrel plan on friday."
    private let secondNotes = "they agreed to ship on friday, with a rollback ready."

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetings-end-to-end-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = E2ESource()
        transcriber = E2ETranscriber()
        events = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var docs: URL { dir.appendingPathComponent("docs") }
    private var kept: KeptAudio { KeptAudio(root: dir.appendingPathComponent("meeting-audio")) }

    // MARK: - the whole of it

    func testAMeetingIsRecordedSummarizedFoundAndRecordedIntoAgain() async throws {
        // 1. a meeting is recorded and saved.
        transcriber.turns = [
            .init(speaker: .you, at: .seconds(1), text: "let us start with the \(transcriptWord) review"),
            .init(speaker: .them(nil), at: .seconds(5), text: "it looks ready to ship"),
        ]
        try await record(coordinator(starting: firstDay))

        let saved = try XCTUnwrap(savedSummary())
        let url = saved.fileURL
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1)
        let plain = try MeetingTranscriptFile.document(at: url)
        XCTAssertNil(plain.summary, "nothing has written it up yet")
        XCTAssertNil(plain.header.title)
        XCTAssertEqual(plain.displayTitle, "meeting")

        // 2. the notes and a name are written when it is saved.
        let client = ScriptedClient { [firstNotes, secondNotes] prompt, _ in
            if prompt.instructions.hasPrefix(MeetingSummaryPrompt.titleInstructions) {
                return "\"Release Sync\""
            }
            // the notes of the whole file: the second session's words are in
            // the request only once it is in the file.
            return prompt.text.contains("rollback") ? secondNotes : firstNotes
        }
        var changed: [URL] = []
        let summaries = MeetingSummaries(
            connect: { .success(RewriteConnection(client: client, model: "m", provider: .openAI)) },
            isEnabled: { true },
            defaultTemplateID: { "auto" },
            pause: { _ in })
        summaries.onChange = { changed.append($0) }

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(summaries.state(for: url), .idle)
        XCTAssertEqual(changed, [url])
        XCTAssertEqual(client.calls.count, 2, "the notes, and a name for a meeting with none")

        // 3. the reader sees both, and the front matter says which template.
        let written = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(written.summary, firstNotes)
        XCTAssertEqual(written.header.title, "Release Sync")
        XCTAssertEqual(written.header.template, "auto")
        XCTAssertEqual(written.displayTitle, "Release Sync")
        XCTAssertEqual(written.sessions.count, 1)
        XCTAssertEqual(written.snippet, firstNotes)

        // 4. the window's list shows it, and finds it by what was said and by
        // what the notes say.
        let folder = docs
        let library = MeetingsLibraryModel(
            load: { MeetingTranscriptFile.listAll(in: folder) },
            delete: { _ in },
            now: { [nextDay] in nextDay },
            calendar: Calendar(identifier: .gregorian))
        await library.reload()

        let entry = try XCTUnwrap(library.entries.first)
        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(entry.title, "Release Sync")
        XCTAssertEqual(entry.snippet, firstNotes)
        XCTAssertTrue(entry.hasNotes)
        XCTAssertEqual(entry.speakers, ["you", "them"])

        library.query = transcriptWord
        XCTAssertEqual(library.sections.flatMap(\.items).map(\.id), [url], "a word from the transcript")
        library.query = "kestrel"
        XCTAssertEqual(library.sections.flatMap(\.items).map(\.id), [url], "a word from the summary")
        library.query = "walrus"
        XCTAssertTrue(library.sections.flatMap(\.items).isEmpty)
        library.query = ""

        // and while its audio is kept, history would offer to transcribe it again.
        let history = historyList()
        XCTAssertFalse(kept.all().isEmpty, "the first session's audio is kept")
        guard case .offer = history.again(for: try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)) else {
            return XCTFail("a meeting of one session is offered transcribe again")
        }

        // 5. the next morning it is recorded into.
        transcriber.turns = [
            .init(speaker: .you, at: .seconds(1), text: "one thing left, the rollback"),
        ]
        events = []
        source = E2ESource()  // a tap of its own: the last one has been heard
        try await record(coordinator(starting: nextDay), appendingTo: url)

        XCTAssertEqual(try XCTUnwrap(savedSummary()).fileURL, url, "the same file grew")
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1, "no second file")
        let appended = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(appended.sessions.count, 2)
        XCTAssertEqual(appended.header.sessions, 2)
        XCTAssertNil(appended.summary, "the notes were of fewer words, and go")
        XCTAssertEqual(appended.header.title, "Release Sync", "the name stays")
        XCTAssertEqual(appended.header.template, "auto", "so does the template")
        XCTAssertEqual(appended.sessions[1].turns.map(\.text), ["one thing left, the rollback"])

        // 6. saved again, it is written up again, over the whole file, and not
        // named again.
        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(client.calls.count, 3, "one more request: the notes, and no new name")
        let request = try XCTUnwrap(client.calls.last).prompt.text
        XCTAssertTrue(request.contains(transcriptWord), "the first session is in it")
        XCTAssertTrue(request.contains("rollback"), "and the second")
        let again = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(again.summary, secondNotes)
        XCTAssertEqual(again.header.title, "Release Sync")
        XCTAssertEqual(again.sessions.count, 2)

        // the list reads the change and finds the new notes.
        await library.reload()
        XCTAssertEqual(library.entries.first?.snippet, secondNotes)
        XCTAssertEqual(library.entries.first?.summary.sessions, 2)
        library.query = "rollback"
        XCTAssertEqual(library.sections.flatMap(\.items).map(\.id), [url])

        // 7. and history no longer offers to read it again: the kept audio is
        // one recording's.
        let after = historyList()
        let row = try XCTUnwrap(MeetingTranscriptFile.listAll(in: docs).first)
        XCTAssertEqual(row.sessions, 2)
        XCTAssertFalse(kept.all().isEmpty, "there is audio, and still nothing is offered")
        XCTAssertEqual(after.again(for: row), .none)
    }

    // MARK: - the pieces

    private func coordinator(starting date: Date) -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: E2EDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            keptAudio: kept,
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(30),
                settleBeforeRebuild: .milliseconds(20)),
            date: { date },
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: docs, hook: nil, model: .whisperLargeV3Turbo,
                    keepAudio: .oneDay)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        return c
    }

    /// history's list over the same folder and the same kept audio, as the
    /// settings pane makes it.
    private func historyList() -> MeetingsListModel {
        let folder = docs
        return MeetingsListModel(
            keptAudio: kept,
            installedModels: { [.whisperLargeV3] },
            transcribeAgain: { _, _ in },
            load: { MeetingTranscriptFile.listAll(in: folder) })
    }

    /// start, hear the tap, and stop: the file is written when this returns.
    private func record(_ c: MeetingCoordinator, appendingTo: URL? = nil) async throws {
        c.start(appendingTo: appendingTo)
        await source.awaitStart()
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()
        c.stop()
        await c.untilWrittenOut()
        await settle()
    }

    private func savedSummary() -> MeetingSummary? {
        for case .saved(let summary) in events.reversed() {
            return summary
        }
        return nil
    }

    private func loud(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    private func settle(for seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - fakes at the edges

private final class E2ESource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var starts = 0

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock {
            self.continuation = continuation
            starts += 1
        }
        return stream
    }

    func rebuild() async throws {}

    func stop() async {
        lock.withLock { () -> AsyncStream<MeetingAudioChunk>.Continuation? in
            defer { continuation = nil }
            return continuation
        }?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        _ = lock.withLock { continuation }?.yield(chunk)
    }

    /// until the tap has been opened, or two seconds.
    func awaitStart() async {
        for _ in 0..<200 {
            if lock.withLock({ starts > 0 }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// says the same turns whether it is read live or as a whole, so the
/// coverage check has nothing to say about them.
private final class E2ETranscriber: MeetingTranscriber, @unchecked Sendable {
    var turns: [MeetingTurn] = []
    let lines: AsyncStream<LiveLine>

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] { turns }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { turns }
}

private struct E2EDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
