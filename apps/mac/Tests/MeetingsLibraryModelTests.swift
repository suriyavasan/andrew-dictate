import XCTest

/// the meetings window's list: found, searched, grouped, renamed and
/// deleted, on real files in a temp folder. the model has no views, so
/// everything the window lists is argued with here.
@MainActor
final class MeetingsLibraryModelTests: XCTestCase {
    private var parent: URL!
    private var trashed: [URL] = []
    private let tz = TimeZone(identifier: "Asia/Kolkata")!
    /// thursday 16 oct 2026, 11:00 in kolkata.
    private var now: Date { date(2026, 10, 16, 11, 0) }

    override func setUp() async throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetings-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        trashed = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - loading

    func testTheListIsNewestFirstWithTitlesFromTheFiles() async throws {
        try write(app: "zoom", title: "stand-up", at: date(2026, 10, 16, 9, 30))
        try write(app: "meet", at: date(2026, 10, 15, 16, 0))
        let model = makeModel()

        await model.reload()

        XCTAssertEqual(model.entries.map(\.title), ["stand-up", "meet call"])
        XCTAssertEqual(model.entries[0].speakers, ["you", "them 1"])
        XCTAssertFalse(model.entries[0].snippet.isEmpty)
        XCTAssertTrue(model.hasLoaded)
    }

    func testBeforeTheFirstReadTheListIsNotYetEmptyFolder() {
        XCTAssertFalse(makeModel().hasLoaded)
    }

    /// a file nobody changed is not read twice: a reload on every window
    /// focus must be cheap.
    func testADocumentIsReadAgainOnlyWhenItsFileChanged() async throws {
        let url = try write(app: "zoom", at: date(2026, 10, 16, 9, 30))
        let reads = Counter()
        let model = makeModel(files: .init(
            read: { reads.bump(); return try MeetingTranscriptFile.document(at: $0) },
            stamp: MeetingsLibraryModel.Files.onDisk.stamp,
            setTitle: MeetingsLibraryModel.Files.onDisk.setTitle))

        await model.reload()
        await model.reload()
        XCTAssertEqual(reads.value, 1)

        try MeetingTranscriptFile.setTitle("renamed elsewhere", at: url)
        await model.reload()
        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(model.entries.first?.title, "renamed elsewhere")
    }

