import XCTest

/// a meeting file read whole, and the three ways one changes after it is
/// written: it is named, it is summarized, it is recorded into again.
final class MeetingDocumentTests: XCTestCase {
    private var parent: URL!
    private let tz = TimeZone(identifier: "Asia/Kolkata")!

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-document-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - reading every shape

    /// no `ended`, `speakers`, `words`, `title` or `sessions`, a line per
    /// fragment: the oldest file there is.
    func testAFileFromBeforeTheNewLayoutIsOneSession() throws {
        let document = try MeetingTranscriptFile.document(
            parsing: oldFile, url: URL(fileURLWithPath: "/x/old.md"))

        XCTAssertEqual(document.header.app, "teams")
        XCTAssertEqual(document.header.duration, .seconds(1800))
        XCTAssertEqual(document.header.gaps.count, 2)
        XCTAssertTrue(document.header.recovered)
        XCTAssertNil(document.header.title)
        XCTAssertNil(document.header.template)
        XCTAssertEqual(document.header.sessions, 1)
        XCTAssertNil(document.summary)
        XCTAssertEqual(document.sessions.count, 1)
        XCTAssertEqual(document.sessions[0].started, document.header.started)
        XCTAssertEqual(document.sessions[0].turns, [
            .init(at: .seconds(4), speaker: "you", text: "hi, can you"),
            .init(at: .seconds(6), speaker: "you", text: "hear me?"),
            .init(at: .seconds(9), speaker: "them", text: "yes."),
        ])
        XCTAssertEqual(document.displayTitle, "teams call")
        XCTAssertEqual(document.speakers, ["you", "them"])
    }

