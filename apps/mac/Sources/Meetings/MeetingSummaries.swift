import Foundation

/// the notes and names of the meetings on disk: what is being summarized
/// now, what failed, and the doing of it. a meeting is summarized when it is
/// saved, if the switch is on, and whenever you ask — an explicit ask works
/// with the switch off, because it is a click.
///
/// one at a time per file: a second ask for the same meeting replaces the
/// first, which is let go and writes nothing. a failure leaves the file as
/// it was. nothing here logs or keeps a word of what was said.
@MainActor
final class MeetingSummaries: ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case summarizing
        /// the reason, in the words the pill uses.
        case failed(String)
    }

    /// the file operations, handed in so a test keeps the meetings in memory.
    /// they run off the main actor: a meeting file can be megabytes.
    struct Files: Sendable {
        var read: @Sendable (URL) throws -> MeetingDocument
        var setSummary: @Sendable (_ markdown: String, _ template: String, URL) throws -> Void
        var setTitle: @Sendable (_ title: String, URL) throws -> Void

        static let onDisk = Files(
            read: { try MeetingTranscriptFile.document(at: $0) },
            setSummary: { try MeetingTranscriptFile.setSummary($0, template: $1, at: $2) },
            setTitle: { try MeetingTranscriptFile.setTitle($0, at: $1) })
    }

    @Published private(set) var states: [URL: State] = [:]

    /// told after a file was written, with the file: for the window that
    /// lists them to read it again.
    var onChange: ((URL) -> Void)?

    private let connect: @MainActor () async -> Result<RewriteConnection, RewriteFailure>
    private let isEnabled: @MainActor () -> Bool
    private let defaultTemplateID: @MainActor () -> String
    private let files: Files
    private let pause: @Sendable (Duration) async throws -> Void

    private struct Flight {
        let id = UUID()
        var task: Task<Void, Never>?
    }

    private var flights: [URL: Flight] = [:]

    init(
        connect: @escaping @MainActor () async -> Result<RewriteConnection, RewriteFailure>,
        isEnabled: @escaping @MainActor () -> Bool,
        defaultTemplateID: @escaping @MainActor () -> String,
        files: Files = .onDisk,
        pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.connect = connect
        self.isEnabled = isEnabled
        self.defaultTemplateID = defaultTemplateID
        self.files = files
        self.pause = pause
    }

    func state(for url: URL) -> State {
        states[url] ?? .idle
    }

    /// a meeting was written: summarize it if summaries are on. the file's
    /// own template wins over the default, so a stand-up recorded into
    /// again stays a stand-up. nil when they are off.
    @discardableResult
    func meetingSaved(at url: URL) -> Task<Void, Never>? {
        guard isEnabled() else { return nil }
        return start(url, templateID: nil, explicit: false)
    }

    /// you asked, for this template. nobody having spoken is told, since
    /// there is a click to answer.
    @discardableResult
    func summarize(_ url: URL, templateID: String) -> Task<Void, Never> {
        start(url, templateID: templateID, explicit: true)
    }

    // MARK: - one flight

    private func start(_ url: URL, templateID: String?, explicit: Bool) -> Task<Void, Never> {
        flights[url]?.task?.cancel()
        var flight = Flight()
        let id = flight.id
        states[url] = .summarizing
        let task = Task { [weak self] in
            guard let self else { return }
            await run(url, templateID: templateID, explicit: explicit, flight: id)
        }
        flight.task = task
        flights[url] = flight
        return task
    }

    private func isCurrent(_ url: URL, _ flight: UUID) -> Bool {
        flights[url]?.id == flight && !Task.isCancelled
    }

    private func finish(_ url: URL, _ flight: UUID, as state: State) {
        guard isCurrent(url, flight) else { return }
        states[url] = state
        flights[url] = nil
    }

    private func run(
        _ url: URL,
        templateID: String?,
        explicit: Bool,
        flight: UUID
    ) async {
        let files = files
        let document: MeetingDocument
        do {
            document = try await Task.detached { try files.read(url) }.value
        } catch {
            finish(url, flight, as: .failed("can't read the transcript"))
            return
        }
        guard document.hasWords else {
            // a meeting nobody spoke in has nothing to summarize: quiet when
            // the app asked, an answer when you did.
            finish(url, flight, as: explicit ? .failed("nobody spoke in this one") : .idle)
            return
        }

        let template = MeetingTemplate.resolving(
            templateID ?? document.header.template ?? defaultTemplateID())
        let connection: RewriteConnection
        switch await connect() {
        case let .failure(failure):
            finish(url, flight, as: .failed(failure.pillReason))
            return
        case let .success(connected):
            connection = connected
        }
        guard isCurrent(url, flight) else { return }

        let summarizer = MeetingSummarizer(
            client: connection.client, model: connection.model,
            provider: connection.provider, pause: pause)
        let notes: String
        var title: String?
        do {
            notes = try await summarizer.summary(of: document, template: template)
            // a name is a nicety: one that fails leaves the meeting with its
            // call's name, and the notes are kept all the same.
            if document.header.title == nil, isCurrent(url, flight) {
                title = try? await summarizer.title(of: document)
            }
        } catch let failure as RewriteFailure {
            finish(url, flight, as: .failed(failure.pillReason))
            return
        } catch {
            // cancelled, or something the clients do not throw.
            finish(url, flight, as: .failed(RewriteFailure.network.pillReason))
            return
        }
        guard isCurrent(url, flight) else { return }

        let id = template.id
        let name = title
        do {
            try await Task.detached {
                try files.setSummary(notes, id, url)
                // a name you gave it while the model was writing wins.
                if let name, (try? files.read(url))?.header.title == nil {
                    try files.setTitle(name, url)
                }
            }.value
        } catch {
            finish(url, flight, as: .failed("can't save the summary"))
            return
        }
        finish(url, flight, as: .idle)
        onChange?(url)
    }
}
