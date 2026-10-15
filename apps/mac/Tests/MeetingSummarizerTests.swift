import XCTest

/// a client that answers from a script and remembers what it was asked, so
/// the summarizer runs with no provider in the room.
final class ScriptedClient: RewriteClient, @unchecked Sendable {
    struct Call: Sendable {
        let prompt: RewritePrompt
        let model: String
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let answer: @Sendable (RewritePrompt, Int) async throws -> String

    init(_ answer: @escaping @Sendable (RewritePrompt, Int) async throws -> String) {
        self.answer = answer
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func complete(
        _ prompt: RewritePrompt,
        model: String,
        timeout: TimeInterval
    ) async throws -> String {
        let index = lock.withLock {
            recorded.append(Call(prompt: prompt, model: model, timeout: timeout))
            return recorded.count
        }
        return try await answer(prompt, index)
    }
}

/// the pauses a summarizer asked for, without waiting them out.
final class Pauses: @unchecked Sendable {
    private let lock = NSLock()
    private var waited: [Duration] = []

    var all: [Duration] {
        lock.withLock { waited }
    }

    var pause: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            lock.withLock { waited.append(duration) }
        }
    }
}

enum MeetingFixtures {
    static let started = Date(timeIntervalSince1970: 1_787_000_000)
    static let tz = TimeZone(identifier: "Asia/Kolkata")!

    static func document(
        title: String? = nil,
        template: String? = nil,
        lines: [(Int, String, String)] = [(4, "you", "hi, can you hear me?"), (9, "them", "yes. ship it friday.")]
    ) -> MeetingDocument {
        MeetingDocument(
            header: .init(
                app: "zoom", started: started, timeZone: tz, duration: .seconds(600),
                gaps: [], recovered: false, complete: true,
                words: lines.reduce(0) { $0 + $1.2.split(separator: " ").count },
                title: title, template: template, sessions: 1, engine: "whisper"),
            summary: nil,
            sessions: [.init(
                started: started,
                turns: lines.map { .init(at: .seconds($0.0), speaker: $0.1, text: $0.2) })])
    }

    /// enough paragraphs to pass `chars`, each a few hundred characters.
    static func longDocument(chars: Int) -> MeetingDocument {
        var lines: [(Int, String, String)] = []
        var total = 0
        var n = 0
        while total < chars {
            let text = "line \(n) " + String(repeating: "talk ", count: 60)
            lines.append((n * 20, n.isMultiple(of: 2) ? "you" : "them", text))
            total += text.count + 30
            n += 1
        }
        return document(lines: lines)
    }
}

final class MeetingSummarizerTests: XCTestCase {
    private func summarizer(
        _ client: ScriptedClient,
        provider: RewriteProvider = .openAI,
        pauses: Pauses = Pauses()
    ) -> MeetingSummarizer {
        MeetingSummarizer(
            client: client, model: "m", provider: provider, pause: pauses.pause)
    }

    // MARK: - one request

    func testAShortMeetingIsOneRequestWithTheTemplateAndTheSummaryTimeout() async throws {
        let client = ScriptedClient { _, _ in "## Meeting Summary\nthey met." }
        let document = MeetingFixtures.document(title: "stand-up")

        let notes = try await summarizer(client).summary(
            of: document, template: .standUp, previous: nil)

        XCTAssertEqual(notes, "## Meeting Summary\nthey met.")
        let call = try XCTUnwrap(client.calls.first)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(call.model, "m")
        XCTAssertEqual(call.timeout, RewriteHTTP.summaryTimeout)
        XCTAssertEqual(call.timeout, 180)
        XCTAssertTrue(call.prompt.instructions.hasSuffix(MeetingTemplate.standUp.instructions))
        XCTAssertTrue(call.prompt.text.hasPrefix("Meeting title: stand-up\n\n"))
        XCTAssertTrue(call.prompt.text.contains(
            "<transcript>\n[00:00:04] you: hi, can you hear me?\n\n[00:00:09] them: yes. ship it friday.\n</transcript>"))
    }

    func testThePreviousNotesAreHandedOverWhenThereAreSome() async throws {
        let client = ScriptedClient { _, _ in "notes" }

        _ = try await summarizer(client).summary(
            of: MeetingFixtures.document(), template: .auto, previous: "old notes")

        let call = try XCTUnwrap(client.calls.first)
        XCTAssertTrue(call.prompt.instructions.contains(MeetingSummaryPrompt.preserveNotes))
        XCTAssertTrue(call.prompt.text.contains(
            "Current generated notes to preserve and reformat:\nold notes"))
    }

