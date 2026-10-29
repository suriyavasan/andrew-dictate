import XCTest

/// who spoke, by name, in the file: written, read back, added to, renamed and
/// renamed back; and a file from before names, which must read as it always
/// did.
final class MeetingNamesTests: XCTestCase {
    private var parent: URL!
    private let tz = TimeZone(identifier: "Asia/Kolkata")!

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    private func started(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_788_000_131 + offset)
    }

    private func transcript(
        youName: String? = nil, voices: [String: String] = [:], at offset: TimeInterval = 0,
        turns: [MeetingTurn]? = nil
    ) -> MeetingTranscript {
        MeetingTranscript(
            app: "zoom", started: started(offset), duration: .seconds(600), engine: "whisper",
            gaps: [], recovered: false, youName: youName, voices: voices,
            turns: turns ?? [
                .init(speaker: .you, at: .seconds(4), text: "hi, can you hear me?"),
                .init(speaker: .them(1), at: .seconds(9), text: "yes. the deploy is blocked."),
                .init(speaker: .them(2), at: .seconds(30), text: "i can fix it."),
                .init(speaker: .them(1), at: .seconds(60), text: "thanks 2 is the plan."),
            ])
    }

    private func front(_ text: String) -> [String] {
        text.components(separatedBy: "\n").dropFirst().prefix { $0 != "---" }.map { $0 }
    }

    // MARK: - writing

    func testAFileNobodyIsNamedInIsExactlyWhatItWas() {
        let text = MeetingTranscriptFile.markdown(transcript(), timeZone: tz)
        XCTAssertTrue(text.contains("speakers: [you, them 1, them 2]\nwords: "))
        XCTAssertFalse(text.contains("participants"))
        XCTAssertFalse(text.contains("voices"))
        XCTAssertTrue(text.contains("[00:00:04] you: hi"))
    }

    func testYourNameReplacesYouOnYourTurns() {
        let text = MeetingTranscriptFile.markdown(transcript(youName: "Suriya"), timeZone: tz)
        XCTAssertTrue(text.contains("[00:00:04] Suriya: hi, can you hear me?"))
        XCTAssertFalse(text.contains("] you:"))
        XCTAssertEqual(front(text).filter { $0.hasPrefix("speakers") }, ["speakers: [Suriya, them 1, them 2]"])
        XCTAssertTrue(text.contains("participants: [Suriya]\nvoices:\n- you: Suriya\nwords: "))
    }

    func testAFarSideNameIsOnItsTurnsAndInTheListsInOrder() {
        let text = MeetingTranscriptFile.markdown(
            transcript(youName: "Suriya", voices: ["them 2": "Rahul", "them 1": "Priya"]), timeZone: tz)
        XCTAssertEqual(front(text).filter { $0.hasPrefix("speakers") }, ["speakers: [Suriya, Priya, Rahul]"])
        XCTAssertTrue(text.contains("participants: [Suriya, Priya, Rahul]"))
        XCTAssertTrue(text.contains("voices:\n- you: Suriya\n- them 1: Priya\n- them 2: Rahul\n"))
        XCTAssertTrue(text.contains("[00:00:09] Priya: yes. the deploy is blocked."))
        XCTAssertTrue(text.contains("[00:00:30] Rahul: i can fix it."))
        XCTAssertTrue(text.contains("[00:01:00] Priya: thanks 2 is the plan."))
    }

    func testOnePersonTwoVoicesAreOneSpeakerAndOneParticipant() {
        let text = MeetingTranscriptFile.markdown(
            transcript(voices: ["them 1": "Priya", "them 2": "Priya"]), timeZone: tz)
        XCTAssertEqual(front(text).filter { $0.hasPrefix("speakers") }, ["speakers: [you, Priya]"])
        XCTAssertTrue(text.contains("participants: [Priya]"))
        XCTAssertTrue(text.contains("- them 1: Priya\n- them 2: Priya\n"))
    }

    func testANameThatCannotBeWrittenIsNotWritten() {
        let text = MeetingTranscriptFile.markdown(
            transcript(youName: "them 2", voices: ["them 1": "a: b", "them 9": "Nobody"]), timeZone: tz)
        XCTAssertTrue(text.contains("[00:00:04] you:"))
        // the colon is made a space; the label without a speaker is ignored.
        XCTAssertTrue(text.contains("[00:00:09] a b:"))
        XCTAssertFalse(text.contains("Nobody"))
    }

    func testTurnsOfOneNamedPersonStillJoinIntoAParagraph() {
        let text = MeetingTranscriptFile.markdown(
            transcript(voices: ["them 1": "Priya"], turns: [
                .init(speaker: .them(1), at: .seconds(1), text: "one"),
                .init(speaker: .them(1), at: .seconds(5), text: "two"),
            ]), timeZone: tz)
        XCTAssertTrue(text.contains("[00:00:01] Priya: one two"))
    }

    // MARK: - reading

    func testTheNamesComeBackOutOfTheFile() throws {
        let url = try MeetingTranscriptFile.write(
            transcript(youName: "Suriya", voices: ["them 1": "Priya"]), in: parent, timeZone: tz)
        let document = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(document.header.participants, ["Suriya", "Priya"])
        XCTAssertEqual(document.header.voices, [
            SpeakerName(label: "you", name: "Suriya"), SpeakerName(label: "them 1", name: "Priya"),
        ])
        XCTAssertEqual(document.speakers, ["Suriya", "Priya", "them 2"])
        XCTAssertEqual(document.youLabel, "Suriya")
        XCTAssertTrue(document.isYou("Suriya"))
        XCTAssertTrue(document.isYou("you"))
        XCTAssertFalse(document.isYou("Priya"))
        XCTAssertEqual(document.speakersWithYou, ["you", "Priya", "them 2"])
        XCTAssertEqual(document.sessions[0].turns.map(\.speaker), ["Suriya", "Priya", "them 2", "Priya"])
    }

    func testAFileFromBeforeNamesStillReads() throws {
        let old = """
        ---
        app: zoom
        started: 2026-08-29T14:02:11+05:30
        ended: 2026-08-29T15:44:11+05:30
        duration_s: 6120
        engine: whisper-large-v3-turbo
        speakers: [you, them 1]
        words: 13
        complete: true
        gaps: []
        recovered: false
        ---

        [00:00:04] you: hi

        [00:00:09] them 1: yes
        """
        let url = parent.appendingPathComponent("old.md")
        try old.write(to: url, atomically: true, encoding: .utf8)
        let document = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(document.header.participants, [])
        XCTAssertEqual(document.header.voices, [])
        XCTAssertEqual(document.youLabel, "you")
        XCTAssertEqual(document.speakers, ["you", "them 1"])
        // the summary reads it too.
        XCTAssertEqual(try MeetingTranscriptFile.summary(of: url).app, "zoom")
    }

    func testAnOlderBuildReadsANamedFileForWhatItAlreadyKnew() throws {
        // the gap lines, the one place the old reader looked at `- ` lines,
        // are not confused by the voices.
        let url = try MeetingTranscriptFile.write(
            MeetingTranscript(
                app: "zoom", started: started(), duration: .seconds(600), engine: "w",
                gaps: [.init(began: .seconds(10), ended: .seconds(20))], recovered: false,
                youName: "Suriya", voices: ["them 1": "Priya"],
                turns: [.init(speaker: .them(1), at: .seconds(1), text: "hi")]),
            in: parent, timeZone: tz)
        let header = try MeetingTranscriptFile.header(of: url)
        XCTAssertEqual(header.gaps.count, 1)
        XCTAssertEqual(header.voices.count, 2)
        XCTAssertEqual(try MeetingTranscriptFile.summary(of: url).gapCount, 1)
    }

    // MARK: - recording into a file

    func testASessionAddedKeepsTheNamesAndAddsTheNewOnes() throws {
        let url = try MeetingTranscriptFile.write(
            transcript(youName: "Suriya", voices: ["them 1": "Priya"]), in: parent, timeZone: tz)
        try MeetingTranscriptFile.append(
            transcript(youName: "Someone Else", voices: ["them 2": "Rahul"], at: 86_400,
                       turns: [
                           .init(speaker: .you, at: .seconds(1), text: "morning"),
                           .init(speaker: .them(2), at: .seconds(5), text: "morning all"),
                       ]),
            to: url, timeZone: tz)
        let document = try MeetingTranscriptFile.document(at: url)
        // the file keeps calling you what it first did.
        XCTAssertEqual(document.sessions[1].turns.map(\.speaker), ["Suriya", "Rahul"])
        XCTAssertEqual(document.speakers, ["Suriya", "Priya", "them 2", "Rahul"])
        XCTAssertEqual(document.header.participants, ["Suriya", "Priya", "Rahul"])
        XCTAssertEqual(document.header.voices.map(\.label), ["you", "them 1", "them 2"])
        XCTAssertEqual(document.header.voices.map(\.name), ["Suriya", "Priya", "Rahul"])
    }

    func testAnAppendNamesAFileThatHadNoNames() throws {
        let url = try MeetingTranscriptFile.write(
            transcript(turns: [.init(speaker: .them(1), at: .seconds(1), text: "hi")]),
            in: parent, timeZone: tz)
        try MeetingTranscriptFile.append(
            transcript(voices: ["them 1": "Priya"], at: 3_600,
                       turns: [.init(speaker: .them(1), at: .seconds(1), text: "hello")]),
            to: url, timeZone: tz)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("participants: [Priya]"))
        XCTAssertTrue(text.contains("[00:00:01] them 1: hi"))
        XCTAssertTrue(text.contains("[00:00:01] Priya: hello"))
        // and the words key is where it always was.
        let document = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(document.header.words, 2)
    }

    func testAFileThatSaidYouKeepsSayingYou() throws {
        let url = try MeetingTranscriptFile.write(transcript(), in: parent, timeZone: tz)
        try MeetingTranscriptFile.append(
            transcript(youName: "Suriya", at: 3_600,
                       turns: [.init(speaker: .you, at: .seconds(1), text: "again")]),
            to: url, timeZone: tz)
        let document = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(document.sessions[1].turns.map(\.speaker), ["you"])
        XCTAssertEqual(document.header.voices, [])
    }

    // MARK: - naming by hand

    private func named(_ text: String, _ shown: String, _ name: String?) throws -> String {
        try XCTUnwrap(MeetingTranscriptFile.renamingSpeaker(shown, to: name, in: text))
    }

    func testALabelBecomesANameEverywhere() throws {
        let text = MeetingTranscriptFile.markdown(transcript(youName: "Suriya"), timeZone: tz)
        let renamed = try named(text, "them 1", "Priya")
        XCTAssertTrue(renamed.contains("[00:00:09] Priya: yes. the deploy is blocked."))
        XCTAssertTrue(renamed.contains("[00:01:00] Priya: thanks 2 is the plan."))
        XCTAssertTrue(renamed.contains("[00:00:30] them 2: i can fix it."))
        XCTAssertEqual(front(renamed).filter { $0.hasPrefix("speakers") }, ["speakers: [Suriya, Priya, them 2]"])
        XCTAssertTrue(renamed.contains("participants: [Suriya, Priya]"))
        XCTAssertTrue(renamed.contains("voices:\n- you: Suriya\n- them 1: Priya\n"))
        // what is said is untouched, even when it looks like a label.
        XCTAssertTrue(renamed.contains("thanks 2 is the plan."))
    }

    func testRenamingAFileThatHadNoNamesAtAll() throws {
        let text = MeetingTranscriptFile.markdown(transcript(), timeZone: tz)
        let renamed = try named(text, "them 2", "Rahul")
        XCTAssertTrue(renamed.contains("speakers: [you, them 1, Rahul]\nparticipants: [Rahul]\nvoices:\n- them 2: Rahul\nwords: "))
        let document = try MeetingTranscriptFile.document(parsing: renamed, url: parent)
        XCTAssertEqual(document.header.words, 19)
    }

    func testANameCanBeChangedAndThenTakenBack() throws {
        let text = MeetingTranscriptFile.markdown(transcript(youName: "Suriya"), timeZone: tz)
        let priya = try named(text, "them 1", "Priya")
        let nair = try named(priya, "Priya", "Priya Nair")
        XCTAssertTrue(nair.contains("[00:00:09] Priya Nair: yes."))
        XCTAssertTrue(nair.contains("- them 1: Priya Nair\n"))
        XCTAssertFalse(nair.contains("- them 1: Priya\n"))

        let back = try named(nair, "Priya Nair", nil)
        XCTAssertEqual(back, text)
        XCTAssertEqual(try named(nair, "Priya Nair", "  "), text)
    }

    func testTakingAUnnamedSpeakerBackIsNothingToDo() throws {
        let text = MeetingTranscriptFile.markdown(transcript(), timeZone: tz)
        XCTAssertEqual(try named(text, "them 1", nil), text)
        XCTAssertEqual(try named(text, "them 1", ""), text)
    }

    func testYouAreNotNamedHereAndAnUnwritableNameIsRefused() throws {
        let text = MeetingTranscriptFile.markdown(transcript(youName: "Suriya"), timeZone: tz)
        XCTAssertEqual(try named(text, "Suriya", "Someone"), text)
        XCTAssertEqual(try named(text, "you", "Someone"), text)
        XCTAssertEqual(try named(text, "them 1", "them 2"), text)
        XCTAssertEqual(try named(text, "them 1", ":,"), text)
        let plain = MeetingTranscriptFile.markdown(transcript(), timeZone: tz)
        XCTAssertEqual(try named(plain, "you", "Someone"), plain)
    }

    func testNamingASpeakerTheSameAsAnotherMergesThem() throws {
        let text = MeetingTranscriptFile.markdown(transcript(voices: ["them 1": "Priya"]), timeZone: tz)
        let merged = try named(text, "them 2", "Priya")
        XCTAssertEqual(front(merged).filter { $0.hasPrefix("speakers") }, ["speakers: [you, Priya]"])
        XCTAssertTrue(merged.contains("participants: [Priya]"))
        XCTAssertTrue(merged.contains("- them 1: Priya\n- them 2: Priya\n"))
        // and renaming the merged person renames both voices.
        let again = try named(merged, "Priya", "Priya N")
        XCTAssertTrue(again.contains("- them 1: Priya N\n- them 2: Priya N\n"))
        XCTAssertFalse(again.contains("] Priya:"))
        // taking the name back puts back the first voice, and no one is lost.
        let undone = try named(again, "Priya N", nil)
        XCTAssertTrue(undone.contains("[00:00:09] them 1:"))
        XCTAssertTrue(undone.contains("[00:00:30] them 1:"))
        XCTAssertFalse(undone.contains("voices"))
    }

    func testEverySessionIsRenamed() throws {
        let url = try MeetingTranscriptFile.write(transcript(), in: parent, timeZone: tz)
        try MeetingTranscriptFile.append(
            transcript(at: 3_600, turns: [.init(speaker: .them(1), at: .seconds(1), text: "second")]),
            to: url, timeZone: tz)
        try MeetingTranscriptFile.renameSpeaker("them 1", to: "Priya", at: url)
        let document = try MeetingTranscriptFile.document(at: url)
        XCTAssertEqual(document.sessions.count, 2)
        XCTAssertEqual(document.sessions[0].turns.map(\.speaker), ["you", "Priya", "them 2", "Priya"])
        XCTAssertEqual(document.sessions[1].turns.map(\.speaker), ["Priya"])
        XCTAssertEqual(document.header.words, 20)
        XCTAssertEqual(document.sessions[1].started, started(3_600))
    }

    func testTheNotesCallThemByTheirNameToo() throws {
        let url = try MeetingTranscriptFile.write(transcript(), in: parent, timeZone: tz)
        try MeetingTranscriptFile.setSummary(
            "- them 1 will ship it\n- ask them 10 about it, and them 1.", template: nil, at: url)
        try MeetingTranscriptFile.renameSpeaker("them 1", to: "Priya", at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("- Priya will ship it"))
        XCTAssertTrue(text.contains("- ask them 10 about it, and Priya."))
        // and the other way leaves the notes to be written again.
        try MeetingTranscriptFile.renameSpeaker("Priya", to: nil, at: url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("- Priya will ship it"))
    }

    func testARenameOnDiskIsWholeAndNotWhenThereIsNothingToDo() throws {
        let url = try MeetingTranscriptFile.write(transcript(), in: parent, timeZone: tz)
        let before = try String(contentsOf: url, encoding: .utf8)
        try MeetingTranscriptFile.renameSpeaker("you", to: "Someone", at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)

        try MeetingTranscriptFile.renameSpeaker("them 2", to: "Rahul", at: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        XCTAssertThrowsError(try MeetingTranscriptFile.renameSpeaker(
            "them 1", to: "x", at: parent.appendingPathComponent("gone.md"))) {
            XCTAssertEqual($0 as? MeetingTranscriptFile.Failure, .gone(parent.appendingPathComponent("gone.md")))
        }
        let notes = parent.appendingPathComponent("notes.md")
        try "no front matter".write(to: notes, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MeetingTranscriptFile.renameSpeaker("them 1", to: "x", at: notes))
    }

    func testAPlainThemCanBeNamedToo() throws {
        let text = MeetingTranscriptFile.markdown(
            transcript(turns: [.init(speaker: .them(nil), at: .seconds(1), text: "hello")]), timeZone: tz)
        let renamed = try named(text, "them", "Priya")
        XCTAssertTrue(renamed.contains("[00:00:01] Priya: hello"))
        XCTAssertTrue(renamed.contains("- them: Priya"))
        XCTAssertEqual(try named(renamed, "Priya", nil), text)
    }

    func testANameTypedIntoTheFileByHandCanStillBeChanged() throws {
        let text = MeetingTranscriptFile.markdown(transcript(), timeZone: tz)
            .replacingOccurrences(of: "] them 1:", with: "] Pri:")
        let renamed = try named(text, "Pri", "Priya")
        XCTAssertTrue(renamed.contains("] Priya: yes."))
        // there is no label to take back to, so it cannot be.
        XCTAssertEqual(try named(renamed, "Priya", nil), renamed)
    }

    func testTheOriginsOfAShownSpeaker() {
        let voices = [SpeakerName(label: "them 1", name: "Priya"), SpeakerName(label: "them 3", name: "Priya")]
        XCTAssertEqual(MeetingTranscriptFile.origins(of: "Priya", in: voices), ["them 1", "them 3"])
        XCTAssertEqual(MeetingTranscriptFile.origins(of: "them 2", in: voices), ["them 2"])
        XCTAssertEqual(MeetingTranscriptFile.origins(of: "Pri", in: voices), [])
    }

    // MARK: - the colours

    func testYouKeepTheirColourWhateverTheFileCallsYou() throws {
        let url = try MeetingTranscriptFile.write(
            transcript(youName: "Suriya", voices: ["them 1": "Priya"]), in: parent, timeZone: tz)
        let document = try MeetingTranscriptFile.document(at: url)
        let turns = MeetingTranscriptBlocks.items(for: document).compactMap { item -> MeetingTranscriptBlocks.Turn? in
            if case let .turn(turn) = item.kind { return turn }
            return nil
        }
        XCTAssertEqual(turns.map(\.speaker), ["Suriya", "Priya", "them 2", "Priya"])
        XCTAssertEqual(turns.map(\.colour), [nil, 0, 1, 0])
    }
}
