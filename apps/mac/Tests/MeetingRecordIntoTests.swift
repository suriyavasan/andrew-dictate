import XCTest

/// Recording into: a meeting started with a title, or into a transcript that
/// is already there. It is written as a new file, or as a session at the end
/// of that file, and a crash between the two changes neither. And the meter
/// the meetings window draws, which only ever sees numbers.
@MainActor
final class MeetingRecordIntoTests: XCTestCase {
    private var dir: URL!
    private var source: FakeSource!
    private var transcriber: FakeTranscriber!
    private var events: [MeetingEvent] = []

    /// 2026-08-23 06:13:20 UTC, and the next day.
    private let firstDay = Date(timeIntervalSince1970: 1_787_000_000)
    private let nextDay = Date(timeIntervalSince1970: 1_787_086_400)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-record-into-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeSource()
        transcriber = FakeTranscriber()
        events = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var docs: URL { dir.appendingPathComponent("docs") }
    private var spool: MeetingSpool { MeetingSpool(root: dir.appendingPathComponent("spool")) }

    private func coordinator(starting date: Date) -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: FakeDiarizer(),
            spool: spool,
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(30),
                settleBeforeRebuild: .milliseconds(20)),
            date: { date },
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: docs, hook: nil, model: .whisperLargeV3Turbo,
                    keepAudio: .deleteAtOnce)
            }
        )
        c.onEvent = { [weak self] in self?.events.append($0) }
        return c
    }

    // MARK: - a title

    func testAMeetingStartedWithATitleIsSavedWithIt() async throws {
        transcriber.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "hello")]
        let c = coordinator(starting: firstDay)

        try await record(c, title: "stand-up")

        let saved = try XCTUnwrap(savedSummary())
        let document = try MeetingTranscriptFile.document(at: saved.fileURL)
        XCTAssertEqual(document.header.title, "stand-up")
        XCTAssertEqual(document.displayTitle, "stand-up")
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1)
    }

    func testAMeetingStartedWithoutOneHasNone() async throws {
        let c = coordinator(starting: firstDay)

        try await record(c)

        let saved = try XCTUnwrap(savedSummary())
        XCTAssertNil(try MeetingTranscriptFile.document(at: saved.fileURL).header.title)
    }

    // MARK: - recording into a file

    func testAMeetingRecordedIntoAFileIsAnotherSessionOfIt() async throws {
        let existing = try firstMeeting(titled: "stand-up")
        transcriber.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "second morning")]
        let c = coordinator(starting: nextDay)

        try await record(c, appendingTo: existing)

        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1, "no second file")
        let saved = try XCTUnwrap(savedSummary())
        XCTAssertEqual(saved.fileURL, existing, "the event names the file that grew")
        let document = try MeetingTranscriptFile.document(at: existing)
        XCTAssertEqual(document.sessions.count, 2)
        XCTAssertEqual(document.header.sessions, 2)
        XCTAssertEqual(document.header.title, "stand-up")
        XCTAssertEqual(document.sessions[0].turns.map(\.text), ["first morning"])
        XCTAssertEqual(document.sessions[1].turns.map(\.text), ["second morning"])
        XCTAssertEqual(saved.sessions, 2)
    }

    /// a file deleted while the meeting ran is not a meeting lost: it is a
    /// file of its own, with the title it was started with.
    func testAFileDeletedMeanwhileMeansANewFile() async throws {
        let existing = try firstMeeting(titled: "stand-up")
        transcriber.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "second morning")]
        let c = coordinator(starting: nextDay)

        c.start(title: "stand-up", appendingTo: existing)
        await source.awaitStart()
        try FileManager.default.removeItem(at: existing)
        try await finish(c)

        let all = MeetingTranscriptFile.listAll(in: docs)
        XCTAssertEqual(all.count, 1)
        let saved = try XCTUnwrap(all.first)
        XCTAssertNotEqual(saved.fileURL, existing)
        XCTAssertEqual(saved.sessions, 1)
        XCTAssertEqual(try MeetingTranscriptFile.document(at: saved.fileURL).header.title, "stand-up")
        XCTAssertEqual(savedSummary()?.fileURL, saved.fileURL)
    }

    /// a file edited past reading takes nothing, and costs the meeting
    /// nothing either.
    func testAFileThatWillNotTakeTheSessionMeansANewFile() async throws {
        let existing = try firstMeeting(titled: "stand-up")
        try "not a transcript".write(to: existing, atomically: true, encoding: .utf8)
        transcriber.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "second morning")]
        let c = coordinator(starting: nextDay)

        try await record(c, appendingTo: existing)

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "not a transcript")
        let saved = try XCTUnwrap(savedSummary())
        XCTAssertNotEqual(saved.fileURL, existing)
        XCTAssertTrue(
            try String(contentsOf: saved.fileURL, encoding: .utf8).contains("second morning"))
    }

    /// kept audio is one session's: reading it again would replace both
    /// sessions with one, so the file is left as it is and the lamp says why.
    func testTranscribingAgainIsRefusedForAMeetingWithSeveralSessions() async throws {
        let existing = try firstMeeting(titled: "stand-up")
        try MeetingTranscriptFile.append(
            MeetingTranscript(
                app: "meeting", started: nextDay, duration: .seconds(30),
                engine: "whisperLargeV3Turbo", gaps: [], recovered: false,
                turns: [.init(speaker: .you, at: .seconds(1), text: "second morning")]),
            to: existing)
        let before = try String(contentsOf: existing, encoding: .utf8)
        let c = coordinator(starting: nextDay)

        await c.transcribeAgain(existing, with: .whisperLargeV3)

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), before)
        XCTAssertTrue(
            events.contains {
                if case .couldNotTranscribeAgain = $0 { return true }
                return false
            }, "\(events)")
        XCTAssertNil(c.transcribingAgain)
    }

    // MARK: - the manifest

    func testTheManifestKeepsTheTitleAndTheFile() throws {
        let target = URL(fileURLWithPath: "/x/meetings/2026-08/stand-up.md")
        let handle = try spool.begin(.init(
            app: "meeting", started: firstDay, engine: "whisperLargeV3Turbo",
            model: .whisperLargeV3Turbo, title: "stand-up", appendTo: target))
        try Data().write(to: handle.audioURL)

        let manifest = try XCTUnwrap(spool.orphan(handle))
        XCTAssertEqual(manifest.title, "stand-up")
        XCTAssertEqual(manifest.appendTo, target)
    }

    /// a manifest written before either existed reads, and says neither.
    func testAManifestFromBeforeThemStillReads() throws {
        let handle = try spool.begin(.init(
            app: "meeting", started: firstDay, engine: "whisperLargeV3Turbo",
            model: .whisperLargeV3Turbo))
        try Data().write(to: handle.audioURL)
        let written = try String(contentsOf: handle.manifestURL, encoding: .utf8)
        XCTAssertFalse(written.contains("title"), "absent, not null: \(written)")
        XCTAssertFalse(written.contains("appendTo"), written)

        let manifest = try XCTUnwrap(spool.orphan(handle))
        XCTAssertNil(manifest.title)
        XCTAssertNil(manifest.appendTo)
    }

    // MARK: - recovery

    func testARecoveredMeetingRecordedIntoAFileIsAppendedToIt() async throws {
        let existing = try firstMeeting(titled: "stand-up")
        try await orphan(title: "stand-up", appendTo: existing)
        transcriber.batchTurns = [.init(speaker: .you, at: .seconds(1), text: "after the crash")]
        let c = coordinator(starting: nextDay)

        c.recoverOrphans()
        let saved = try await awaitSaved()

        XCTAssertEqual(saved.fileURL, existing)
        XCTAssertEqual(MeetingTranscriptFile.listAll(in: docs).count, 1)
        let document = try MeetingTranscriptFile.document(at: existing)
        XCTAssertEqual(document.sessions.count, 2)
        XCTAssertEqual(document.sessions[1].turns.map(\.text), ["after the crash"])
        XCTAssertTrue(document.header.recovered)
        XCTAssertEqual(spool.orphans().count, 0)
    }

    func testARecoveredMeetingKeepsItsTitleAndMakesANewFileWhenItsFileIsGone() async throws {
        let gone = docs.appendingPathComponent("meetings/2026-08/gone.md")
        try await orphan(title: "retro", appendTo: gone)
        transcriber.batchTurns = [.init(speaker: .you, at: .seconds(1), text: "after the crash")]
        let c = coordinator(starting: nextDay)

        c.recoverOrphans()
        let saved = try await awaitSaved()

        XCTAssertNotEqual(saved.fileURL, gone)
        XCTAssertEqual(try MeetingTranscriptFile.document(at: saved.fileURL).header.title, "retro")
    }

    // MARK: - levels

    func testTheLevelsFollowTheAudioAndGoQuietWhenTheMeetingStops() async throws {
        let c = coordinator(starting: firstDay)
        XCTAssertEqual(c.levels, .zero)

        c.start()
        await source.awaitStart()
        source.send(loud(at: .zero))
        await settle()

        XCTAssertGreaterThan(c.levels.them, 0.3)
        XCTAssertGreaterThan(c.levels.you, 0.2)
        XCTAssertLessThanOrEqual(c.levels.them, 1)

        try await finish(c)
        XCTAssertEqual(c.levels, .zero)
    }

    func testTheLevelsOfALazyHolderAreQuietUntilItIsBuilt() {
        let lazy = LazyMeetings(
            coordinator: { fatalError("a question builds nothing") },
            notifier: { fatalError("a question builds nothing") })
        XCTAssertEqual(lazy.levels, .zero)
    }

    func testTheMeterMapsDecibelsToTheBar() {
        XCTAssertEqual(MeetingLevels.level(rms: 0), 0)
        XCTAssertEqual(MeetingLevels.level(rms: -1), 0)
        XCTAssertEqual(MeetingLevels.level(rms: .nan), 0)
        XCTAssertEqual(MeetingLevels.level(rms: 0.001), 0, accuracy: 0.0001, "-60 dB is the floor")
        XCTAssertEqual(MeetingLevels.level(rms: 1), 1, accuracy: 0.0001, "0 dB is the top")
        XCTAssertEqual(MeetingLevels.level(rms: 4), 1, "past it is the top")
        XCTAssertEqual(MeetingLevels.level(rms: 0.00001), 0, "below it is the floor")
        // -30 dB is half way, however small that looks in raw numbers.
        XCTAssertEqual(MeetingLevels.level(rms: 0.0316228), 0.5, accuracy: 0.001)
        XCTAssertLessThan(MeetingLevels.level(rms: 0.05), MeetingLevels.level(rms: 0.2))
    }

    func testABarRisesFasterThanItFalls() {
        let up = MeetingLevels.smoothed(0, toward: 1)
        let down = 1 - MeetingLevels.smoothed(1, toward: 0)
        XCTAssertGreaterThan(up, down)
        XCTAssertGreaterThan(up, 0.5)
        XCTAssertEqual(MeetingLevels.smoothed(0.4, toward: 0.4), 0.4, accuracy: 0.0001)
    }

    func testTheMeterPublishesAtMostFifteenTimesASecond() {
        var meter = MeetingLevelMeter()
        let start = ContinuousClock.now
        var published = 0
        // a chunk every 10 ms for two seconds.
        for step in 0..<200 {
            if meter.hear(youRMS: 0.1, themRMS: 0.1, at: start + .milliseconds(step * 10)) != nil {
                published += 1
            }
        }
        XCTAssertLessThanOrEqual(published, 2 * MeetingLevelMeter.rate + 1)
        XCTAssertGreaterThan(published, MeetingLevelMeter.rate)
    }

    func testTheFirstChunkIsPublishedAtOnceAndAResetStartsOver() {
        var meter = MeetingLevelMeter()
        let start = ContinuousClock.now
        XCTAssertNotNil(meter.hear(youRMS: 0.1, themRMS: 0.1, at: start))
        XCTAssertNil(meter.hear(youRMS: 0.1, themRMS: 0.1, at: start + .milliseconds(10)))
        meter.reset()
        let again = meter.hear(youRMS: 0, themRMS: 0, at: start + .milliseconds(20))
        XCTAssertEqual(again, .zero, "smoothing starts from silence again")
    }

    /// a skipped chunk is still counted: the bar the next one shows has
    /// risen on both.
    func testAThrottledChunkStillMovesTheBar() throws {
        var meter = MeetingLevelMeter()
        let start = ContinuousClock.now
        let first = try XCTUnwrap(meter.hear(youRMS: 0.01, themRMS: 0.01, at: start))
        XCTAssertNil(meter.hear(youRMS: 0.3, themRMS: 0.3, at: start + .milliseconds(10)))
        let later = try XCTUnwrap(meter.hear(youRMS: 0.3, themRMS: 0.3, at: start + .milliseconds(100)))
        let alone = MeetingLevels.smoothed(first.you, toward: MeetingLevels.level(rms: 0.3))
        XCTAssertGreaterThan(later.you, alone)
    }

    // MARK: - helpers

    /// start, hear the tap, and stop: the file is written when this returns.
    private func record(
        _ c: MeetingCoordinator, title: String? = nil, appendingTo: URL? = nil
    ) async throws {
        c.start(title: title, appendingTo: appendingTo)
        await source.awaitStart()
        try await finish(c)
    }

    private func finish(_ c: MeetingCoordinator) async throws {
        source.send(loud(at: .zero))
        source.send(loud(at: .seconds(1)))
        await settle()
        c.stop()
        await c.untilWrittenOut()
        await settle()
    }

    /// the meeting that is already on disk: one session, a title.
    private func firstMeeting(titled title: String) throws -> URL {
        try MeetingTranscriptFile.write(
            MeetingTranscript(
                app: "meeting", started: firstDay, duration: .seconds(60),
                engine: "whisperLargeV3Turbo", gaps: [], recovered: false,
                title: title,
                turns: [.init(speaker: .you, at: .seconds(1), text: "first morning")]),
            in: docs)
    }

    /// a spool a crash left behind, with a second of audio on it.
    private func orphan(title: String?, appendTo: URL?) async throws {
        let handle = try spool.begin(.init(
            app: "meeting", started: nextDay, engine: "whisperLargeV3Turbo",
            model: .whisperLargeV3Turbo, title: title, appendTo: appendTo))
        let file = try SpoolAudioFile(url: handle.audioURL)
        try await file.append(loud(at: .zero))
    }

    private func savedSummary() -> MeetingSummary? {
        for case .saved(let summary) in events.reversed() {
            return summary
        }
        return nil
    }

    /// until a meeting has been saved, or five seconds.
    private func awaitSaved() async throws -> MeetingSummary {
        for _ in 0..<500 where savedSummary() == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(savedSummary(), "\(events)")
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

// MARK: - fakes

private final class FakeSource: MeetingAudioSource, @unchecked Sendable {
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

    /// Until the tap has been opened, or two seconds.
    func awaitStart() async {
        for _ in 0..<200 {
            if lock.withLock({ starts > 0 }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FakeTranscriber: MeetingTranscriber, @unchecked Sendable {
    var finalTurns: [MeetingTurn] = []
    var batchTurns: [MeetingTurn] = []
    let lines: AsyncStream<LiveLine>

    init() {
        (lines, _) = AsyncStream<LiveLine>.makeStream()
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] { finalTurns }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { batchTurns }
}

private struct FakeDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
