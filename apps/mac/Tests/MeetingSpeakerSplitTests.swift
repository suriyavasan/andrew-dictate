import XCTest

/// The speaker split through the coordinator: the far side handed to the
/// diarizer a piece at a time while the meeting records, and only the tail
/// at the stop; a piece it throws on is a meeting with fewer numbers, not a
/// lost one; and the file numbers its speakers 1, 2, 3 with no holes. The
/// diarizer's pieces are a second of audio here, so a meeting of a few
/// seconds has several.
@MainActor
final class MeetingSpeakerSplitTests: XCTestCase {
    private var dir: URL!
    private var source: ChunkSource!
    private var transcriber: ScriptedTranscriber!
    private var hearing: PieceHearing!
    private var records: [MeetingRecord] = []
    private var book: VoiceBook!
    private var prints: MeetingVoicePrints!
    private var yourName: String?
    private var rememberVoices = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-speaker-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = ChunkSource()
        transcriber = ScriptedTranscriber()
        hearing = PieceHearing()
        records = []
        book = VoiceBook(url: dir.appendingPathComponent("voices.json"))
        prints = MeetingVoicePrints(folder: dir.appendingPathComponent("meeting-voices"))
        yourName = nil
        rememberVoices = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func coordinator(
        thresholds: MeetingThresholds = .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(60),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600))
    ) -> MeetingCoordinator {
        let c = MeetingCoordinator(
            source: source,
            makeTranscriber: { [transcriber] _ in transcriber! },
            diarizer: PieceDiarizer(ear: hearing),
            spool: MeetingSpool(root: dir.appendingPathComponent("spool")),
            hookRunner: HookRunner(logURL: dir.appendingPathComponent("hooks.log")),
            voiceBook: book,
            voicePrints: prints,
            thresholds: thresholds,
            preferences: { [unowned self] in
                MeetingPreferences(
                    folder: dir.appendingPathComponent("docs"), hook: nil,
                    model: .whisperLargeV3Turbo, keepAudio: .deleteAtOnce,
                    yourName: yourName, rememberVoices: rememberVoices)
            }
        )
        c.keepMeetingRecord = { [weak self] in self?.records.append($0) }
        return c
    }

    /// Three and a half seconds of meeting. The three whole seconds go to
    /// the diarizer while it records, each stamped where it is on the spool;
    /// the stop hands over the last half second and nothing else.
    func testTheDiarizerHearsTheMeetingAsItGoesAndOnlyTheTailAtTheStop() async throws {
        let c = coordinator()
        c.start()
        await source.awaitStart()
        for s in 0..<3 {
            source.send(loud(at: .seconds(s)))
        }
        source.send(loud(at: .seconds(3), seconds: 0.5))
        await hearing.heard(3)

        XCTAssertEqual(hearing.pieces, [
            .init(at: .seconds(0), samples: 16_000),
            .init(at: .seconds(1), samples: 16_000),
            .init(at: .seconds(2), samples: 16_000),
        ])

        // the last half second is still on its way through `ingest` when the
        // third piece is heard; a stop before it is spooled has no tail.
        await until { c.elapsed >= .seconds(3.5) }
        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(hearing.pieces.dropFirst(3), [.init(at: .seconds(3), samples: 8_000)])
        XCTAssertEqual(records.first?.split?.skipped, 0)
        XCTAssertNotNil(records.first?.split?.tailS)
    }

    /// The diarizer throws on the second second, both times. The meeting is
    /// written all the same; the turn said in it is plain `them`, and the
    /// two voices it did hear are `them 1` and `them 2` — the diarizer
    /// calls them 7 and 3.
    func testAPieceThatFailsDoesNotFailTheMeetingAndTheNumbersHaveNoHoles() async throws {
        hearing.fail(at: .seconds(1), times: 2)
        hearing.speak([(from: .zero, number: 7), (from: .seconds(2), number: 3)])
        transcriber.finalTurns = [
            them("hello", at: 0.2),
            them("can you hear me", at: 1.2),
            them("yes", at: 2.2),
            them("good", at: 3.2),
        ]
        let c = coordinator()
        c.start()
        await source.awaitStart()
        for s in 0..<4 {
            source.send(loud(at: .seconds(s)))
        }
        await hearing.heard(3)

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(records.map(\.outcome), [.saved])
        XCTAssertEqual(records.first?.split?.skipped, 1)
        XCTAssertEqual(try lines(), [
            "[00:00:00] them 1: hello",
            "[00:00:01] them: can you hear me",
            "[00:00:02] them 2: yes good",
        ])
    }

    /// A turn keeps where it ended through the split: two turns of the
    /// same voice nine seconds apart, the first ending eight seconds before
    /// the second begins, are two paragraphs. Without the end, the file
    /// would judge them by where they began, and join them.
    func testATurnKeepsItsEndThroughTheSplit() async throws {
        hearing.speak([(from: .zero, number: 1), (from: .seconds(5), number: 2), (from: .seconds(9), number: 1)])
        transcriber.finalTurns = [
            them("are we all here", at: 1, end: 2),
            them("one moment", at: 6, end: 7),
            them("right then", at: 10, end: 11),
            them("let us begin", at: 15, end: 16),
        ]
        let c = coordinator()
        c.start()
        await source.awaitStart()
        // a second at a time, each heard before the next: sixteen at once
        // on a loaded runner are more than the split lets wait.
        for s in 0..<16 {
            source.send(loud(at: .seconds(s)))
            await hearing.heard(s + 1)
        }

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(try lines(), [
            "[00:00:01] them 1: are we all here",
            "[00:00:06] them 2: one moment",
            "[00:00:10] them 1: right then",
            "[00:00:15] them 1: let us begin",
        ])
    }

    /// A tap that kept calling back with silence: the quiet probe went
    /// unheard at 11 s and the gap ran to 21 s, where the far side was heard
    /// again — and every chunk of it was spooled. A new voice speaks from
    /// there. The turn at 23.5 s is at 23.5 s on the spool, in the new
    /// voice, not ten seconds back in the first.
    func testAfterAGapTheSpoolKeptRecordingThroughTheSpeakersAreTheOnesSpeakingThen() async throws {
        hearing.speak([(from: .zero, number: 7), (from: .seconds(21), number: 3)])
        transcriber.finalTurns = [
            them("before the gap", at: 0.5),
            them("after the gap", at: 23.5),
        ]
        source.anythingIsPlaying = true
        let c = coordinator(thresholds: .init(
            probeTimeout: .seconds(1), silenceTimeout: .seconds(5),
            silenceFloor: 0.001, quietNudgeAfter: .seconds(3_600),
            quietProbeWindow: .seconds(2)))
        var events: [MeetingEvent] = []
        c.onEvent = { events.append($0) }
        c.start()
        await source.awaitStart()
        // silence while something plays from 2 s: asked at 8 s, unheard by
        // 11 s, and the tap goes on calling back with nothing in it. Each
        // second heard before the next, so none is let go for being behind.
        for s in 0..<25 {
            source.send((2..<20).contains(s) ? silence(at: .seconds(s)) : loud(at: .seconds(s)))
            await hearing.heard(s + 1)
        }
        await until { c.elapsed >= .seconds(25) }
        XCTAssertEqual(events, [.started, .gapBegan, .gapEnded])

        c.stop()
        await c.untilWrittenOut()

        XCTAssertEqual(try lines(), [
            "[00:00:00] them 1: before the gap",
            "[00:00:23] them 2: after the gap",
        ])
    }

    // MARK: - names

    /// Priya was named in an earlier meeting and her voice is in the book.
    /// `them 1` sounds like her and `them 2` like nobody; you are Suriya.
    /// The file says who spoke, by name, and keeps the voices so the rest
    /// can be named later.
    func testARememberedVoiceAndYourNameReachTheFile() async throws {
        book.learn([1, 0, 0], as: "Priya")
        yourName = "Suriya"
        rememberVoices = true
        hearing.speak([(from: .zero, number: 4), (from: .seconds(2), number: 8)])
        hearing.embeddings = ["them 4": [0.97, 0.1, 0], "them 8": [0, 1, 0]]
        transcriber.finalTurns = [
            MeetingTurn(speaker: .you, at: .seconds(0.5), text: "hello all"),
            them("hello", at: 0.2),
            them("yes", at: 2.2),
        ]
        try await record(seconds: 4)

        let text = try transcriptText()
        XCTAssertTrue(text.contains("speakers: ["))
        XCTAssertTrue(text.contains("participants: [Suriya, Priya]"))
        XCTAssertTrue(text.contains("voices:\n- you: Suriya\n- them 1: Priya\n"))
        XCTAssertTrue(text.contains("] Suriya: hello all"))
        XCTAssertTrue(text.contains("] Priya: hello"))
        XCTAssertTrue(text.contains("] them 2: yes"))

        // the voice that was recognised sharpened her average; both were kept.
        XCTAssertEqual(book.people().map(\.name), ["Priya"])
        XCTAssertEqual(book.people()[0].samples, 2)
        let url = try XCTUnwrap(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first).fileURL
        let kept = prints.prints(for: url)
        XCTAssertEqual(Set(kept.keys), ["them 1", "them 2"])
        XCTAssertEqual(kept["them 1"]?.taught, "Priya")
        XCTAssertNil(kept["them 2"]?.taught)
    }

    /// With "remember voices" off, your name still goes in the file, and no
    /// voice is matched, taught or kept.
    func testWithRememberingOffNobodyIsRecognisedOrKept() async throws {
        book.learn([1, 0, 0], as: "Priya")
        yourName = "Suriya"
        rememberVoices = false
        hearing.speak([(from: .zero, number: 4), (from: .seconds(2), number: 8)])
        hearing.embeddings = ["them 4": [1, 0, 0], "them 8": [0, 1, 0]]
        transcriber.finalTurns = [
            MeetingTurn(speaker: .you, at: .seconds(0.5), text: "hello all"),
            them("hello", at: 0.2),
            them("yes", at: 2.2),
        ]
        try await record(seconds: 4)

        let text = try transcriptText()
        XCTAssertTrue(text.contains("] Suriya: hello all"))
        XCTAssertTrue(text.contains("] them 1: hello"))
        XCTAssertFalse(text.contains("Priya"))
        XCTAssertEqual(book.people()[0].samples, 1)
        let url = try XCTUnwrap(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first).fileURL
        XCTAssertTrue(prints.prints(for: url).isEmpty)
    }

    /// Two clusters that both sound like Priya: neither is a name nobody
    /// should be sure of. Neither is named, but both are kept.
    func testTwoVoicesThatSoundLikeOnePersonAreNotNamed() async throws {
        book.learn([1, 0, 0], as: "Priya")
        rememberVoices = true
        hearing.speak([(from: .zero, number: 4), (from: .seconds(2), number: 8)])
        hearing.embeddings = ["them 4": [0.9, 0.3, 0], "them 8": [0.9, 0, 0.3]]
        transcriber.finalTurns = [them("hello", at: 0.2), them("yes", at: 2.2)]
        try await record(seconds: 4)

        let text = try transcriptText()
        XCTAssertFalse(text.contains("Priya"))
        XCTAssertFalse(text.contains("participants"))
        XCTAssertEqual(book.people()[0].samples, 1)
    }

    /// A piece the diarizer was too far behind to hear leaves `them`, and
    /// the numbers close up: the voice that was `them 2` to the diarizer is
    /// `them 1` in the file, and its embedding is the one kept under that.
    func testTheEmbeddingFollowsTheNumberTheFileGaveTheVoice() async throws {
        rememberVoices = true
        hearing.fail(at: .seconds(1), times: 2)
        hearing.speak([(from: .zero, number: 7), (from: .seconds(2), number: 3)])
        hearing.embeddings = ["them 7": [1, 0, 0], "them 3": [0, 1, 0]]
        transcriber.finalTurns = [
            them("hello", at: 1.2),
            them("yes", at: 2.2),
            them("good", at: 3.2),
        ]
        try await record(seconds: 4)

        let url = try XCTUnwrap(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first).fileURL
        let text = try transcriptText()
        XCTAssertTrue(text.contains("] them: hello"))
        XCTAssertTrue(text.contains("] them 1: yes good"))
        // the file's `them 1` is the diarizer's `them 2`.
        XCTAssertEqual(prints.prints(for: url)["them 1"]?.embedding, [0, 1, 0])
        XCTAssertNil(prints.prints(for: url)["them 2"])
        XCTAssertNil(prints.prints(for: url)["them"])
    }

    /// The whole of it: a meeting is saved with an unnamed voice, it is
    /// named by hand, and the next meeting recognises it.
    func testNamingAVoiceByHandIsRecognisedInTheNextMeeting() async throws {
        rememberVoices = true
        hearing.speak([(from: .zero, number: 4), (from: .seconds(2), number: 8)])
        hearing.embeddings = ["them 4": [1, 0, 0], "them 8": [0, 1, 0]]
        transcriber.finalTurns = [them("hello", at: 0.2), them("yes", at: 2.2)]
        try await record(seconds: 4)
        let url = try XCTUnwrap(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first).fileURL

        let naming = SpeakerNaming(voiceBook: book, voicePrints: prints, remembering: { true })
        try naming.rename("them 2", to: "Rahul", at: url)
        XCTAssertTrue(try transcriptText().contains("] Rahul: yes"))
        XCTAssertEqual(book.people().map(\.name), ["Rahul"])
        XCTAssertEqual(prints.prints(for: url)["them 2"]?.taught, "Rahul")

        // the second meeting: the same voice, a different day.
        source = ChunkSource()
        hearing = PieceHearing()
        hearing.speak([(from: .zero, number: 9)])
        hearing.embeddings = ["them 9": [0.05, 0.99, 0]]
        transcriber.finalTurns = [them("morning", at: 0.2)]
        try await record(seconds: 4)
        let second = try XCTUnwrap(
            MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
                .first { $0.fileURL != url }).fileURL
        let text = try String(contentsOf: second, encoding: .utf8)
        XCTAssertTrue(text.contains("] Rahul: morning"), text)
        XCTAssertEqual(book.people()[0].samples, 2)
    }

    /// Naming by hand and changing your mind: the voice is taken out of the
    /// first person and put into the second, and out of both when the label
    /// is put back.
    func testRenamingMovesTheVoiceBetweenPeopleAndBackOut() async throws {
        rememberVoices = true
        hearing.speak([(from: .zero, number: 4), (from: .seconds(2), number: 8)])
        hearing.embeddings = ["them 4": [1, 0, 0], "them 8": [0, 1, 0]]
        transcriber.finalTurns = [them("hello", at: 0.2), them("yes", at: 2.2)]
        try await record(seconds: 4)
        let url = try XCTUnwrap(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first).fileURL
        let naming = SpeakerNaming(voiceBook: book, voicePrints: prints, remembering: { true })

        try naming.rename("them 1", to: "Priya", at: url)
        try naming.rename("Priya", to: "Priyanka", at: url)
        XCTAssertEqual(book.people().map(\.name), ["Priyanka"])
        XCTAssertEqual(book.people()[0].samples, 1)
        XCTAssertEqual(prints.prints(for: url)["them 1"]?.taught, "Priyanka")

        try naming.rename("Priyanka", to: nil, at: url)
        XCTAssertTrue(book.people().isEmpty)
        XCTAssertNil(prints.prints(for: url)["them 1"]?.taught)
        XCTAssertTrue(try transcriptText().contains("] them 1: hello"))
    }

    /// With "remember voices" off a name goes into the file and nowhere else.
    func testNamingWithRememberingOffTeachesNothing() async throws {
        rememberVoices = true
        hearing.speak([(from: .zero, number: 4), (from: .seconds(2), number: 8)])
        hearing.embeddings = ["them 4": [1, 0, 0], "them 8": [0, 1, 0]]
        transcriber.finalTurns = [them("hello", at: 0.2), them("yes", at: 2.2)]
        try await record(seconds: 4)
        let url = try XCTUnwrap(MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs")).first).fileURL

        let naming = SpeakerNaming(voiceBook: book, voicePrints: prints, remembering: { false })
        try naming.rename("them 1", to: "Priya", at: url)
        XCTAssertTrue(try transcriptText().contains("] Priya: hello"))
        XCTAssertTrue(book.people().isEmpty)
    }

    // MARK: -

    private func record(seconds: Int) async throws {
        let c = coordinator()
        c.start()
        await source.awaitStart()
        for s in 0..<seconds {
            source.send(loud(at: .seconds(s)))
        }
        await hearing.heard(seconds - 1)
        c.stop()
        await c.untilWrittenOut()
    }

    private func transcriptText() throws -> String {
        let files = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        return try String(contentsOf: try XCTUnwrap(files.last).fileURL, encoding: .utf8)
    }

    private func silence(at: Duration) -> MeetingAudioChunk {
        .init(you: Array(repeating: 0, count: 16_000),
              them: Array(repeating: 0, count: 16_000), at: at)
    }

    /// Until `done`, or two seconds.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func loud(at: Duration, seconds: Double = 1) -> MeetingAudioChunk {
        let n = Int(16_000 * seconds)
        return .init(you: Array(repeating: 0.05, count: n),
                     them: (0..<n).map { sin(Float($0) * 0.05) * 0.3 }, at: at)
    }

    private func them(_ text: String, at: Double, end: Double? = nil) -> MeetingTurn {
        MeetingTurn(speaker: .them(nil), at: .seconds(at), text: text, end: end.map { .seconds($0) })
    }

    /// The body of the one transcript written: its paragraphs.
    private func lines() throws -> [String] {
        let files = MeetingTranscriptFile.listAll(in: dir.appendingPathComponent("docs"))
        let file = try XCTUnwrap(files.first)
        return try String(contentsOf: file.fileURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("[") }
    }
}

