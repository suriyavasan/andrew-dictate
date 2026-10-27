import Foundation

/// a meeting's notes and its name, asked of the provider settings chose. the
/// prompts are `MeetingSummaryPrompt`'s; this is the part that decides how
/// many requests it takes and what to do when one fails. the client, the
/// model and the pause between tries are handed in, so a test runs it with
/// none of the three real.
///
/// nothing here keeps or logs a word of the meeting: it goes to the client
/// and what comes back goes to the caller.
struct MeetingSummarizer: Sendable {
    let client: any RewriteClient
    let model: String
    let provider: RewriteProvider
    /// seconds a request may go without a byte.
    var timeout: TimeInterval = RewriteHTTP.summaryTimeout
    /// the wait between tries; tests hand back one that does not.
    var pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    init(
        client: any RewriteClient,
        model: String,
        provider: RewriteProvider,
        timeout: TimeInterval = RewriteHTTP.summaryTimeout,
        pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.model = model
        self.provider = provider
        self.timeout = timeout
        self.pause = pause
    }

    init(connection: RewriteConnection) {
        self.init(
            client: connection.client, model: connection.model,
            provider: connection.provider)
    }

    // MARK: - the notes

    /// the notes for the whole meeting in `template`. `previous` is a
    /// summary to carry details over from, when there is one worth it.
    func summary(
        of document: MeetingDocument,
        template: MeetingTemplate,
        previous: String? = nil
    ) async throws -> String {
        var transcript = document.transcriptText
        var condensed = false
        let limit = Self.limit(for: provider)

        // a transcript past what the model takes in one go is read a part at
        // a time, and the notes of the parts are what the template is
        // filled from. notes of a long meeting can still be too long, so
        // this goes round again on them — a few times at most, and not at
        // all once a round has stopped making them shorter.
        for _ in 0..<Self.rounds where transcript.count > limit {
            let parts = Self.chunks(of: transcript, limit: limit)
            var notes: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                notes.append(try await ask(
                    MeetingSummaryPrompt.notesPrompt(
                        part: index + 1, of: parts.count, text: part)))
            }
            let joined = notes.joined(separator: "\n\n")
            condensed = true
            let shrank = joined.count < transcript.count
            transcript = joined
            if !shrank { break }
        }

        return try await ask(MeetingSummaryPrompt.prompt(
            title: document.displayTitle,
            transcript: transcript,
            template: template,
            previousSummary: previous,
            condensed: condensed))
    }

    // MARK: - the name

    /// three to seven words, on one line, at most 60 characters.
    func title(of document: MeetingDocument) async throws -> String {
        let answer = try await ask(
            MeetingSummaryPrompt.titlePrompt(transcript: document.transcriptText))
        guard let title = Self.tidy(title: answer) else {
            throw RewriteFailure.emptyAnswer
        }
        return title
    }

    /// models add what they were asked not to: a quote mark, `Title:`, a
    /// second line of explanation. the first line is the title.
    static func tidy(title answer: String) -> String? {
        let cleaned = RewriteInstructions.cleanAnswer(answer)
        guard var line = cleaned.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        line = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        if line.lowercased().hasPrefix("title:") {
            line = String(line.dropFirst("title:".count))
                .trimmingCharacters(in: .whitespaces)
        }
        line = line.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"“”").union(.whitespaces))
        guard line.count > titleLimit else { return line.isEmpty ? nil : line }
        // cut at a word when there is one near the end, so it does not stop
        // mid-word.
        let cut = String(line.prefix(titleLimit))
        if let space = cut.lastIndex(of: " "),
           cut.distance(from: cut.startIndex, to: space) >= titleLimit - 20 {
            return String(cut[..<space]).trimmingCharacters(in: .whitespaces)
        }
        return cut.trimmingCharacters(in: .whitespaces)
    }

    static let titleLimit = 60

    // MARK: - too long to read whole

    /// how many requests' worth of transcript the provider takes in one. the
    /// apple model's window is small; the others take a long meeting whole.
    static func limit(for provider: RewriteProvider) -> Int {
        provider == .apple ? 6_000 : 300_000
    }

    /// the most times a long transcript is boiled down.
    static let rounds = 4

    /// parts of at most `limit` characters, cut between paragraphs. a
    /// paragraph longer than the limit is cut at a space, or anywhere when it
    /// has none.
    static func chunks(of text: String, limit: Int) -> [String] {
        guard text.count > limit, limit > 0 else { return [text] }
        var parts: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { parts.append(current) }
            current = ""
        }
        for paragraph in text.components(separatedBy: "\n\n") {
            for piece in pieces(of: paragraph, limit: limit) {
                let joined = current.isEmpty ? piece : current + "\n\n" + piece
                if joined.count <= limit {
                    current = joined
                } else {
                    flush()
                    current = piece
                }
            }
        }
        flush()
        return parts
    }

    private static func pieces(of paragraph: String, limit: Int) -> [String] {
        var rest = Substring(paragraph)
        guard rest.count > limit else { return [paragraph] }
        var out: [String] = []
        while rest.count > limit {
            let window = rest.prefix(limit)
            let end = window.lastIndex(of: " ").map { window.index(after: $0) }
                .flatMap { $0 > window.startIndex ? $0 : nil } ?? window.endIndex
            out.append(String(rest[..<end]).trimmingCharacters(in: .whitespaces))
            rest = rest[end...]
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out.filter { !$0.isEmpty }
    }

    // MARK: - asking, and asking again

    /// a try, and up to two more after a failure that is the network's or
    /// the provider's rather than the account's: one second, then three.
    static let backoff: [Duration] = [.seconds(1), .seconds(3)]

    /// a wait can end; a refusal of the key or the plan cannot, and asking
    /// again with it only costs time.
    static func isWorthRetrying(_ failure: RewriteFailure) -> Bool {
        switch failure {
        case .timedOut, .network, .unavailable, .rateLimited:
            true
        case .notSignedIn, .rejectedCredentials, .planLimitReached, .outOfCredits,
             .notAllowed, .modelUnavailable, .emptyAnswer:
            false
        }
    }

    private func ask(_ prompt: RewritePrompt) async throws -> String {
        var waits = Self.backoff[...]
        while true {
            do {
                let answer = try await client.complete(
                    prompt, model: model, timeout: timeout)
                let cleaned = RewriteInstructions.cleanAnswer(answer)
                guard !cleaned.isEmpty else { throw RewriteFailure.emptyAnswer }
                return cleaned
            } catch let failure as RewriteFailure {
                guard Self.isWorthRetrying(failure), let wait = waits.popFirst() else {
                    throw failure
                }
                try await pause(wait)
            }
        }
    }
}
