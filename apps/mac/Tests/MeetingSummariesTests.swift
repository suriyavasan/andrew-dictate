import XCTest

/// the meetings, in memory: what `MeetingSummaries` reads and what it wrote.
final class MemoryMeetings: @unchecked Sendable {
    struct Write: Equatable {
        let notes: String
        let template: String
        let url: URL
    }

    private let lock = NSLock()
    private var documents: [URL: MeetingDocument] = [:]
    private var summaryWrites: [Write] = []
    private var titleWrites: [URL: String] = [:]
    var failReading = false
    var failWriting = false

    func put(_ document: MeetingDocument, at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        documents[url] = document
    }

    var summaries: [Write] {
        lock.lock()
        defer { lock.unlock() }
        return summaryWrites
    }

    func title(at url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return titleWrites[url]
    }

    var files: MeetingSummaries.Files {
        MeetingSummaries.Files(
            read: { [self] url in
                lock.lock()
                defer { lock.unlock() }
                guard !failReading, let document = documents[url] else {
                    throw MeetingTranscriptFile.Failure.gone(url)
                }
                return document
            },
            setSummary: { [self] notes, template, url in
                lock.lock()
                defer { lock.unlock() }
                if failWriting { throw MeetingTranscriptFile.Failure.gone(url) }
                summaryWrites.append(Write(notes: notes, template: template, url: url))
            },
            setTitle: { [self] title, url in
                lock.lock()
                defer { lock.unlock() }
                titleWrites[url] = title
            })
    }
}

/// holds a request until the test lets it go, and says when it got there.
actor RequestLatch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiting { waiter.resume() }
        waiting = []
    }
}