// MARK: - fakes

/// A diarizer that hears in pieces of a second, through one hearing the
/// test can look into.
private struct PieceDiarizer: MeetingDiarizer {
    let ear: PieceHearing

    func hearing() -> (any SpeakerHearing)? {
        ear
    }

    func split(them: [Float], turns: [MeetingTurn]) async -> [MeetingTurn] {
        turns
    }
}

/// Keeps where each piece began and how long it was; throws on a piece it
/// is told to; numbers a turn by the voice speaking from where it began.
private final class PieceHearing: SpeakerHearing, @unchecked Sendable {
    struct Piece: Equatable {
        let at: Duration
        let samples: Int
    }

    let pieceLength = 16_000
    private let lock = NSLock()
    private var _pieces: [Piece] = []
    private var failures: [Duration: Int] = [:]
    private var voices: [(from: Duration, number: Int)] = []
    private var _embeddings: [String: [Float]] = [:]

    /// The embedding behind each label the file will give a voice.
    var embeddings: [String: [Float]] {
        get { lock.withLock { _embeddings } }
        set { lock.withLock { _embeddings = newValue } }
    }

    func voices(of turns: [MeetingTurn]) async -> [String: [Float]] {
        embeddings
    }

    var pieces: [Piece] {
        lock.withLock { _pieces }
    }