    func testTheAnswerHasItsFenceTakenOff() async throws {
        let client = ScriptedClient { _, _ in "```markdown\n## Notes\n- a\n```" }

        let notes = try await summarizer(client).summary(
            of: MeetingFixtures.document(), template: .auto, previous: nil)

        XCTAssertEqual(notes, "## Notes\n- a")
    }

    func testAnEmptyAnswerIsAFailureAndIsNotAskedAgain() async {
        let client = ScriptedClient { _, _ in "  \n " }
        let pauses = Pauses()

        do {
            _ = try await summarizer(client, pauses: pauses).summary(
                of: MeetingFixtures.document(), template: .auto, previous: nil)
            XCTFail("an empty answer is not notes")
        } catch {
            XCTAssertEqual(error as? RewriteFailure, .emptyAnswer)
        }
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(pauses.all, [])
    }

    // MARK: - too long to read whole

    func testALongMeetingIsReadInPartsAndTheTemplateFilledFromTheirNotes() async throws {
        let document = MeetingFixtures.longDocument(chars: 15_000)
        let client = ScriptedClient { prompt, _ in
            prompt.instructions.hasPrefix(MeetingSummaryPrompt.notesInstructions)
                ? "- a point" : "## Meeting Summary\nfinal"
        }

        let notes = try await summarizer(client, provider: .apple).summary(
            of: document, template: .hiring, previous: nil)

        XCTAssertEqual(notes, "## Meeting Summary\nfinal")
        let parts = MeetingSummarizer.chunks(
            of: document.transcriptText, limit: MeetingSummarizer.limit(for: .apple))
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(client.calls.count, parts.count + 1)

        let partCalls = client.calls.dropLast()
        for (index, call) in partCalls.enumerated() {
            XCTAssertTrue(call.prompt.text.hasPrefix("Part \(index + 1) of \(parts.count)."))
            XCTAssertTrue(call.prompt.text.contains("<transcript>\n"))
            XCTAssertEqual(call.timeout, RewriteHTTP.summaryTimeout)
        }
        let last = try XCTUnwrap(client.calls.last)
        XCTAssertTrue(last.prompt.instructions.hasSuffix(MeetingTemplate.hiring.instructions))
        XCTAssertTrue(last.prompt.text.contains(
            "<transcript>\n" + Array(repeating: "- a point", count: parts.count)
                .joined(separator: "\n\n") + "\n</transcript>"))
        XCTAssertFalse(last.prompt.text.contains("line 0 "), "the words themselves are not sent again")
        XCTAssertTrue(last.prompt.text.contains("too long to read whole"))
    }

    func testAMeetingUnderTheLimitIsNeverCut() async throws {
        let client = ScriptedClient { _, _ in "notes" }

        _ = try await summarizer(client, provider: .apple).summary(
            of: MeetingFixtures.longDocument(chars: 4_000), template: .auto, previous: nil)

        XCTAssertEqual(client.calls.count, 1)
    }

    func testOtherProvidersTakeALongMeetingWhole() async throws {
        let client = ScriptedClient { _, _ in "notes" }

        _ = try await summarizer(client, provider: .gemini).summary(
            of: MeetingFixtures.longDocument(chars: 60_000), template: .auto, previous: nil)

        XCTAssertEqual(client.calls.count, 1)
    }

    /// notes that are not shorter than what they came from would go round
    /// forever: one round, then the template.
    func testNotesThatDoNotGetShorterAreNotBoiledDownAgain() async throws {
        let client = ScriptedClient { prompt, _ in
            prompt.instructions.hasPrefix(MeetingSummaryPrompt.notesInstructions)
                ? String(repeating: "x", count: 5_900) : "final"
        }
        let document = MeetingFixtures.longDocument(chars: 15_000)
        let parts = MeetingSummarizer.chunks(
            of: document.transcriptText, limit: 6_000).count

        let notes = try await summarizer(client, provider: .apple).summary(
            of: document, template: .auto, previous: nil)

        XCTAssertEqual(notes, "final")
        XCTAssertEqual(client.calls.count, parts + 1)
    }

