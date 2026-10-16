import XCTest

/// a transcript cut into rows, and the words found in them.
final class MeetingTranscriptBlocksTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Kolkata")!

    private func document(_ sessions: [[(String, String)]]) -> MeetingDocument {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let header = MeetingTranscriptFile.Header(
            app: "zoom", started: started, timeZone: tz, duration: .seconds(600), gaps: [],
            recovered: false, complete: true, words: 0, title: nil, template: nil,
            sessions: sessions.count, engine: "whisper-a")
        return MeetingDocument(
            header: header, summary: nil,
            sessions: sessions.enumerated().map { index, turns in
                .init(
                    started: started.addingTimeInterval(Double(index) * 86_400),
                    turns: turns.enumerated().map {
                        .init(at: .seconds($0.offset * 10), speaker: $0.element.0, text: $0.element.1)
                    })
            })
    }

    private func turns(_ items: [MeetingTranscriptBlocks.Item]) -> [MeetingTranscriptBlocks.Turn] {
        items.compactMap { if case let .turn(turn) = $0.kind { turn } else { nil } }
    }

    func testARunBeginsWhereTheSpeakerChanges() {
        let items = MeetingTranscriptBlocks.items(for: document([[
            ("you", "one"), ("you", "two"), ("them", "three"), ("you", "four"),
        ]]))

        XCTAssertEqual(turns(items).map(\.beginsRun), [true, false, true, true])
    }

    func testYouIsGoldAndOthersCycleInTheOrderTheyFirstSpoke() {
        let speakers = ["them 2", "you", "them", "them 3", "them 4", "them 5"]
        let colours = speakers.map { MeetingTranscriptBlocks.colour(of: $0, in: speakers) }

        XCTAssertEqual(colours, [0, nil, 1, 2, 3, 0])
        XCTAssertNil(MeetingTranscriptBlocks.colour(of: "stranger", in: speakers))
    }

    func testOneSessionHasNoHeadingButSeveralDo() {
        let one = MeetingTranscriptBlocks.items(for: document([[("you", "a")]]))
        XCTAssertEqual(one.count, 1)

        let two = MeetingTranscriptBlocks.items(for: document([[("you", "a")], [("them", "b")]]))
        XCTAssertEqual(two.count, 4)
        guard case let .session(heading) = two[0].kind else { return XCTFail("no heading") }
        XCTAssertFalse(heading.hasPrefix("#"))
        XCTAssertTrue(heading.contains("·"))
    }

    func testASpeakerWhoContinuesAcrossASessionBeginsAgain() {
        let items = MeetingTranscriptBlocks.items(for: document([[("you", "a")], [("you", "b")]]))

        XCTAssertEqual(turns(items).map(\.beginsRun), [true, true])
    }

    func testLiveLinesAreLaidOutByTheSameRules() {
        let lines = [
            LiveLine(speaker: .them, at: .seconds(1), text: "hi", isConfirmed: true),
            LiveLine(speaker: .them, at: .seconds(3), text: "there", isConfirmed: false),
            LiveLine(speaker: .you, at: .seconds(5), text: "hello", isConfirmed: true),
        ]

        let found = turns(MeetingTranscriptBlocks.items(live: lines))

        XCTAssertEqual(found.map(\.speaker), ["them", "them", "you"])
        XCTAssertEqual(found.map(\.beginsRun), [true, false, true])
        XCTAssertEqual(found.map(\.isConfirmed), [true, false, true])
        XCTAssertEqual(found.map(\.colour), [0, 0, nil])
    }

    func testLiveLinesKeepTheColoursOfSpeakersAlreadyOnScreen() {
        let lines = [LiveLine(speaker: .them, at: .seconds(1), text: "hi", isConfirmed: true)]

        let found = turns(MeetingTranscriptBlocks.items(live: lines, knownSpeakers: ["you", "them 1", "them"]))

        XCTAssertEqual(found.first?.colour, 1)
    }

    // MARK: - find

    func testFindCountsEveryOccurrenceInReadingOrder() {
        let items = MeetingTranscriptBlocks.items(for: document([[
            ("you", "The deploy is blocked"), ("them", "no deploy today, deploy tomorrow"),
        ]]))

        let found = MeetingTranscriptFind.matches(in: items, for: "DEPLOY")

        XCTAssertEqual(found.map(\.occurrence), [0, 0, 1])
        XCTAssertEqual(found.map(\.itemID), ["turn-0-0", "turn-0-1", "turn-0-1"])
    }

    func testFindIgnoresAccentsAndBlankQueries() {
        let items = MeetingTranscriptBlocks.items(for: document([[("you", "a café")]]))

        XCTAssertEqual(MeetingTranscriptFind.matches(in: items, for: "cafe").count, 1)
        XCTAssertTrue(MeetingTranscriptFind.matches(in: items, for: "  ").isEmpty)
        XCTAssertTrue(MeetingTranscriptFind.matches(in: items, for: "zebra").isEmpty)
    }

    func testFindDoesNotCountOverlaps() {
        XCTAssertEqual(MeetingTranscriptFind.ranges(of: "aa", in: "aaaaa").count, 2)
    }

    func testNextAndPreviousWrap() {
        XCTAssertEqual(MeetingTranscriptFind.step(2, by: 1, of: 3), 0)
        XCTAssertEqual(MeetingTranscriptFind.step(0, by: -1, of: 3), 2)
        XCTAssertEqual(MeetingTranscriptFind.step(1, by: 1, of: 3), 2)
        XCTAssertEqual(MeetingTranscriptFind.step(0, by: 1, of: 0), 0)
    }
}
