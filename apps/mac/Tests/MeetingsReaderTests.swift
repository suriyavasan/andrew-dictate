import XCTest

final class MeetingsReaderTests: XCTestCase {
    private var fixture: MCPFixture!

    override func setUpWithError() throws {
        fixture = try MCPFixture()
    }

    private func array(_ json: [String: Any], _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(json[key] as? [[String: Any]])
    }

    // MARK: - list

    func testTheListIsEveryMeetingNewestFirstAndNothingElse() throws {
        let list = try object(fixture.reader().listMeetings(limit: nil, since: nil, query: nil))
        let meetings = try array(list, "meetings")
        XCTAssertEqual(meetings.map { $0["id"] as? String }, [MCPFixture.namedID, MCPFixture.oldID])
        XCTAssertEqual(list["total"] as? Int, 2)
        XCTAssertEqual(list["more"] as? Bool, false)
    }

    func testAMeetingWithNamesSaysWhoWasInIt() throws {
        let meeting = try array(
            object(fixture.reader().listMeetings(limit: nil, since: nil, query: nil)), "meetings")[0]
        XCTAssertEqual(meeting["title"] as? String, "q4 planning")
        XCTAssertEqual(meeting["app"] as? String, "meet")
        XCTAssertEqual(meeting["started"] as? String, "2026-10-12T09:30:00Z")
        XCTAssertEqual(meeting["duration_s"] as? Int, 3_600)
        XCTAssertEqual(meeting["duration"] as? String, "1h")
        XCTAssertEqual(meeting["participants"] as? [String], ["Suriya", "Priya", "Rahul"])
        XCTAssertEqual(meeting["speakers"] as? [String], ["Suriya", "Priya", "Rahul"])
        XCTAssertEqual(meeting["complete"] as? Bool, true)
    }

    func testAMeetingFromBeforeNamesHasLabelsAndNoParticipants() throws {
        let meeting = try array(
            object(fixture.reader().listMeetings(limit: nil, since: nil, query: nil)), "meetings")[1]
        XCTAssertEqual(meeting["title"] as? String, "zoom call")
        XCTAssertEqual(meeting["participants"] as? [String], [])
        XCTAssertEqual(meeting["speakers"] as? [String], ["you", "them 1", "them 2"])
    }

    func testTheListIsLimitedAndSaysThereIsMore() throws {
        let list = try object(fixture.reader().listMeetings(limit: 1, since: nil, query: nil))
        XCTAssertEqual(try array(list, "meetings").count, 1)
        XCTAssertEqual(list["more"] as? Bool, true)
        XCTAssertEqual(list["total"] as? Int, 2)
        let zero = try object(fixture.reader().listMeetings(limit: 0, since: nil, query: nil))
        XCTAssertEqual(try array(zero, "meetings").count, 1)
    }

    func testSinceKeepsTheMeetingsFromThenOn() throws {
        let list = try object(fixture.reader().listMeetings(
            limit: nil, since: MeetingsReader.date(from: "2026-10-01"), query: nil))
        XCTAssertEqual(try array(list, "meetings").map { $0["id"] as? String }, [MCPFixture.namedID])
    }

    func testTheQueryFindsATitleAnAppOrAPerson() throws {
        func ids(_ query: String) throws -> [String?] {
            try array(object(fixture.reader().listMeetings(limit: nil, since: nil, query: query)), "meetings")
                .map { $0["id"] as? String }
        }
        XCTAssertEqual(try ids("planning"), [MCPFixture.namedID])
        XCTAssertEqual(try ids("priya"), [MCPFixture.namedID])
        XCTAssertEqual(try ids("ZOOM"), [MCPFixture.oldID])
        XCTAssertEqual(try ids("them 2"), [MCPFixture.oldID])
        XCTAssertEqual(try ids("nobody"), [])
        // what was said is search's, not the list's.
        XCTAssertEqual(try ids("roadmap"), [])
    }