    func testAFileWithATitleCarriesItAndShowsIt() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(title: "stand-up", template: "standUp"), in: parent, timeZone: tz)

        let document = try MeetingTranscriptFile.document(at: url)

        XCTAssertEqual(document.header.title, "stand-up")
        XCTAssertEqual(document.header.template, "standUp")
        XCTAssertEqual(document.displayTitle, "stand-up")
        XCTAssertEqual(document.header.engine, "whisper-a")
        XCTAssertEqual(document.header.words, 10)
    }

    func testAMeetingWithNoCallAppIsJustMeeting() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(app: "meeting"), in: parent, timeZone: tz)

        XCTAssertEqual(try MeetingTranscriptFile.document(at: url).displayTitle, "meeting")
    }

    func testATitleIsOneLineWhateverItWasGiven() throws {
        let long = String(repeating: "x", count: 200)
        let url = try MeetingTranscriptFile.write(
            meeting(title: "  a\nb\u{7}c: d  "), in: parent, timeZone: tz)
        XCTAssertEqual(try MeetingTranscriptFile.document(at: url).header.title, "a b c: d")

        let longURL = try MeetingTranscriptFile.write(
            meeting(title: long, started: started().addingTimeInterval(3_600)),
            in: parent, timeZone: tz)
        XCTAssertEqual(
            try MeetingTranscriptFile.document(at: longURL).header.title?.count, 120)

        let blank = try MeetingTranscriptFile.write(
            meeting(title: " \n ", started: started().addingTimeInterval(7_200)),
            in: parent, timeZone: tz)
        XCTAssertNil(try MeetingTranscriptFile.document(at: blank).header.title)
        XCTAssertFalse(try String(contentsOf: blank, encoding: .utf8).contains("title:"))
    }

    func testTheSummaryBlockIsReadAndIsNotATurn() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        try MeetingTranscriptFile.setSummary(
            "## Meeting Summary\nthey met.\n\n---\n\n[00:00:01] you: not a turn\n",
            template: "auto", at: url)

        let document = try MeetingTranscriptFile.document(at: url)

        XCTAssertEqual(
            document.summary,
            "## Meeting Summary\nthey met.\n\n---\n\n[00:00:01] you: not a turn")
        XCTAssertEqual(document.sessions.count, 1)
        XCTAssertEqual(document.sessions[0].turns.count, 2)
        XCTAssertEqual(document.header.template, "auto")
    }

    /// the summary sits right after the front matter, and the blockquotes
    /// either side of it are fine: a file someone moved things in still reads.
    func testTheSummaryIsFoundWhicheverSideOfTheGapNoteItIsOn() throws {
        let before = """
        ---
        app: zoom
        started: 2026-08-29T14:02:11+05:30
        duration_s: 100
        complete: false
        ---
        > 1 gap — audio was lost between 00:00:41 and 00:01:03

        <!-- andrew:summary -->
        notes
        <!-- /andrew:summary -->

        [00:00:00] you: hello

        """
        let after = before
            .replacingOccurrences(of: "> 1 gap — audio was lost between 00:00:41 and 00:01:03\n\n", with: "")
            .replacingOccurrences(
                of: "<!-- /andrew:summary -->\n\n",
                with: "<!-- /andrew:summary -->\n\n> 1 gap — audio was lost between 00:00:41 and 00:01:03\n\n")
        let url = URL(fileURLWithPath: "/x/a.md")

        for text in [before, after] {
            let document = try MeetingTranscriptFile.document(parsing: text, url: url)
            XCTAssertEqual(document.summary, "notes")
            XCTAssertEqual(document.sessions[0].turns.map(\.text), ["hello"])
        }
    }

    func testASummaryThatNeverClosesIsNotASummary() throws {
        let text = """
        ---
        app: zoom
        started: 2026-08-29T14:02:11+05:30
        duration_s: 100
        ---
        <!-- andrew:summary -->
        half

        [00:00:00] you: hello

        """
        let document = try MeetingTranscriptFile.document(
            parsing: text, url: URL(fileURLWithPath: "/x/a.md"))

        XCTAssertNil(document.summary)
        XCTAssertEqual(document.sessions[0].turns.map(\.text), ["hello"])
    }

    func testSessionsAfterTheFirstAreReadWithTheirOwnStartAndClock() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        try MeetingTranscriptFile.append(second(), to: url, timeZone: tz)

        let document = try MeetingTranscriptFile.document(at: url)

        XCTAssertEqual(document.header.sessions, 2)
        XCTAssertEqual(document.sessions.count, 2)
        XCTAssertEqual(document.sessions[0].started, started())
        XCTAssertEqual(document.sessions[1].started, secondStarted())
        XCTAssertEqual(document.sessions[0].turns.count, 2)
        XCTAssertEqual(document.sessions[1].turns, [
            .init(at: .seconds(2), speaker: "them 2", text: "morning."),
            .init(at: .seconds(5), speaker: "you", text: "hi."),
        ])
        XCTAssertEqual(document.speakers, ["you", "them 1", "them 2"])
        XCTAssertEqual(document.wordCount, 12)
    }

    func testALineTheParserDoesNotKnowIsLeftOutAndAContinuationCarriesOn() throws {
        let text = """
        ---
        app: zoom
        started: 2026-08-29T14:02:11+05:30
        duration_s: 100
        ---

        stray words before anything

        [00:00:00] you: one
        and two

        some other stray words

        [100:00:00] them: late
        """
        let document = try MeetingTranscriptFile.document(
            parsing: text, url: URL(fileURLWithPath: "/x/a.md"))

        XCTAssertEqual(document.sessions[0].turns, [
            .init(at: .zero, speaker: "you", text: "one\nand two"),
            .init(at: .seconds(360_000), speaker: "them", text: "late"),
        ])
    }

    func testAFileWithNoFrontMatterCannotBeRead() {
        XCTAssertThrowsError(try MeetingTranscriptFile.document(
            parsing: "just notes", url: URL(fileURLWithPath: "/x/a.md"))
        ) { error in
            XCTAssertEqual(
                error as? MeetingTranscriptFile.Failure,
                .noFrontMatter(URL(fileURLWithPath: "/x/a.md")))
        }
    }

    // MARK: - what a window shows

    func testTheTranscriptTextIsTheTurnsAndNothingElse() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(gaps: [.init(began: .seconds(41), ended: .seconds(63))]),
            in: parent, timeZone: tz)
        try MeetingTranscriptFile.setSummary("notes", template: "auto", at: url)

        XCTAssertEqual(
            try MeetingTranscriptFile.document(at: url).transcriptText,
            """
            [00:00:04] you: hi, can you hear me?

            [00:00:09] them 1: yes. the deploy is blocked.
            """)
    }

    func testSeveralSessionsAreHeadedWithTheirDates() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        try MeetingTranscriptFile.append(second(), to: url, timeZone: tz)

        XCTAssertEqual(
            try MeetingTranscriptFile.document(at: url).transcriptText,
            """
            ## 29 aug 2026 · 14:02

            [00:00:04] you: hi, can you hear me?

            [00:00:09] them 1: yes. the deploy is blocked.

            ## 30 aug 2026 · 09:30

            [00:00:02] them 2: morning.

            [00:00:05] you: hi.
            """)
    }

    func testTheSnippetIsTheFirstProseOfTheNotes() throws {
        let document = try documentWithSummary(
            "## Meeting Summary\nThey agreed to ship on friday.\n\n## Action Items\n- [ ] call dana")

        XCTAssertEqual(document.snippet, "They agreed to ship on friday.")
    }

    func testWithoutProseTheSnippetIsTheFirstPointAndLosesItsBullet() throws {
        let document = try documentWithSummary(
            "## Yesterday\n- [ ] finished the login screen\n\n## Today\n- tests")

        XCTAssertEqual(document.snippet, "finished the login screen")
    }

    func testNoneNotedIsNotASnippetAndTheTranscriptIsTheLastResort() throws {
        XCTAssertEqual(
            try documentWithSummary("## Blockers\nNone noted.").snippet,
            "hi, can you hear me?")
        XCTAssertEqual(
            try MeetingTranscriptFile.document(
                parsing: MeetingTranscriptFile.markdown(meeting(), timeZone: tz),
                url: URL(fileURLWithPath: "/x/a.md")).snippet,
            "hi, can you hear me?")
    }

    func testALongSnippetIsCutAtAboutAHundredAndFortyCharacters() throws {
        let words = Array(repeating: "word", count: 100).joined(separator: " ")
        let snippet = try documentWithSummary(words).snippet

        XCTAssertEqual(snippet.count, 140)
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    // MARK: - setTitle

    func testSettingATitleLeavesTheRestOfTheFileAlone() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        let before = try String(contentsOf: url, encoding: .utf8)

        try MeetingTranscriptFile.setTitle("  Q3\nplanning ", at: url)

        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            after,
            before.replacingOccurrences(of: "app: zoom\n", with: "app: zoom\ntitle: Q3 planning\n"))
        XCTAssertEqual(permissions(of: url), 0o600)
    }

    func testRetitlingReplacesAndNilRemovesTheLine() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        let plain = try String(contentsOf: url, encoding: .utf8)

        try MeetingTranscriptFile.setTitle("one", at: url)
        try MeetingTranscriptFile.setTitle("two", at: url)
        XCTAssertEqual(try MeetingTranscriptFile.document(at: url).header.title, "two")

        try MeetingTranscriptFile.setTitle(nil, at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), plain)
    }

    func testTheFileNameDoesNotChangeWithTheTitle() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        let folder = url.deletingLastPathComponent()
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)

        try MeetingTranscriptFile.setTitle("a whole new name", at: url)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            before.sorted())
    }

    func testChangingAFileThatIsGoneThrowsAndMakesNothing() {
        let url = parent.appendingPathComponent("meetings/2026-08/gone.md")

        XCTAssertThrowsError(try MeetingTranscriptFile.setTitle("x", at: url)) {
            XCTAssertEqual($0 as? MeetingTranscriptFile.Failure, .gone(url))
        }
        XCTAssertThrowsError(try MeetingTranscriptFile.setSummary("x", template: "auto", at: url))
        XCTAssertThrowsError(try MeetingTranscriptFile.append(meeting(), to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testChangingAFileWithNoFrontMatterThrowsAndLeavesItAlone() throws {
        let url = parent.appendingPathComponent("notes.md")
        try "just notes\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MeetingTranscriptFile.setTitle("x", at: url))
        XCTAssertThrowsError(try MeetingTranscriptFile.append(meeting(), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "just notes\n")
    }

    // MARK: - setSummary

    func testTheSummaryGoesRightAfterTheFrontMatterAndTheTranscriptStaysPut() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(gaps: [.init(began: .seconds(41), ended: .seconds(63))]),
            in: parent, timeZone: tz)
        let before = try String(contentsOf: url, encoding: .utf8)

        try MeetingTranscriptFile.setSummary("## Notes\n- a\n", template: "standUp", at: url)

        let after = try String(contentsOf: url, encoding: .utf8)
        let frontEnd = try XCTUnwrap(before.range(of: "recovered: false\n---\n"))
        let rest = String(before[frontEnd.upperBound...])
        XCTAssertEqual(
            after,
            String(before[..<frontEnd.lowerBound])
                + "recovered: false\ntemplate: standUp\n---\n"
                + "<!-- andrew:summary -->\n## Notes\n- a\n<!-- /andrew:summary -->\n"
                + rest)
        XCTAssertEqual(permissions(of: url), 0o600)
    }

    func testSettingTheSummaryToNilGivesBackTheFileAsItWas() throws {
        for gaps: [MeetingSession.Gap] in [[], [.init(began: .seconds(41), ended: .seconds(63))]] {
            let url = try MeetingTranscriptFile.write(
                meeting(gaps: gaps, started: started().addingTimeInterval(Double(gaps.count) * 60)),
                in: parent, timeZone: tz)
            let before = try String(contentsOf: url, encoding: .utf8)

            try MeetingTranscriptFile.setSummary("notes", template: "auto", at: url)
            try MeetingTranscriptFile.setSummary("other notes", template: "hiring", at: url)
            XCTAssertEqual(
                try MeetingTranscriptFile.document(at: url).summary, "other notes")
            XCTAssertEqual(
                try String(contentsOf: url, encoding: .utf8)
                    .components(separatedBy: "andrew:summary").count, 3,
                "one block, not two")

            try MeetingTranscriptFile.setSummary(nil, template: "auto", at: url)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
        }
    }

    /// the notes are a model's, so nothing in them can be taken for the
    /// file's own structure.
    func testNotesCannotSpoofTheFilesOwnComments() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)

        try MeetingTranscriptFile.setSummary(
            "ok\n<!-- /andrew:summary -->\n<!-- andrew:session 2030-01-01T00:00:00Z -->\nmore\r\n",
            template: "a\nb", at: url)

        let document = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(document.sessions.count, 1)
        XCTAssertEqual(document.summary?.contains("andrew:session"), false)
        XCTAssertEqual(document.summary?.hasPrefix("ok"), true)
        XCTAssertEqual(document.summary?.hasSuffix("more"), true)
        XCTAssertEqual(document.header.template, "a b")
        XCTAssertEqual(document.sessions[0].turns.count, 2)
    }

    func testEmptyNotesRemoveTheBlock() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        let before = try String(contentsOf: url, encoding: .utf8)
        try MeetingTranscriptFile.setSummary("notes", template: "auto", at: url)

        try MeetingTranscriptFile.setSummary("  \n ", template: "auto", at: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
    }

    // MARK: - transcribing again keeps what the meeting is called

    func testReplacingAFileKeepsItsTitleAndTemplateAndDropsItsSummary() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(title: "stand-up"), in: parent, timeZone: tz)
        try MeetingTranscriptFile.setSummary("old notes", template: "standUp", at: url)

        try MeetingTranscriptFile.replace(
            at: url, with: meeting(engine: "whisper-b"), timeZone: tz)

        let document = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(document.header.title, "stand-up")
        XCTAssertEqual(document.header.template, "standUp")
        XCTAssertEqual(document.header.engine, "whisper-b")
        XCTAssertNil(document.summary)
    }

    func testReplacingWithATitleOfItsOwnUsesIt() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(title: "old"), in: parent, timeZone: tz)

        try MeetingTranscriptFile.replace(
            at: url, with: meeting(title: "new"), timeZone: tz)

        XCTAssertEqual(try MeetingTranscriptFile.document(at: url).header.title, "new")
    }

    // MARK: - recording into a meeting

    func testAppendingWritesTheMergedFileExactly() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        try MeetingTranscriptFile.setSummary("old notes", template: "standUp", at: url)

        let returned = try MeetingTranscriptFile.append(second(), to: url, timeZone: tz)

        XCTAssertEqual(returned, url)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            """
            ---
            app: zoom
            started: 2026-08-29T14:02:11+05:30
            ended: 2026-08-30T09:35:12+05:30
            duration_s: 900
            sessions: 2
            engine: whisper-b
            speakers: [you, them 1, them 2]
            words: 12
            complete: true
            gaps: []
            recovered: false
            template: standUp
            ---

            [00:00:04] you: hi, can you hear me?

            [00:00:09] them 1: yes. the deploy is blocked.

            <!-- andrew:session 2026-08-30T09:30:12+05:30 -->
            ## 30 aug 2026 · 09:30

            [00:00:02] them 2: morning.

            [00:00:05] you: hi.

            """)
        XCTAssertEqual(permissions(of: url), 0o600)
    }

    func testAppendingTwiceCountsThreeSessionsAndKeepsEveryTurn() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        try MeetingTranscriptFile.append(second(), to: url, timeZone: tz)
        try MeetingTranscriptFile.append(
            second(started: secondStarted().addingTimeInterval(86_400)), to: url, timeZone: tz)

        let document = try MeetingTranscriptFile.document(at: url)

        XCTAssertEqual(document.header.sessions, 3)
        XCTAssertEqual(document.sessions.count, 3)
        XCTAssertEqual(document.header.duration, .seconds(1_200))
        XCTAssertEqual(document.header.words, 14)
        XCTAssertEqual(document.sessions.map { $0.turns.count }, [2, 2, 2])
        XCTAssertEqual(
            document.sessions[2].started, secondStarted().addingTimeInterval(86_400))
    }

    func testAppendingMergesWhatTheFrontMatterCounts() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(
                gaps: [.init(began: .seconds(41), ended: .seconds(63))],
                recovered: false, reason: "the model changed"),
            in: parent, timeZone: tz)
        let incomplete = MeetingTranscript(
            app: "other", started: secondStarted(), duration: .seconds(300),
            engine: "whisper-b",
            gaps: [.init(began: .seconds(5), ended: .seconds(9))],
            recovered: true,
            turns: [.init(speaker: .them(nil), at: .seconds(1), text: "hello")])

        try MeetingTranscriptFile.append(incomplete, to: url, timeZone: tz)

        let text = try String(contentsOf: url, encoding: .utf8)
        let front = try XCTUnwrap(MeetingTranscriptFile.split(text)).front
        XCTAssertTrue(front.contains("app: zoom"), "app never changes")
        XCTAssertTrue(front.contains("started: 2026-08-29T14:02:11+05:30"))
        XCTAssertTrue(front.contains("complete: false"))
        XCTAssertTrue(front.contains("reason: the model changed; audio was lost in 1 gap"))
        XCTAssertTrue(front.contains("recovered: true"))
        XCTAssertTrue(front.contains("speakers: [you, them 1, them]"))
        XCTAssertTrue(front.contains("engine: whisper-b"))
        XCTAssertEqual(
            Array(front.drop { $0 != "gaps:" }.prefix(3)),
            ["gaps:", "- [41.0, 63.0]", "- [5.0, 9.0]"])
        // the second session says where its own hole is, on its own clock
        XCTAssertTrue(
            text.contains("andrew:session"), text)
        XCTAssertTrue(
            text.contains("> 1 gap — audio was lost between 00:00:05 and 00:00:09\n"), text)
    }

    func testAppendingToACompleteFileKeepsItCompleteAndWithoutAReason() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)

        try MeetingTranscriptFile.append(second(), to: url, timeZone: tz)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("complete: true\n"))
        XCTAssertFalse(text.contains("reason:"))
    }

    func testAppendingToAFileFromBeforeTheNewLayoutFillsInWhatItLacked() throws {
        let url = parent.appendingPathComponent("old.md")
        try oldFile.write(to: url, atomically: true, encoding: .utf8)

        try MeetingTranscriptFile.append(second(), to: url, timeZone: tz)

        let document = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(document.header.sessions, 2)
        XCTAssertEqual(document.header.words, 6 + 2)
        XCTAssertEqual(document.header.duration, .seconds(1_800 + 300))
        XCTAssertEqual(document.speakers, ["you", "them", "them 2"])
        XCTAssertEqual(document.header.gaps.count, 2)
        XCTAssertFalse(document.header.complete)
    }

    func testAppendingDropsTheSummaryAndKeepsTheTitle() throws {
        let url = try MeetingTranscriptFile.write(
            meeting(title: "stand-up"), in: parent, timeZone: tz)
        try MeetingTranscriptFile.setSummary("old notes", template: "standUp", at: url)

        try MeetingTranscriptFile.append(second(title: "ignored"), to: url, timeZone: tz)

        let document = try MeetingTranscriptFile.document(at: url)
        XCTAssertNil(document.summary)
        XCTAssertEqual(document.header.title, "stand-up")
        XCTAssertEqual(document.header.template, "standUp")
    }

    func testAnAppendedMeetingNobodySpokeInSaysSo() throws {
        let url = try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        let quiet = MeetingTranscript(
            app: "zoom", started: secondStarted(), duration: .seconds(60),
            engine: "whisper-b", gaps: [], recovered: false, nobodySpoke: true, turns: [])

        try MeetingTranscriptFile.append(quiet, to: url, timeZone: tz)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("## 30 aug 2026 · 09:30\n\n> nobody spoke\n"), text)
        XCTAssertEqual(try MeetingTranscriptFile.document(at: url).sessions[1].turns, [])
    }

    func testTheNoteBesideTheMonthsExplainsTheNewKeysAndTheSummary() throws {
        try MeetingTranscriptFile.write(meeting(), in: parent, timeZone: tz)
        let note = try String(
            contentsOf: parent.appendingPathComponent("meetings/README.md"),
            encoding: .utf8)

        for word in ["`title`", "`sessions`", "`template`", "andrew:summary", "andrew:session"] {
            XCTAssertTrue(note.contains(word), "\(word) is not in the note")
        }
    }

    // MARK: -

    private let oldFile = """
    ---
    app: teams
    started: 2026-07-02T09:00:05+05:30
    duration_s: 1800
    engine: whisper-large-v3
    complete: false
    gaps:
    - [41.2, 63.0]
    - [100.0, 104.5]
    recovered: true
    ---

    > 2 gaps — audio was lost between 00:00:41 and 00:01:03, and between 00:01:40 and 00:01:44

    [00:00:04] you: hi, can you

    [00:00:06] you: hear me?

    [00:00:09] them: yes.

    """

    private func started() -> Date {
        date(2026, 8, 29, 14, 2, 11)
    }

    private func secondStarted() -> Date {
        date(2026, 8, 30, 9, 30, 12)
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var components = DateComponents()
        components.year = y; components.month = mo; components.day = d
        components.hour = h; components.minute = mi; components.second = s
        components.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func meeting(
        app: String = "zoom",
        title: String? = nil,
        template: String? = nil,
        engine: String = "whisper-a",
        gaps: [MeetingSession.Gap] = [],
        recovered: Bool = false,
        reason: String? = nil,
        started: Date? = nil
    ) -> MeetingTranscript {
        MeetingTranscript(
            app: app, started: started ?? self.started(), duration: .seconds(600),
            engine: engine, gaps: gaps, recovered: recovered, reason: reason,
            title: title, template: template,
            turns: [
                .init(speaker: .you, at: .seconds(4), text: "hi, can you hear me?"),
                .init(speaker: .them(1), at: .seconds(9), text: "yes. the deploy is blocked."),
            ])
    }

    private func second(
        started: Date? = nil,
        title: String? = nil
    ) -> MeetingTranscript {
        MeetingTranscript(
            app: "zoom", started: started ?? secondStarted(), duration: .seconds(300),
            engine: "whisper-b", gaps: [], recovered: false, title: title,
            turns: [
                .init(speaker: .them(2), at: .seconds(2), text: "morning."),
                .init(speaker: .you, at: .seconds(5), text: "hi."),
            ])
    }

    private func documentWithSummary(_ notes: String) throws -> MeetingDocument {
        let url = try MeetingTranscriptFile.write(
            meeting(started: started().addingTimeInterval(Double.random(in: 1...1_000_000))),
            in: parent, timeZone: tz)
        try MeetingTranscriptFile.setSummary(notes, template: "auto", at: url)
        return try MeetingTranscriptFile.document(at: url)
    }

    private func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }
}
