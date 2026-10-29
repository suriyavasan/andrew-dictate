import XCTest

final class LiveFeedTests: XCTestCase {
    private var root: URL!
    private let started = Date(timeIntervalSince1970: 1_792_000_000)
    private let utc = TimeZone(secondsFromGMT: 0)!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
    }

    private func feed(keep: Int = LiveFeed.keptFeeds) -> LiveFeed {
        LiveFeed(
            directory: root.appendingPathComponent("live", isDirectory: true), keep: keep,
            processID: 4242, timeZone: utc, now: { [started] in started.addingTimeInterval(95) })
    }

    private func objects(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    private func line(
        _ speaker: LiveLine.Speaker, at seconds: Int, _ text: String,
        confirmed: Bool = true, id: UUID = UUID()
    ) -> LiveLine {
        LiveLine(id: id, speaker: speaker, at: .seconds(seconds), text: text, isConfirmed: confirmed)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testAMeetingStartsWithAStartLine() throws {
        let session = try XCTUnwrap(feed().begin(app: "zoom", started: started, youName: "Suriya"))
        let first = try XCTUnwrap(objects(session.url).first)
        XCTAssertEqual(first["v"] as? Int, 1)
        XCTAssertEqual(first["event"] as? String, "start")
        XCTAssertEqual(first["meeting"] as? String, session.id)
        XCTAssertEqual(first["app"] as? String, "zoom")
        XCTAssertEqual(first["started"] as? String, "2026-10-14T17:46:40Z")
        XCTAssertEqual(first["pid"] as? Int, 4242)
        XCTAssertEqual(first["you"] as? String, "Suriya")
    }

    func testTheIdIsTheNameTheTranscriptWillMostLikelyHave() throws {
        let session = try XCTUnwrap(feed().begin(app: "Google Chrome", started: started, youName: nil))
        XCTAssertEqual(session.id, "2026-10-14-1746-google-chrome")
        let again = try XCTUnwrap(feed().begin(app: "Google Chrome", started: started, youName: nil))
        XCTAssertEqual(again.id, "2026-10-14-1746-google-chrome-2")
    }

    func testALineHasWhoWhenAndWhat() throws {
        let session = try XCTUnwrap(feed().begin(app: "zoom", started: started, youName: "Suriya"))
        session.record(line(.them, at: 7, "  let's start with the budget. "))
        session.record(line(.you, at: 3_725, "sure"))
        let lines = try objects(session.url).dropFirst()
        let first = try XCTUnwrap(lines.first)
        XCTAssertEqual(first["v"] as? Int, 1)
        XCTAssertEqual(first["meeting"] as? String, session.id)
        XCTAssertEqual(first["app"] as? String, "zoom")
        XCTAssertEqual(first["started"] as? String, "2026-10-14T17:46:40Z")
        XCTAssertEqual(first["seq"] as? Int, 1)
        XCTAssertEqual(first["at"] as? String, "00:00:07")
        XCTAssertEqual(first["wall"] as? String, "2026-10-14T17:46:47Z")
        XCTAssertEqual(first["side"] as? String, "them")
        XCTAssertEqual(first["speaker"] as? String, "them")
        XCTAssertEqual(first["text"] as? String, "let's start with the budget.")
        let second = try XCTUnwrap(lines.last)
        XCTAssertEqual(second["seq"] as? Int, 2)
        XCTAssertEqual(second["at"] as? String, "01:02:05")
        XCTAssertEqual(second["side"] as? String, "you")
        XCTAssertEqual(second["speaker"] as? String, "Suriya")
    }

    func testWithoutANameYouAreYou() throws {
        for name in [nil, "", " : "] as [String?] {
            let session = try XCTUnwrap(feed().begin(app: "meeting", started: started, youName: name))
            session.record(line(.you, at: 1, "hello"))
            XCTAssertEqual(try objects(session.url).last?["speaker"] as? String, "you")
            session.end(saved: nil)
        }
    }

    func testTheKeysComeInTheOrderAnAgentReadsThem() throws {
        let session = try XCTUnwrap(feed().begin(app: "zoom", started: started, youName: nil))
        session.record(line(.them, at: 1, "hi"))
        let raw = try String(contentsOf: session.url, encoding: .utf8).split(separator: "\n").last.map(String.init)
        let keys = ["v", "meeting", "app", "started", "seq", "at", "wall", "side", "speaker", "text"]
        let positions = keys.map { raw?.range(of: "\"\($0)\":")?.lowerBound }
        XCTAssertFalse(positions.contains(where: { $0 == nil }))
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
    }

    func testOnlySettledLinesAreWrittenAndEachOnce() throws {
        let session = try XCTUnwrap(feed().begin(app: "zoom", started: started, youName: nil))
        let id = UUID()
        session.record(line(.them, at: 1, "so the bud", confirmed: false, id: id))
        XCTAssertEqual(try objects(session.url).count, 1)
        session.record(line(.them, at: 1, "so the budget", id: id))
        session.record(line(.them, at: 1, "so the budget is", id: id))
        session.record(line(.them, at: 2, "   "))
        let lines = try objects(session.url).dropFirst()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["text"] as? String, "so the budget")
        XCTAssertEqual(session.lines, 1)
    }

    func testAMeetingEndsWithAnEndLineAndNothingIsWrittenAfter() throws {
        let session = try XCTUnwrap(feed().begin(app: "zoom", started: started, youName: nil))
        session.record(line(.them, at: 1, "hi"))
        let saved = URL(fileURLWithPath: "/tmp/meetings/2026-10/2026-10-14-1746-zoom.md")
        session.end(saved: saved)
        session.record(line(.them, at: 2, "too late"))
        session.end(saved: nil)
        let all = try objects(session.url)
        XCTAssertEqual(all.count, 3)
        let end = try XCTUnwrap(all.last)
        XCTAssertEqual(end["event"] as? String, "end")
        XCTAssertEqual(end["v"] as? Int, 1)
        XCTAssertEqual(end["meeting"] as? String, session.id)
        XCTAssertEqual(end["saved"] as? String, saved.path)
        XCTAssertEqual(end["lines"] as? Int, 1)
        XCTAssertEqual(end["ended"] as? String, "2026-10-14T17:48:15Z")
        XCTAssertFalse(session.isOpen)
    }

    func testAMeetingThatKeptNothingSaysSo() throws {
        let session = try XCTUnwrap(feed().begin(app: "zoom", started: started, youName: nil))
        session.end(saved: nil)
        XCTAssertTrue(try XCTUnwrap(objects(session.url).last)["saved"] is NSNull)
    }

    func testTheFolderIsPrivateAndSoIsEachFile() throws {
        let live = feed()
        // a folder that was already there, open to everyone.
        try FileManager.default.createDirectory(
            at: live.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let session = try XCTUnwrap(live.begin(app: "zoom", started: started, youName: nil))
        XCTAssertEqual(try permissions(live.directory), 0o700)
        XCTAssertEqual(try permissions(session.url), 0o600)
    }

    func testCurrentPointsAtTheMeetingRecordingAndIsLetGoOfAtTheEnd() throws {
        let live = feed()
        let session = try XCTUnwrap(live.begin(app: "zoom", started: started, youName: nil))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: live.current.path),
            session.url.lastPathComponent)
        session.record(line(.them, at: 1, "through the link"))
        XCTAssertTrue(try String(contentsOf: live.current, encoding: .utf8).contains("through the link"))
        session.end(saved: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.current.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: live.current.path))
    }

    func testAMeetingThatEndsAfterTheNextBeganLeavesTheNextOnesLink() throws {
        let live = feed()
        let first = try XCTUnwrap(live.begin(app: "zoom", started: started, youName: nil))
        let second = try XCTUnwrap(live.begin(app: "meet", started: started.addingTimeInterval(600), youName: nil))
        first.end(saved: nil)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: live.current.path),
            second.url.lastPathComponent)
    }

    func testOnlyTheNewestFeedsAreKept() throws {
        let live = feed(keep: 3)
        var ids: [String] = []
        for n in 0..<6 {
            let session = try XCTUnwrap(live.begin(
                app: "zoom", started: started.addingTimeInterval(Double(n) * 3_600), youName: nil))
            ids.append(session.id)
            session.end(saved: nil)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: live.directory.path).sorted()
        XCTAssertEqual(names, ids.suffix(3).map { "\($0).jsonl" })
    }

    func testTheMeetingRecordingIsNeverPrunedAway() throws {
        let live = feed(keep: 1)
        let newer = try XCTUnwrap(live.begin(app: "zoom", started: started.addingTimeInterval(7_200), youName: nil))
        // begun later but dated earlier: it sorts first, and it is the live one.
        let older = try XCTUnwrap(live.begin(app: "zoom", started: started, youName: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: older.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.url.path))
    }

    func testNothingIsWrittenBeforeAMeetingBegins() {
        let live = feed()
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.directory.path))
    }

    func testAFolderThatCannotBeMadeIsNoFeedAndNoTrouble() throws {
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let live = LiveFeed(directory: blocker.appendingPathComponent("live"))
        XCTAssertNil(live.begin(app: "zoom", started: started, youName: nil))
    }

    func testTheSupportFolderHoldsItInALiveFolder() {
        let support = URL(fileURLWithPath: "/tmp/support")
        XCTAssertEqual(LiveFeed.inSupport(support).directory.path, "/tmp/support/live")
    }
}