    func testADateIsReadAsADayOrAsATime() {
        XCTAssertNotNil(MeetingsReader.date(from: "2026-10-01"))
        XCTAssertEqual(
            MeetingsReader.date(from: "2026-10-01T09:00:00+05:30"), fixture.date("2026-10-01T03:30:00Z"))
        XCTAssertNil(MeetingsReader.date(from: "last tuesday"))
    }

    func testAFileEditedSinceItWasListedIsListedAsItIsNow() throws {
        let reader = fixture.reader()
        _ = reader.listMeetings(limit: nil, since: nil, query: nil)
        let text = try String(contentsOf: fixture.named, encoding: .utf8)
        try text.replacingOccurrences(of: "title: q4 planning", with: "title: roadmap review")
            .write(to: fixture.named, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: fixture.named.path)
        let meeting = try array(
            object(reader.listMeetings(limit: nil, since: nil, query: nil)), "meetings")[0]
        XCTAssertEqual(meeting["title"] as? String, "roadmap review")
    }

    func testAnEmptyOrMissingFolderIsAnEmptyList() throws {
        let nothing = MeetingsReader(locations: MCPLocations(
            meetingsParent: fixture.root.appendingPathComponent("nowhere"), liveDirectory: fixture.live))
        let list = try object(nothing.listMeetings(limit: nil, since: nil, query: nil))
        XCTAssertEqual(try array(list, "meetings").count, 0)
    }

    // MARK: - get

    func testAMeetingIsItsMarkdownAsItIs() throws {
        let text = try fixture.reader().getMeeting(id: MCPFixture.namedID, turns: false)
        XCTAssertEqual(text, try String(contentsOf: fixture.named, encoding: .utf8))
        XCTAssertTrue(text.contains("participants: [Suriya, Priya, Rahul]"))
        XCTAssertTrue(text.contains("[00:00:15] Priya: The roadmap needs the Café integration first"))
    }

    func testAnIdIsForgivenItsExtensionAndItsFolder() throws {
        let reader = fixture.reader()
        let whole = try String(contentsOf: fixture.old, encoding: .utf8)
        XCTAssertEqual(try reader.getMeeting(id: "\(MCPFixture.oldID).md", turns: false), whole)
        XCTAssertEqual(try reader.getMeeting(id: "2026-09/\(MCPFixture.oldID)", turns: false), whole)
        XCTAssertEqual(try reader.getMeeting(id: " \(MCPFixture.oldID) ", turns: false), whole)
    }

