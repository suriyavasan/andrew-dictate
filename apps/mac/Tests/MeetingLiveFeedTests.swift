import XCTest

/// the live feed as the coordinator drives it: begun when a meeting starts,
/// fed the lines the transcriber settles, ended with the transcript's path.
@MainActor
final class MeetingLiveFeedTests: XCTestCase {
    private var dir: URL!
    private var source: FakeFeedSource!
    private var transcriber: FakeFeedTranscriber!
    private var events: [MeetingEvent] = []
    private let day = Date(timeIntervalSince1970: 1_787_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-live-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = FakeFeedSource()
        transcriber = FakeFeedTranscriber()
        events = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var feeds: URL { dir.appendingPathComponent("live") }

    private func coordinator(feed: Bool = true, yourName: String? = "Suriya") -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: FakeFeedDiarizer(),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            liveFeed: feed ? LiveFeed(directory: feeds) : nil,
            thresholds: .init(
                probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
                silenceFloor: 0.001, quietNudgeAfter: .seconds(30),
                settleBeforeRebuild: .milliseconds(20)),
            date: { [day] in day },
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: dir.appendingPathComponent("docs"), hook: nil,
                    model: .whisperLargeV3Turbo, keepAudio: .deleteAtOnce, yourName: yourName)
            })
        c.onEvent = { [weak self] in self?.events.append($0) }
        return c
    }

    private func chunk(at: Duration) -> MeetingAudioChunk {
        let n = 16_000
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    private func settle() async {
        try? await Task.sleep(for: .seconds(0.3))
    }

    private func feedFile() throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: feeds.path)
            .filter { $0.hasSuffix(".jsonl") && $0 != "current.jsonl" }
        return feeds.appendingPathComponent(try XCTUnwrap(names.first))
    }

    private func objects(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func testAMeetingWritesItsLinesAsTheyAreSettledAndEndsWithItsTranscript() async throws {
        transcriber.finalTurns = [.init(speaker: .you, at: .seconds(1), text: "hello")]
        let c = coordinator()
        c.start(name: "zoom")
        await source.awaitStart()
        source.send(chunk(at: .zero))

        let current = feeds.appendingPathComponent("current.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path), "pointing at the meeting while it records")
        transcriber.say(LiveLine(speaker: .them, at: .seconds(2), text: "so the budget", isConfirmed: false))
        transcriber.say(LiveLine(speaker: .them, at: .seconds(2), text: "so the budget is fine", isConfirmed: true))
        transcriber.say(LiveLine(speaker: .you, at: .seconds(5), text: "agreed", isConfirmed: true))
        await settle()

        let during = try objects(feedFile())
        XCTAssertEqual(during.compactMap { $0["text"] as? String }, ["so the budget is fine", "agreed"])
        XCTAssertEqual(during.last?["speaker"] as? String, "Suriya")
        XCTAssertEqual(during.first?["app"] as? String, "zoom")

        c.stop()
        await c.untilWrittenOut()
        await settle()

        let all = try objects(feedFile())
        let end = try XCTUnwrap(all.last)
        XCTAssertEqual(end["event"] as? String, "end")
        var saved: URL?
        for case .saved(let summary) in events { saved = summary.fileURL }
        XCTAssertEqual(end["saved"] as? String, try XCTUnwrap(saved).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path), "nothing is recording now")
    }

    func testAMeetingWithNoFeedWritesNothing() async throws {
        let c = coordinator(feed: false)
        c.start(name: "zoom")
        await source.awaitStart()
        transcriber.say(LiveLine(speaker: .them, at: .seconds(2), text: "hello", isConfirmed: true))
        c.stop()
        await c.untilWrittenOut()
        XCTAssertFalse(FileManager.default.fileExists(atPath: feeds.path))
    }

    func testNothingIsWrittenBeforeAMeetingStartsOrAfterItEnded() async throws {
        let c = coordinator()
        XCTAssertFalse(FileManager.default.fileExists(atPath: feeds.path))
        c.start(name: "zoom")
        await source.awaitStart()
        c.stop()
        await c.untilWrittenOut()
        await settle()
        let file = try feedFile()
        let before = try Data(contentsOf: file)
        transcriber.say(LiveLine(speaker: .them, at: .seconds(9), text: "after the end", isConfirmed: true))
        await settle()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try objects(file).last?["event"] as? String, "end")
    }
}

// MARK: - fakes

private final class FakeFeedSource: MeetingAudioSource, @unchecked Sendable {
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

    func awaitStart() async {
        for _ in 0..<200 {
            if lock.withLock({ starts > 0 }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FakeFeedTranscriber: MeetingTranscriber, @unchecked Sendable {
    var finalTurns: [MeetingTurn] = []
    let lines: AsyncStream<LiveLine>
    private let emitter: AsyncStream<LiveLine>.Continuation

    init() {
        (lines, emitter) = AsyncStream<LiveLine>.makeStream()
    }

    func say(_ line: LiveLine) {
        emitter.yield(line)
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] { finalTurns }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { [] }
}

private struct FakeFeedDiarizer: MeetingDiarizer {
    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] { turns }
}