@MainActor
final class MeetingSummariesTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/meetings/2026-08/2026-08-29-1402-zoom.md")
    private let memory = MemoryMeetings()
    private var connects = 0
    private var enabled = true
    private var defaultTemplate = "auto"
    private var connection: Result<RewriteConnection, RewriteFailure> = .failure(.notSignedIn(.openAI))
    private var changed: [URL] = []

    private func make() -> MeetingSummaries {
        let summaries = MeetingSummaries(
            connect: { [unowned self] in
                connects += 1
                return connection
            },
            isEnabled: { [unowned self] in enabled },
            defaultTemplateID: { [unowned self] in defaultTemplate },
            files: memory.files,
            pause: { _ in })
        summaries.onChange = { [unowned self] in changed.append($0) }
        return summaries
    }

    private func answering(
        title: String = "Q3 Planning",
        notes: String = "## Meeting Summary\nthey met."
    ) -> ScriptedClient {
        ScriptedClient { prompt, _ in
            prompt.instructions.hasPrefix(MeetingSummaryPrompt.titleInstructions) ? title : notes
        }
    }

    private func connect(_ client: ScriptedClient, provider: RewriteProvider = .openAI) {
        connection = .success(RewriteConnection(client: client, model: "m", provider: provider))
    }

    // MARK: - when a meeting is saved

    func testASavedMeetingGetsNotesATemplateAndATitle() async throws {
        let client = answering(title: "\"Q3 Planning\"")
        connect(client)
        memory.put(MeetingFixtures.document(), at: url)
        let summaries = make()

        let task = try XCTUnwrap(summaries.meetingSaved(at: url))
        XCTAssertEqual(summaries.state(for: url), .summarizing)
        await task.value

        XCTAssertEqual(summaries.state(for: url), .idle)
        XCTAssertEqual(
            memory.summaries,
            [.init(notes: "## Meeting Summary\nthey met.", template: "auto", url: url)])
        XCTAssertEqual(memory.title(at: url), "Q3 Planning")
        XCTAssertEqual(changed, [url])
        XCTAssertEqual(client.calls.count, 2)
    }

    func testAMeetingThatHasATitleKeepsIt() async throws {
        let client = answering()
        connect(client)
        memory.put(MeetingFixtures.document(title: "stand-up"), at: url)
        let summaries = make()

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(client.calls.count, 1, "no request for a name it has")
        XCTAssertNil(memory.title(at: url))
        XCTAssertEqual(memory.summaries.count, 1)
    }

    func testTheDefaultTemplateIsUsedWhenTheFileNamesNone() async {
        let client = answering()
        connect(client)
        defaultTemplate = "weeklyTeam"
        memory.put(MeetingFixtures.document(title: "t"), at: url)
        let summaries = make()

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(memory.summaries.first?.template, "weeklyTeam")
        XCTAssertTrue(client.calls[0].prompt.instructions.hasSuffix(
            MeetingTemplate.weeklyTeam.instructions))
    }

    /// a stand-up recorded into again is still a stand-up.
    func testTheFilesOwnTemplateBeatsTheDefault() async {
        let client = answering()
        connect(client)
        defaultTemplate = "hiring"
        memory.put(MeetingFixtures.document(title: "t", template: "standUp"), at: url)
        let summaries = make()

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(memory.summaries.first?.template, "standUp")
    }

    func testAnIdNobodyKnowsFallsBackToAuto() async {
        let client = answering()
        connect(client)
        defaultTemplate = "removedLater"
        memory.put(MeetingFixtures.document(title: "t"), at: url)
        let summaries = make()

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(memory.summaries.first?.template, "auto")
    }

    func testWithSummariesOffASavedMeetingIsLeftAlone() {
        let client = answering()
        connect(client)
        enabled = false
        memory.put(MeetingFixtures.document(), at: url)
        let summaries = make()

        XCTAssertNil(summaries.meetingSaved(at: url))

        XCTAssertEqual(connects, 0)
        XCTAssertEqual(summaries.state(for: url), .idle)
        XCTAssertTrue(summaries.states.isEmpty)
        XCTAssertEqual(client.calls.count, 0)
    }

    func testAMeetingNobodySpokeInIsLeftAloneWhenTheAppAsked() async {
        let client = answering()
        connect(client)
        memory.put(MeetingFixtures.document(lines: []), at: url)
        let summaries = make()

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(summaries.state(for: url), .idle)
        XCTAssertEqual(connects, 0)
        XCTAssertEqual(client.calls.count, 0)
        XCTAssertEqual(memory.summaries, [])
        XCTAssertEqual(changed, [])
    }

    // MARK: - when you ask

    func testAskingWorksWithTheSwitchOffAndUsesTheTemplateYouPicked() async {
        let client = answering()
        connect(client)
        enabled = false
        memory.put(MeetingFixtures.document(title: "t", template: "standUp"), at: url)
        let summaries = make()

        await summaries.summarize(url, templateID: "hiring").value

        XCTAssertEqual(summaries.state(for: url), .idle)
        XCTAssertEqual(memory.summaries.first?.template, "hiring")
        XCTAssertTrue(client.calls[0].prompt.instructions.hasSuffix(
            MeetingTemplate.hiring.instructions))
        XCTAssertEqual(changed, [url])
    }

    func testAskingAboutAMeetingNobodySpokeInSaysSo() async {
        connect(answering())
        memory.put(MeetingFixtures.document(lines: []), at: url)
        let summaries = make()

        await summaries.summarize(url, templateID: "auto").value

        XCTAssertEqual(summaries.state(for: url), .failed("nobody spoke in this one"))
        XCTAssertEqual(memory.summaries, [])
    }

    func testAnUnreadableMeetingIsAFailureAndNothingIsWritten() async {
        connect(answering())
        let summaries = make()

        await summaries.summarize(url, templateID: "auto").value

        XCTAssertEqual(summaries.state(for: url), .failed("can't read the transcript"))
        XCTAssertEqual(connects, 0)
        XCTAssertEqual(memory.summaries, [])
    }

    // MARK: - when it fails

    func testNoProviderIsAFailureInThePillsWordsAndTheFileIsUntouched() async {
        connection = .failure(.notSignedIn(.openAI))
        memory.put(MeetingFixtures.document(), at: url)
        let summaries = make()

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(summaries.state(for: url), .failed("add an openai key"))
        XCTAssertEqual(memory.summaries, [])
        XCTAssertNil(memory.title(at: url))
        XCTAssertEqual(changed, [])
    }

    func testAProviderThatKeepsFailingIsAFailureAfterItsRetries() async {
        let client = ScriptedClient { _, _ in throw RewriteFailure.rateLimited(.openRouter) }
        connect(client, provider: .openRouter)
        memory.put(MeetingFixtures.document(), at: url)
        let summaries = make()

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(summaries.state(for: url), .failed("openrouter is rate limiting"))
        XCTAssertEqual(client.calls.count, 3)
        XCTAssertEqual(memory.summaries, [])
        XCTAssertEqual(changed, [])
    }

    func testAFailedMeetingCanBeTriedAgain() async {
        connection = .failure(.notSignedIn(.openAI))
        memory.put(MeetingFixtures.document(), at: url)
        let summaries = make()
        await summaries.meetingSaved(at: url)?.value
        XCTAssertEqual(summaries.state(for: url), .failed("add an openai key"))

        connect(answering())
        await summaries.summarize(url, templateID: "auto").value

        XCTAssertEqual(summaries.state(for: url), .idle)
        XCTAssertEqual(memory.summaries.count, 1)
    }

    func testANameThatCannotBeMadeDoesNotCostTheNotes() async {
        let client = ScriptedClient { prompt, _ in
            if prompt.instructions.hasPrefix(MeetingSummaryPrompt.titleInstructions) {
                throw RewriteFailure.rejectedCredentials(.openAI)
            }
            return "notes"
        }
        connect(client)
        memory.put(MeetingFixtures.document(), at: url)
        let summaries = make()

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(summaries.state(for: url), .idle)
        XCTAssertEqual(memory.summaries.first?.notes, "notes")
        XCTAssertNil(memory.title(at: url))
        XCTAssertEqual(changed, [url])
    }

    func testAFileThatCannotBeWrittenIsAFailure() async {
        connect(answering())
        memory.put(MeetingFixtures.document(), at: url)
        memory.failWriting = true
        let summaries = make()

        await summaries.meetingSaved(at: url)?.value

        XCTAssertEqual(summaries.state(for: url), .failed("can't save the summary"))
        XCTAssertEqual(changed, [])
    }

    // MARK: - one at a time

    func testASecondAskForTheSameMeetingReplacesTheFirst() async throws {
        let entered = RequestLatch()
        let release = RequestLatch()
        let client = ScriptedClient { _, call in
            if call == 1 {
                await entered.open()
                await release.wait()
                return "first"
            }
            return "second"
        }
        connect(client)
        memory.put(MeetingFixtures.document(title: "t"), at: url)
        let summaries = make()

        let first = summaries.summarize(url, templateID: "auto")
        await entered.wait()
        let second = summaries.summarize(url, templateID: "hiring")
        await second.value
        await release.open()
        await first.value

        XCTAssertEqual(summaries.state(for: url), .idle)
        XCTAssertEqual(
            memory.summaries, [.init(notes: "second", template: "hiring", url: url)])
        XCTAssertEqual(changed, [url])
    }

    func testTwoMeetingsAreSummarizedSideBySide() async throws {
        let other = URL(fileURLWithPath: "/meetings/2026-08/2026-08-29-1500-zoom.md")
        let client = answering()
        connect(client)
        memory.put(MeetingFixtures.document(title: "a"), at: url)
        memory.put(MeetingFixtures.document(title: "b"), at: other)
        let summaries = make()

        let one = summaries.summarize(url, templateID: "auto")
        let two = summaries.summarize(other, templateID: "auto")
        XCTAssertEqual(summaries.state(for: url), .summarizing)
        XCTAssertEqual(summaries.state(for: other), .summarizing)
        await one.value
        await two.value

        XCTAssertEqual(Set(memory.summaries.map(\.url)), [url, other])
        XCTAssertEqual(Set(changed), [url, other])
    }
}