    func testAnIdCannotReachOutsideTheMeetings() throws {
        try "secret".write(
            to: fixture.root.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        for id in ["../secret", "../../secret.md", "/etc/passwd", "", "notes", "README"] {
            XCTAssertThrowsError(try fixture.reader().getMeeting(id: id, turns: false), id) {
                XCTAssertTrue(($0 as? MeetingsReader.Failure)?.message.contains("list_meetings") ?? false)
            }
        }
    }

    private func parsed(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testTurnsAreWhoSaidWhatAndWhen() throws {
        let meeting = try parsed(fixture.reader().getMeeting(id: MCPFixture.namedID, turns: true))
        XCTAssertEqual(meeting["id"] as? String, MCPFixture.namedID)
        XCTAssertEqual(meeting["title"] as? String, "q4 planning")
        XCTAssertEqual(meeting["participants"] as? [String], ["Suriya", "Priya", "Rahul"])
        let turns = try array(meeting, "turns")
        XCTAssertEqual(turns.count, 4)
        XCTAssertEqual(turns[1]["at"] as? String, "00:00:15")
        XCTAssertEqual(turns[1]["speaker"] as? String, "Priya")
        XCTAssertEqual(turns[1]["text"] as? String, "The roadmap needs the Café integration first")
        XCTAssertNil(turns[1]["session"])
    }

    func testTurnsFromBeforeNamesKeepTheirLabels() throws {
        let meeting = try parsed(fixture.reader().getMeeting(id: MCPFixture.oldID, turns: true))
        XCTAssertEqual(try array(meeting, "turns").map { $0["speaker"] as? String }, ["you", "them 1", "them 2"])
    }

    func testTurnsSayWhichSessionTheyAreFromWhenThereAreSeveral() throws {
        try MeetingTranscriptFile.append(
            MeetingTranscript(
                app: "zoom", started: fixture.date("2026-09-03T12:00:00Z"), duration: .seconds(60),
                engine: "whisper-large-v3", gaps: [], recovered: false,
                turns: [.init(speaker: .them(1), at: .seconds(5), text: "one more thing")]),
            to: fixture.old, timeZone: fixture.utc)
        let meeting = try parsed(fixture.reader().getMeeting(id: MCPFixture.oldID, turns: true))
        let turns = try array(meeting, "turns")
        XCTAssertEqual(turns.map { $0["session"] as? Int }, [1, 1, 1, 2])
        XCTAssertEqual(turns.last?["at"] as? String, "00:00:05")
    }

    func testTheNotesComeWithTheTurns() throws {
        try MeetingTranscriptFile.setSummary("## decisions\n- ship friday", template: nil, at: fixture.old)
        let meeting = try parsed(fixture.reader().getMeeting(id: MCPFixture.oldID, turns: true))
        XCTAssertEqual(meeting["notes"] as? String, "## decisions\n- ship friday")
    }

    // MARK: - search

    private func hits(_ query: String, speaker: String? = nil, limit: Int? = nil) throws -> [[String: Any]] {
        try array(object(fixture.reader().searchMeetings(query: query, speaker: speaker, limit: limit)), "matches")
    }

    func testASearchFindsTheTurnsAndSaysWhoAndWhen() throws {
        let found = try hits("contract")
        XCTAssertEqual(found.map { $0["meeting"] as? String }, [MCPFixture.namedID, MCPFixture.oldID])
        XCTAssertEqual(found[0]["speaker"] as? String, "Rahul")
        XCTAssertEqual(found[0]["at"] as? String, "00:01:10")
        XCTAssertEqual(found[0]["wall"] as? String, "2026-10-12T09:31:10Z")
        XCTAssertEqual(found[0]["title"] as? String, "q4 planning")
        XCTAssertEqual(found[1]["speaker"] as? String, "them 2")
    }

    func testEveryWordMustBeThereInAnyCaseAndAnyOrder() throws {
        XCTAssertEqual(try hits("BUDGET approved").count, 1)
        XCTAssertEqual(try hits("approved budget").count, 1)
        XCTAssertEqual(try hits("budget").count, 3)
        XCTAssertEqual(try hits("budget contract").count, 0)
        XCTAssertEqual(try hits("cafe").count, 1, "an accent is not in the way")
    }

    func testASpeakerIsAskedForByNameByLabelOrAsYou() throws {
        XCTAssertEqual(try hits("", speaker: "Priya").map { $0["text"] as? String },
                       ["The roadmap needs the Café integration first", "budget is approved"])
        XCTAssertEqual(try hits("budget", speaker: "priya").count, 1)
        // the label a name replaced finds the person, in the file that names them.
        XCTAssertEqual(try hits("", speaker: "them 1").count, 3)
        // you are "you" in one file and Suriya in the other.
        XCTAssertEqual(try hits("", speaker: "you").map { $0["speaker"] as? String }, ["Suriya", "you"])
        XCTAssertEqual(try hits("", speaker: "Suriya").count, 1)
        XCTAssertEqual(try hits("contract", speaker: "Priya").count, 0)
    }

    func testASearchIsLimitedAndSaysThereIsMore() throws {
        let json = try object(fixture.reader().searchMeetings(query: "the", speaker: nil, limit: 2))
        XCTAssertEqual(try array(json, "matches").count, 2)
        XCTAssertEqual(json["more"] as? Bool, true)
        let all = try object(fixture.reader().searchMeetings(query: "budget", speaker: nil, limit: 10))
        XCTAssertEqual(all["more"] as? Bool, false)
    }

    func testALongTurnIsQuotedNotDumped() throws {
        let long = String(repeating: "budget ", count: 400)
        try fixture.write(MeetingTranscript(
            app: "teams", started: fixture.date("2026-10-13T08:00:00Z"), duration: .seconds(60),
            engine: "whisper-large-v3", gaps: [], recovered: false,
            turns: [.init(speaker: .them(nil), at: .seconds(1), text: long)]))
        let quote = try XCTUnwrap(try hits("budget")[0]["text"] as? String)
        XCTAssertEqual(quote.count, MeetingsReader.quoteLimit + 1)
        XCTAssertTrue(quote.hasSuffix("…"))
    }

    func testASearchAcrossHundredsOfMeetingsIsQuick() throws {
        for n in 0..<400 {
            try fixture.write(MeetingTranscript(
                app: "zoom", started: fixture.date("2025-01-01T08:00:00Z").addingTimeInterval(Double(n) * 3_600),
                duration: .seconds(1_800), engine: "whisper-large-v3", gaps: [], recovered: false,
                turns: (0..<60).map {
                    .init(speaker: .them(1 + $0 % 3), at: .seconds($0 * 20),
                          text: "line \($0) of the weekly sync about tickets and releases, nothing else")
                }))
        }
        let reader = fixture.reader()
        let began = ContinuousClock.now
        let first = try object(reader.listMeetings(limit: 5, since: nil, query: nil))
        XCTAssertEqual(first["total"] as? Int, 402)
        let json = try object(reader.searchMeetings(query: "roadmap", speaker: nil, limit: nil))
        XCTAssertEqual(try array(json, "matches").count, 2)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(5))
    }

    // MARK: - live

    func testNoLiveMeetingIsSaidSo() throws {
        let json = try object(fixture.reader().liveMeeting(afterSeq: nil))
        XCTAssertEqual(json["recording"] as? Bool, false)
        XCTAssertTrue(json["last_meeting"] is NSNull)
    }

    func testTheMeetingRecordingNowAndItsLines() throws {
        let session = try fixture.feed(lines: [(.them, 3, "hello everyone"), (.you, 9, "hi")])
        let json = try object(fixture.reader().liveMeeting(afterSeq: nil))
        XCTAssertEqual(json["recording"] as? Bool, true)
        XCTAssertEqual(json["meeting"] as? String, session.id)
        XCTAssertEqual(json["app"] as? String, "zoom")
        XCTAssertEqual(json["started"] as? String, "2026-10-14T11:00:00Z")
        XCTAssertEqual(json["you"] as? String, "Suriya")
        XCTAssertEqual(json["participants"] as? [String], ["Suriya"])
        XCTAssertEqual(json["last_seq"] as? Int, 2)
        let lines = try array(json, "lines")
        XCTAssertEqual(lines.map { $0["speaker"] as? String }, ["them", "Suriya"])
        XCTAssertEqual(lines.map { $0["side"] as? String }, ["them", "you"])
        XCTAssertEqual(lines[0]["at"] as? String, "00:00:03")
        XCTAssertEqual(lines[0]["wall"] as? String, "2026-10-14T11:00:03Z")
        XCTAssertEqual(lines[0]["text"] as? String, "hello everyone")
    }

    func testPollingGetsOnlyWhatCameAfter() throws {
        let session = try fixture.feed(lines: [(.them, 3, "one"), (.them, 4, "two")])
        let reader = fixture.reader()
        let first = try object(reader.liveMeeting(afterSeq: nil))
        session.record(LiveLine(speaker: .them, at: .seconds(8), text: "three", isConfirmed: true))
        let next = try object(reader.liveMeeting(afterSeq: first["last_seq"] as? Int))
        XCTAssertEqual(try array(next, "lines").map { $0["text"] as? String }, ["three"])
        XCTAssertEqual(next["last_seq"] as? Int, 3)
        let none = try object(reader.liveMeeting(afterSeq: 3))
        XCTAssertEqual(try array(none, "lines").count, 0)
        XCTAssertEqual(none["last_seq"] as? Int, 3)
    }

    func testALongMeetingIsAnsweredWithItsLatestLinesOrInPages() throws {
        let lines = (1...(MeetingsReader.liveLines + 50)).map { (LiveLine.Speaker.them, $0, "line \($0)") }
        _ = try fixture.feed(lines: lines)
        let latest = try object(fixture.reader().liveMeeting(afterSeq: nil))
        XCTAssertEqual(try array(latest, "lines").count, MeetingsReader.liveLines)
        XCTAssertEqual(try array(latest, "lines").last?["seq"] as? Int, MeetingsReader.liveLines + 50)
        XCTAssertEqual(latest["earlier_lines_left_out"] as? Bool, true)
        let page = try object(fixture.reader().liveMeeting(afterSeq: 10))
        XCTAssertEqual(try array(page, "lines").first?["seq"] as? Int, 11)
        XCTAssertEqual(page["more"] as? Bool, true)
    }

    func testAnEndedMeetingIsNotRecordingAndSaysWhereItWentTo() throws {
        let saved = fixture.named!
        _ = try fixture.feed(lines: [(.them, 1, "bye")], end: .some(saved))
        let json = try object(fixture.reader().liveMeeting(afterSeq: nil))
        XCTAssertEqual(json["recording"] as? Bool, false)
        let last = try XCTUnwrap(json["last_meeting"] as? [String: Any])
        XCTAssertEqual(last["saved"] as? String, saved.path)
        XCTAssertEqual(last["saved_id"] as? String, MCPFixture.namedID)
        XCTAssertEqual(last["interrupted"] as? Bool, false)
    }

    func testAFeedWhoseAppDiedIsNotRecording() throws {
        _ = try fixture.feed(lines: [(.them, 1, "and then the app crashed")])
        let json = try object(fixture.reader(alive: false).liveMeeting(afterSeq: nil))
        XCTAssertEqual(json["recording"] as? Bool, false)
        XCTAssertEqual((json["last_meeting"] as? [String: Any])?["interrupted"] as? Bool, true)
    }

    func testALineBeingWrittenRightNowIsWaitedFor() throws {
        let session = try fixture.feed(lines: [(.them, 1, "whole")])
        let handle = try FileHandle(forWritingTo: session.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"v":1,"seq":2,"text":"cut o"#.utf8))
        try handle.close()
        let json = try object(fixture.reader().liveMeeting(afterSeq: nil))
        XCTAssertEqual(json["last_seq"] as? Int, 1)
    }

    func testReadingNeverChangesAnything() throws {
        _ = try fixture.feed(lines: [(.them, 1, "x")])
        func snapshot() throws -> [String: Date] {
            var found: [String: Date] = [:]
            for case let path as String in FileManager.default.enumerator(atPath: fixture.root.path)! {
                let full = fixture.root.appendingPathComponent(path).path
                found[path] = try FileManager.default.attributesOfItem(atPath: full)[.modificationDate] as? Date
            }
            return found
        }
        let before = try snapshot()
        let reader = fixture.reader()
        _ = reader.listMeetings(limit: nil, since: nil, query: nil)
        _ = try reader.getMeeting(id: MCPFixture.oldID, turns: true)
        _ = reader.searchMeetings(query: "budget", speaker: nil, limit: nil)
        _ = reader.liveMeeting(afterSeq: nil)
        XCTAssertEqual(try snapshot(), before)
    }
}
