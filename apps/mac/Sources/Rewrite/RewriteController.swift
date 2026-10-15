import AppKit
import Foundation

/// a provider ready to answer, and the model it was told to use.
struct RewriteConnection {
    let client: any RewriteClient
    let model: String
    let provider: RewriteProvider
}

/// the rewrite's half of a take (fn+⌃), from the cleaned words to the words
/// that are pasted: the picker on the pill, then the model.
///
/// the model is asked for the style the picker starts on the moment the
/// picker goes up, so the usual answer — the style you used last, or no
/// pick at all — is already on its way while you look. another pick asks
/// again and lets the first go.
///
/// every way it ends has words in it: the model's, or yours as said with a
/// reason the pill gives after they land. only esc ends it with none, and
/// that is the machine's to do.
@MainActor
final class RewriteController {
    typealias Connect = @MainActor () async -> Result<RewriteConnection, RewriteFailure>

    /// how long the model has to answer once the style is picked. a
    /// rewrite is a sentence or a paragraph; past this, something is wrong.
    static let answerDeadline: Duration = .seconds(20)

    /// the pill: the picker, the wait, or nil when it is over.
    var showPill: ((HUDRewritePill?) -> Void)?
    /// a VoiceOver announcement: the panel is never visited, so the picker
    /// has to say itself.
    var announce: ((String) -> Void)?

    /// whether the picker is up and waiting: the panel takes clicks only
    /// then.
    var isPicking: Bool {
        pickContinuation != nil
    }

    private let settings: RewriteSettings
    private let connect: Connect
    private let pickLasts: Duration
    private let keys = RewritePickerKeys()
    private let epoch = ContinuousClock.now

    private var pick: RewritePick?
    private var pickContinuation: CheckedContinuation<RewriteChoice?, Never>?
    private var countdown: PillCountdown?
    private var pickTimer: Task<Void, Never>?

    init(
        settings: RewriteSettings,
        pickLasts: Duration = RewritePick.lasts,
        connect: @escaping Connect
    ) {
        self.settings = settings
        self.pickLasts = pickLasts
        self.connect = connect
        keys.onDigit = { [weak self] digit in
            self?.pressed(digit: digit)
        }
    }

    /// the machine's `rewrite`: the cleaned words in, what to paste out.
    func run(_ text: String) async -> RewriteOutcome {
        defer {
            showPill?(nil)
        }
        let connection: RewriteConnection
        switch await connect() {
        case let .success(ready):
            connection = ready
        case let .failure(failure):
            return .failed(reason: failure.pillReason, style: nil)
        }

        let pick = RewritePick(
            styles: settings.pickerStyles,
            lastStyleID: settings.lastStyleID
        )
        var asked = (
            style: pick.startingStyle,
            answer: ask(connection, text, pick.startingStyle)
        )

        let choice = await choose(from: pick)
        let style: RewriteStyle
        switch choice {
        case nil, .asSaid:
            asked.answer.cancel()
            return .asSaid
        case let .style(picked):
            style = picked
        }

        settings.lastStyleID = style.id
        if style.id != asked.style.id {
            asked.answer.cancel()
            asked = (style, ask(connection, text, style))
        }
        showPill?(.working("rewriting · \(style.name)…"))

        let name = RewritePick.recordName(for: style)
        do {
            let rewritten = try await answer(asked.answer)
            return .rewritten(rewritten, style: name)
        } catch is CancellationError {
            return .asSaid
        } catch let failure as RewriteFailure {
            return .failed(reason: failure.pillReason, style: name)
        } catch {
            return .failed(reason: RewriteFailure.network.pillReason, style: name)
        }
    }

    // MARK: - the picker

    /// a button on the pill, by its place in the row.
    func chose(button index: Int) {
        guard let choice = pick?.choice(forButton: index) else {
            return
        }
        finishPick(choice)
    }

    /// the pointer over the pill holds the picker up, the way it holds a
    /// question (`PillCountdown`).
    func pointerOverPill(_ over: Bool) {
        guard countdown != nil else {
            return
        }
        countdown?.pointer(
            isOver: over,
            at: NSEvent.mouseLocation,
            now: elapsed()
        )
        timeThePick()
    }

    private func choose(from pick: RewritePick) async -> RewriteChoice? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.pick = pick
                pickContinuation = continuation
                showPill?(.picking(pick.buttons))
                announce?(
                    "rewrite it how? "
                        + pick.buttons
                        .map { "\($0.key), \($0.title)" }
                        .joined(separator: ". ")
                )
                keys.take(Array(0...pick.styles.count))
                countdown = PillCountdown(
                    lasts: pickLasts,
                    startedAt: elapsed(),
                    pointerAt: NSEvent.mouseLocation
                )
                timeThePick()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPick(nil)
            }
        }
    }

    private func pressed(digit: Int) {
        guard let choice = pick?.choice(forDigit: digit) else {
            return
        }
        finishPick(choice)
    }

    private func timeThePick() {
        pickTimer?.cancel()
        guard let countdown else {
            return
        }
        let left = countdown.timeLeft(at: elapsed())
        pickTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: left)
            guard !Task.isCancelled, let self else {
                return
            }
            guard let countdown = self.countdown,
                  let pick = self.pick else {
                return
            }
            if countdown.timeLeft(at: self.elapsed()) > .zero {
                self.timeThePick()
            } else {
                self.finishPick(.style(pick.startingStyle))
            }
        }
    }

    private func finishPick(_ choice: RewriteChoice?) {
        guard let continuation = pickContinuation else {
            return
        }
        pickContinuation = nil
        pick = nil
        countdown = nil
        pickTimer?.cancel()
        pickTimer = nil
        keys.release()
        continuation.resume(returning: choice)
    }

    private func elapsed() -> Duration {
        epoch.duration(to: .now)
    }

    // MARK: - the model

    private func ask(
        _ connection: RewriteConnection,
        _ text: String,
        _ style: RewriteStyle
    ) -> Task<String, any Error> {
        let prompt = RewriteInstructions.prompt(for: text, style: style)
        let client = connection.client
        let model = connection.model
        return Task.detached(priority: .userInitiated) {
            let raw = try await client.rewrite(prompt, model: model)
            let cleaned = RewriteInstructions.cleanAnswer(raw)
            guard !cleaned.isEmpty else {
                throw RewriteFailure.emptyAnswer
            }
            return cleaned
        }
    }

    /// the answer, or the deadline, whichever is first. the take being
    /// thrown away (esc) lets the request go too.
    private func answer(_ task: Task<String, any Error>) async throws -> String {
        try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await task.value
                    }
                    group.addTask {
                        try await Task.sleep(for: Self.answerDeadline)
                        throw RewriteFailure.timedOut
                    }
                    defer {
                        group.cancelAll()
                    }
                    guard let first = try await group.next() else {
                        throw RewriteFailure.timedOut
                    }
                    return first
                }
            } catch {
                task.cancel()
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }
}