    func speak(_ voices: [(from: Duration, number: Int)]) {
        lock.withLock { self.voices = voices }
    }

    func fail(at: Duration, times: Int) {
        lock.withLock { failures[at] = times }
    }

    func hear(_ piece: [Float], at: Duration) async throws {
        let thrown = lock.withLock { () -> Bool in
            _pieces.append(Piece(at: at, samples: piece.count))
            guard let left = failures[at], left > 0 else { return false }
            failures[at] = left - 1
            return true
        }
        if thrown {
            throw Garbled()
        }
    }

    func split(_ turns: [MeetingTurn]) async -> [MeetingTurn] {
        let voices = lock.withLock { self.voices }
        return turns.map { turn in
            guard case .them = turn.speaker,
                  let voice = voices.last(where: { $0.from <= turn.at })
            else { return turn }
            return turn.said(by: .them(voice.number))
        }
    }

    /// Until `count` pieces have been handed over, or two seconds.
    func heard(_ count: Int) async {
        for _ in 0..<200 {
            if pieces.count >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Garbled: Error {}
}

/// A tap: one stream of chunks per start, finished by its stop.
private final class ChunkSource: MeetingAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: AsyncStream<MeetingAudioChunk>.Continuation?
    private var starts = 0
    private var _anythingIsPlaying: Bool?

    /// What the source last heard of the mac playing anything.
    var anythingIsPlaying: Bool? {
        get { lock.withLock { _anythingIsPlaying } }
        set { lock.withLock { _anythingIsPlaying = newValue } }
    }

    func start() async throws -> AsyncStream<MeetingAudioChunk> {
        let (stream, chunks) = AsyncStream<MeetingAudioChunk>.makeStream()
        lock.withLock {
            self.chunks = chunks
            starts += 1
        }
        return stream
    }

    func rebuild() async throws {}

    func stop() async {
        lock.withLock {
            defer { chunks = nil }
            return chunks
        }?.finish()
    }

    func send(_ chunk: MeetingAudioChunk) {
        _ = lock.withLock { chunks }?.yield(chunk)
    }

    /// Until the tap has been opened, or two seconds.
    func awaitStart() async {
        for _ in 0..<200 {
            if lock.withLock({ starts > 0 }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Hears nothing and finishes with the turns it was given.
private final class ScriptedTranscriber: MeetingTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _finalTurns: [MeetingTurn] = []
    let lines = AsyncStream<LiveLine> { $0.finish() }

    var finalTurns: [MeetingTurn] {
        get { lock.withLock { _finalTurns } }
        set { lock.withLock { _finalTurns = newValue } }
    }

    func begin() async throws {}
    func feed(_ chunk: MeetingAudioChunk) async {}
    func finish() async -> [MeetingTurn] { finalTurns }
    func transcribe(you: [Float], them: [Float]) async throws -> [MeetingTurn] { [] }
}