    func testNotesThatAreStillTooLongAreBoiledDownAgain() async throws {
        let client = ScriptedClient { prompt, _ in
            prompt.instructions.hasPrefix(MeetingSummaryPrompt.notesInstructions)
                ? String(repeating: "y", count: 1_500) : "final"
        }
        let document = MeetingFixtures.longDocument(chars: 30_000)
        let first = MeetingSummarizer.chunks(of: document.transcriptText, limit: 6_000).count

        _ = try await summarizer(client, provider: .apple).summary(
            of: document, template: .auto, previous: nil)

        // first round: `first` notes of 1_500 characters, which together are
        // over 6_000, so a second round runs on them.
        XCTAssertGreaterThan(first * 1_500, 6_000)
        XCTAssertGreaterThan(client.calls.count, first + 1)
    }

    func testChunksSplitBetweenParagraphsAndLoseNothing() {
        let paragraphs = (0..<10).map { "paragraph \($0) " + String(repeating: "w", count: 90) }
        let text = paragraphs.joined(separator: "\n\n")

        let parts = MeetingSummarizer.chunks(of: text, limit: 300)

        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 300 })
        XCTAssertTrue(parts.allSatisfy { $0.hasPrefix("paragraph ") })
        XCTAssertEqual(parts.joined(separator: "\n\n"), text)
    }

    func testAParagraphLongerThanTheLimitIsCutAtASpace() {
        let text = Array(repeating: "alpha", count: 100).joined(separator: " ")

        let parts = MeetingSummarizer.chunks(of: text, limit: 120)

        XCTAssertTrue(parts.allSatisfy { $0.count <= 120 })
        XCTAssertTrue(parts.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
        XCTAssertEqual(parts.joined(separator: " "), text)
    }

    func testAParagraphWithNoSpaceIsCutAnywhere() {
        let parts = MeetingSummarizer.chunks(of: String(repeating: "z", count: 250), limit: 100)

        XCTAssertEqual(parts.map(\.count), [100, 100, 50])
    }

    func testTheLimitsAreTheProvidersOwn() {
        XCTAssertEqual(MeetingSummarizer.limit(for: .apple), 6_000)
        for provider in RewriteProvider.allCases where provider != .apple {
            XCTAssertEqual(MeetingSummarizer.limit(for: provider), 300_000)
        }
    }

    // MARK: - asking again

    func testAFailureTheNetworkCausedIsRetriedAfterOneSecondThenThree() async throws {
        let client = ScriptedClient { _, call in
            switch call {
            case 1: throw RewriteFailure.timedOut
            case 2: throw RewriteFailure.network
            default: return "notes"
            }
        }
        let pauses = Pauses()

        let notes = try await summarizer(client, pauses: pauses).summary(
            of: MeetingFixtures.document(), template: .auto, previous: nil)

        XCTAssertEqual(notes, "notes")
        XCTAssertEqual(client.calls.count, 3)
        XCTAssertEqual(pauses.all, [.seconds(1), .seconds(3)])
    }

    func testTwoRetriesAreAllThereAre() async {
        let client = ScriptedClient { _, _ in throw RewriteFailure.rateLimited(.openAI) }
        let pauses = Pauses()

        do {
            _ = try await summarizer(client, pauses: pauses).summary(
                of: MeetingFixtures.document(), template: .auto, previous: nil)
            XCTFail("it never answered")
        } catch {
            XCTAssertEqual(error as? RewriteFailure, .rateLimited(.openAI))
        }
        XCTAssertEqual(client.calls.count, 3)
        XCTAssertEqual(pauses.all, [.seconds(1), .seconds(3)])
    }

    func testEveryFailureThatIsWorthRetryingIsAndNoneThatIsNot() {
        let worth: [RewriteFailure] = [
            .timedOut, .network, .unavailable("openai is having trouble"), .rateLimited(.gemini),
        ]
        let not: [RewriteFailure] = [
            .notSignedIn(.openAI), .rejectedCredentials(.chatGPT), .planLimitReached,
            .outOfCredits(.openRouter), .notAllowed(.openAI), .modelUnavailable(.gemini),
            .emptyAnswer,
        ]
        for failure in worth { XCTAssertTrue(MeetingSummarizer.isWorthRetrying(failure), "\(failure)") }
        for failure in not { XCTAssertFalse(MeetingSummarizer.isWorthRetrying(failure), "\(failure)") }
    }

    func testAKeyThatIsRefusedIsNotAskedAgain() async {
        let client = ScriptedClient { _, _ in throw RewriteFailure.rejectedCredentials(.openAI) }
        let pauses = Pauses()

        do {
            _ = try await summarizer(client, pauses: pauses).summary(
                of: MeetingFixtures.document(), template: .auto, previous: nil)
            XCTFail("a refused key does not summarize")
        } catch {
            XCTAssertEqual(error as? RewriteFailure, .rejectedCredentials(.openAI))
        }
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(pauses.all, [])
    }

    func testAPartOfALongMeetingIsRetriedOnItsOwn() async throws {
        let client = ScriptedClient { prompt, call in
            if call == 1 { throw RewriteFailure.timedOut }
            return prompt.instructions.hasPrefix(MeetingSummaryPrompt.notesInstructions)
                ? "- p" : "final"
        }
        let document = MeetingFixtures.longDocument(chars: 15_000)
        let parts = MeetingSummarizer.chunks(of: document.transcriptText, limit: 6_000).count

        let notes = try await summarizer(client, provider: .apple).summary(
            of: document, template: .auto, previous: nil)

        XCTAssertEqual(notes, "final")
        XCTAssertEqual(client.calls.count, parts + 2)
    }

    func testCancellingStopsTheRetries() async {
        let client = ScriptedClient { _, _ in throw RewriteFailure.network }
        let sleeper = MeetingSummarizer(
            client: client, model: "m", provider: .openAI,
            pause: { _ in throw CancellationError() })

        do {
            _ = try await sleeper.summary(
                of: MeetingFixtures.document(), template: .auto, previous: nil)
            XCTFail("it was cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(client.calls.count, 1)
    }

    // MARK: - the title

    func testTheTitleIsAskedFromTheOpeningTheMiddleAndTheEnd() async throws {
        let client = ScriptedClient { _, _ in "Q3 Sprint Planning" }

        let title = try await summarizer(client).title(
            of: MeetingFixtures.longDocument(chars: 20_000))

        XCTAssertEqual(title, "Q3 Sprint Planning")
        let call = try XCTUnwrap(client.calls.first)
        XCTAssertEqual(call.timeout, RewriteHTTP.summaryTimeout)
        XCTAssertTrue(call.prompt.instructions.hasPrefix(MeetingSummaryPrompt.titleInstructions))
        XCTAssertTrue(call.prompt.text.contains("Opening:\n"))
        XCTAssertTrue(call.prompt.text.contains("Middle:\n"))
        XCTAssertTrue(call.prompt.text.contains("Closing:\n"))
        XCTAssertLessThan(call.prompt.text.count, 3_000)
    }

    func testTitlesAreCleanedToOneShortLine() {
        XCTAssertEqual(MeetingSummarizer.tidy(title: "\"Q3 Planning\""), "Q3 Planning")
        XCTAssertEqual(MeetingSummarizer.tidy(title: "“Q3 Planning”\n\nThis title captures…"), "Q3 Planning")
        XCTAssertEqual(MeetingSummarizer.tidy(title: "Title: Q3 Planning"), "Q3 Planning")
        XCTAssertEqual(MeetingSummarizer.tidy(title: "# Q3 Planning"), "Q3 Planning")
        XCTAssertEqual(MeetingSummarizer.tidy(title: "\n\n  Q3 Planning  \n"), "Q3 Planning")
        XCTAssertNil(MeetingSummarizer.tidy(title: " \n "))
        XCTAssertNil(MeetingSummarizer.tidy(title: "\"\""))
    }

    func testALongTitleIsCutAtAWordUnderSixtyCharacters() {
        let long = Array(repeating: "planning", count: 12).joined(separator: " ")

        let title = MeetingSummarizer.tidy(title: long)

        XCTAssertLessThanOrEqual(try XCTUnwrap(title).count, 60)
        XCTAssertTrue(try XCTUnwrap(title).hasSuffix("planning"))
        XCTAssertEqual(MeetingSummarizer.tidy(title: String(repeating: "x", count: 100))?.count, 60)
    }

    func testATitleThatComesBackEmptyIsAFailure() async {
        let client = ScriptedClient { _, _ in "\"\"" }

        do {
            _ = try await summarizer(client).title(of: MeetingFixtures.document())
            XCTFail("no title")
        } catch {
            XCTAssertEqual(error as? RewriteFailure, .emptyAnswer)
        }
    }
}