    func testAFileThatWentAwayLeavesTheList() async throws {
        let url = try write(app: "zoom", at: date(2026, 10, 16, 9, 30))
        let model = makeModel()
        await model.reload()
        try FileManager.default.removeItem(at: url)

        await model.reload()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.document(for: url))
    }

    // MARK: - groups

    func testMeetingsAreGroupedByWhenTheyHappened() async throws {
        try write(app: "a", at: date(2026, 10, 16, 9, 30))  // today
        try write(app: "b", at: date(2026, 10, 15, 22, 0))  // yesterday
        try write(app: "c", at: date(2026, 10, 12, 10, 0))  // monday: this week
        try write(app: "d", at: date(2026, 10, 9, 10, 0))   // last friday
        try write(app: "e", at: date(2026, 9, 1, 10, 0))
        let model = makeModel()

        await model.reload()

        XCTAssertEqual(
            model.sections.map(\.group),
            [.today, .yesterday, .thisWeek, .earlier])
        XCTAssertEqual(model.sections.map { $0.items.count }, [1, 1, 1, 2])
        XCTAssertEqual(model.sections.map(\.group.title),
                       ["today", "yesterday", "this week", "earlier"])
    }

    func testAGroupWithNothingInItIsLeftOut() async throws {
        try write(app: "a", at: date(2026, 10, 16, 9, 30))
        let model = makeModel()

        await model.reload()

        XCTAssertEqual(model.sections.map(\.group), [.today])
    }

    func testAMeetingFromTheFutureIsToday() {
        XCTAssertEqual(
            MeetingsLibraryModel.Group.of(
                now.addingTimeInterval(86_400 * 3), now: now, calendar: calendar),
            .today)
    }

    func testLateYesterdayIsYesterdayEvenWithinTwentyFourHours() {
        XCTAssertEqual(
            MeetingsLibraryModel.Group.of(
                date(2026, 10, 15, 23, 30), now: now, calendar: calendar),
            .yesterday)
    }

    // MARK: - search

    func testTheSearchLooksInTheTitleTheNotesAndTheWords() async throws {
        try write(app: "zoom", title: "quarterly planning", at: date(2026, 10, 16, 9, 0))
        let notes = try write(app: "meet", at: date(2026, 10, 16, 8, 0))
        try MeetingTranscriptFile.setSummary(
            "## Summary\nthe migration slips a week.", template: "auto", at: notes)
        try write(app: "teams", saying: "did the invoice land?", at: date(2026, 10, 16, 7, 0))
        let model = makeModel()
        await model.reload()

        model.query = "PLANNING"
        XCTAssertEqual(model.visible.map(\.title), ["quarterly planning"])
        model.query = "migration"
        XCTAssertEqual(model.visible.map(\.title), ["meet call"])
        model.query = "invoice"
        XCTAssertEqual(model.visible.map(\.title), ["teams call"])
        model.query = "nothing like this"
        XCTAssertTrue(model.visible.isEmpty)
        XCTAssertTrue(model.isSearching)
        model.query = "   "
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visible.count, 3)
    }

    func testASearchIgnoresCaseAndAccents() async throws {
        try write(app: "zoom", title: "café review", at: date(2026, 10, 16, 9, 0))
        let model = makeModel()
        await model.reload()

        model.query = "CAFE"

        XCTAssertEqual(model.visible.count, 1)
    }

    func testABodyHitShowsTheWordsAroundIt() async throws {
        try write(
            app: "zoom",
            saying: "we looked at the numbers and the invoice never landed in april",
            at: date(2026, 10, 16, 9, 0))
        let model = makeModel()
        await model.reload()

        model.query = "invoice"

        let hit = try XCTUnwrap(model.sections.first?.items.first?.hit)
        XCTAssertTrue(hit.contains("invoice never landed"))
        XCTAssertTrue(hit.hasPrefix("…"))
    }

    func testATitleHitNeedsNoExcerpt() async throws {
        try write(app: "zoom", title: "invoice review", at: date(2026, 10, 16, 9, 0))
        let model = makeModel()
        await model.reload()

        model.query = "invoice"

        XCTAssertNil(model.sections.first?.items.first?.hit)
    }

    func testTheExcerptIsOneLineWithEllipsesOnlyWhereTextWasCut() {
        let whole = MeetingsLibraryModel.excerpt(of: "short\nwords here", for: "words")
        XCTAssertEqual(whole, "short words here")
        let long = String(repeating: "a ", count: 60) + "needle" + String(repeating: " b", count: 60)
        let cut = MeetingsLibraryModel.excerpt(of: long, for: "needle")
        XCTAssertTrue(cut?.hasPrefix("…") == true && cut?.hasSuffix("…") == true)
        XCTAssertNil(MeetingsLibraryModel.excerpt(of: "nothing", for: "needle"))
    }

    // MARK: - rename

    func testRenamingWritesTheTitleAndTheListShowsIt() async throws {
        let url = try write(app: "zoom", at: date(2026, 10, 16, 9, 0))
        let model = makeModel()
        await model.reload()
        var told: [URL] = []
        model.onChange = { told.append($0) }

        let ok = await model.rename(url, to: "  weekly\nsync  ")

        XCTAssertTrue(ok)
        XCTAssertEqual(try MeetingTranscriptFile.document(at: url).header.title, "weekly sync")
        XCTAssertEqual(model.entries.first?.title, "weekly sync")
        XCTAssertEqual(told, [url])
    }

    func testABlankNameGoesBackToTheCallApp() async throws {
        let url = try write(app: "zoom", title: "old name", at: date(2026, 10, 16, 9, 0))
        let model = makeModel()
        await model.reload()

        await model.rename(url, to: "   ")

        XCTAssertNil(try MeetingTranscriptFile.document(at: url).header.title)
        XCTAssertEqual(model.entries.first?.title, "zoom call")
    }

    func testARenameOfAFileThatIsGoneSaysSo() async throws {
        let url = try write(app: "zoom", at: date(2026, 10, 16, 9, 0))
        let model = makeModel()
        await model.reload()
        try FileManager.default.removeItem(at: url)

        let ok = await model.rename(url, to: "x")

        XCTAssertFalse(ok)
        XCTAssertNotNil(model.failure)
    }

    // MARK: - delete

    func testDeletingTrashesTheFileAndSelectsTheNextOne() async throws {
        let first = try write(app: "a", at: date(2026, 10, 16, 9, 0))
        let second = try write(app: "b", at: date(2026, 10, 16, 8, 0))
        let model = makeModel()
        await model.reload()
        model.selection = .meeting(first)
        var told: [URL] = []
        model.onChange = { told.append($0) }

        XCTAssertTrue(model.remove(first))

        XCTAssertEqual(trashed, [first])
        XCTAssertEqual(model.entries.map(\.id), [second])
        XCTAssertEqual(model.selection, .meeting(second))
        XCTAssertEqual(told, [first])
    }

    func testDeletingTheLastOneSelectsTheOneAbove() async throws {
        let first = try write(app: "a", at: date(2026, 10, 16, 9, 0))
        let second = try write(app: "b", at: date(2026, 10, 16, 8, 0))
        let model = makeModel()
        await model.reload()
        model.selection = .meeting(second)

        model.remove(second)

        XCTAssertEqual(model.selection, .meeting(first))
    }

    func testDeletingAnotherMeetingKeepsTheSelection() async throws {
        let first = try write(app: "a", at: date(2026, 10, 16, 9, 0))
        let second = try write(app: "b", at: date(2026, 10, 16, 8, 0))
        let model = makeModel()
        await model.reload()
        model.selection = .meeting(first)

        model.remove(second)

        XCTAssertEqual(model.selection, .meeting(first))
    }

    /// a delete that did not happen must not look like one that did.
    func testADeleteThatFailedKeepsTheRowAndSaysSo() async throws {
        let url = try write(app: "a", at: date(2026, 10, 16, 9, 0))
        let model = makeModel(failDelete: true)
        await model.reload()
        model.selection = .meeting(url)

        XCTAssertFalse(model.remove(url))

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.selection, .meeting(url))
        XCTAssertNotNil(model.failure)
        model.dismissFailure()
        XCTAssertNil(model.failure)
    }

    // MARK: - the arrow keys

    func testTheArrowsStepAndStopAtTheEnds() {
        let a = URL(fileURLWithPath: "/a.md"), b = URL(fileURLWithPath: "/b.md")
        let order: [MeetingsLibraryModel.Selection] = [.recording, .meeting(a), .meeting(b)]

        XCTAssertEqual(MeetingsLibraryModel.stepped(nil, by: 1, in: order), .recording)
        XCTAssertEqual(MeetingsLibraryModel.stepped(nil, by: -1, in: order), .meeting(b))
        XCTAssertEqual(MeetingsLibraryModel.stepped(.recording, by: 1, in: order), .meeting(a))
        XCTAssertEqual(MeetingsLibraryModel.stepped(.meeting(b), by: 1, in: order), .meeting(b))
        XCTAssertEqual(MeetingsLibraryModel.stepped(.recording, by: -1, in: order), .recording)
        XCTAssertNil(MeetingsLibraryModel.stepped(nil, by: 1, in: []))
    }

    // MARK: - copying

    func testWhatTheCopyButtonsPut() async throws {
        let url = try write(app: "zoom", title: "stand-up", at: date(2026, 10, 16, 9, 0))
        try MeetingTranscriptFile.setSummary("## Notes\n- a point", template: "auto", at: url)
        let document = try MeetingTranscriptFile.document(at: url)

        XCTAssertEqual(MeetingsLibraryModel.text(.summary, of: document), "## Notes\n- a point")
        XCTAssertEqual(MeetingsLibraryModel.text(.transcript, of: document), document.transcriptText)
        XCTAssertEqual(
            MeetingsLibraryModel.text(.both, of: document),
            "# stand-up\n\n## summary\n## Notes\n- a point\n\n## transcript\n\(document.transcriptText)")
    }

    func testCopyingBothWithoutNotesIsTheTranscriptUnderItsTitle() async throws {
        let url = try write(app: "zoom", at: date(2026, 10, 16, 9, 0))
        let document = try MeetingTranscriptFile.document(at: url)

        XCTAssertEqual(
            MeetingsLibraryModel.text(.both, of: document),
            "# zoom call\n\n## transcript\n\(document.transcriptText)")
    }

    // MARK: - helpers

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var components = DateComponents()
        components.year = y; components.month = mo; components.day = d
        components.hour = h; components.minute = mi
        components.timeZone = tz
        return calendar.date(from: components)!
    }

    private func makeModel(
        files: MeetingsLibraryModel.Files = .onDisk,
        failDelete: Bool = false
    ) -> MeetingsLibraryModel {
        let parent = parent!
        return MeetingsLibraryModel(
            load: { MeetingTranscriptFile.listAll(in: parent) },
            files: files,
            delete: { [self] url in
                if failDelete { throw MeetingTranscriptFile.Failure.gone(url) }
                trashed.append(url)
                try FileManager.default.removeItem(at: url)
            },
            now: { [now] in now },
            calendar: calendar)
    }

    @discardableResult
    private func write(
        app: String, title: String? = nil, saying: String = "hi, can you hear me?", at started: Date
    ) throws -> URL {
        try MeetingTranscriptFile.write(
            MeetingTranscript(
                app: app, started: started, duration: .seconds(600),
                engine: "whisper-a", gaps: [], recovered: false, title: title,
                turns: [
                    .init(speaker: .you, at: .seconds(4), text: saying),
                    .init(speaker: .them(1), at: .seconds(9), text: "yes."),
                ]),
            in: parent, timeZone: tz)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
