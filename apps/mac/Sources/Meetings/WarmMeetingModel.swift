import Foundation
import os

/// The meeting model, loaded once and kept while meetings are likely, so
/// a meeting is read as it is said and not after it.
///
/// Whisper large-v3 takes over a minute to load (measured 2026-10-16: 64 to
/// 92 s, on the neural engine or the gpu, the second load no faster than
/// the first). Loaded at the press, as every meeting used to, a short
/// meeting was over before its model was in: nothing was live, every
/// stretch waited for the stop, and the stop waited for the load. So the
/// model is loaded the moment a meeting looks likely — the meetings window
/// opened, a call heard beginning, the press itself — and kept, for every
/// meeting, the reading again of a thin one, a recovery and a transcribe
/// again alike, until it has gone unused for `linger`.
///
/// One model is kept, the last one asked for. A meeting holds the engine it
/// was handed for as long as it runs, so one replaced or let go here is let
/// go only when that meeting is done with it.
///
/// The app's one is `MeetingEngines.warm`.
actor WarmMeetingModel {
    /// How long a model nobody has used is kept. Provisional: a meeting
    /// recorded into again after a stand-up, or the next call of a run of
    /// them, is within it.
    static let defaultLinger = Duration.seconds(15 * 60)

    private let make: @Sendable (SpeechModel) -> any StretchEngine
    private let linger: Duration
    private let wedgedAfter: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async -> Void
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "meeting-models")

    private var held: SharedStretchEngine?
    private var lettingGo: Task<Void, Never>?

    /// `wedgedAfter` is how long one decode may go on before the engine is
    /// taken for wedged: a call that never comes back must not be handed to
    /// every meeting after it. Past twice the longest try a stretch is given
    /// (`StretchTranscriber.Patience`), it is not a slow day.
    init(
        linger: Duration = WarmMeetingModel.defaultLinger,
        wedgedAfter: Duration = .seconds(120),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        make: @escaping @Sendable (SpeechModel) -> any StretchEngine
    ) {
        self.make = make
        self.linger = linger
        self.wedgedAfter = wedgedAfter
        self.now = now
        self.sleep = sleep
    }

    /// The engine for `model`: the one kept, when it is that model's and
    /// is not wedged, and otherwise a new one, kept from now on. Not loaded
    /// yet, perhaps; its `load` is shared by whoever asks.
    func engine(for model: SpeechModel) async -> SharedStretchEngine {
        if let held, held.model == model {
            if await held.isWedged(after: wedgedAfter) {
                logger.error("the meeting model has a decode that never came back; loading another")
            } else {
                keepForAWhile()
                return held
            }
        }
        let fresh = SharedStretchEngine(model: model, engine: make(model), now: now)
        held = fresh
        keepForAWhile()
        return fresh
    }

    /// Starts loading `model` now, for a meeting that looks likely, and
    /// returns without waiting. A load that fails is tried again by the
    /// meeting that needs it, which says why when it fails too.
    func warm(_ model: SpeechModel) async {
        let engine = await engine(for: model)
        Task.detached(priority: .utility) {
            try? await engine.load()
        }
    }

    /// The model kept, if any: for a test, and for nothing else.
    var kept: SpeechModel? { held?.model }

    /// Looks again `linger` from now, and lets the model go once it has had
    /// a whole `linger` with no decode and none going on. A meeting holding
    /// it keeps it in use, so it is never let go under one.
    private func keepForAWhile() {
        lettingGo?.cancel()
        lettingGo = Task { [weak self, linger, sleep] in
            while !Task.isCancelled {
                await sleep(linger)
                guard !Task.isCancelled, let self else { return }
                if await self.letGoIfUnused() { return }
            }
        }
    }

    private func letGoIfUnused() async -> Bool {
        guard let held else { return true }
        guard await held.isUnused(for: linger) else { return false }
        logger.notice("letting the meeting model go: unused for \(self.linger.totalSeconds, format: .fixed(precision: 0), privacy: .public) s")
        self.held = nil
        return true
    }
}

/// One stretch engine, shared: one load however many ask for it, and a
/// note of each decode while it is going on, so a wedged one can be told
/// and the engine not handed out again.
actor SharedStretchEngine: StretchEngine {
    nonisolated let model: SpeechModel
    private let engine: any StretchEngine
    private let now: @Sendable () -> ContinuousClock.Instant
    private var loading: Task<Void, any Error>?
    /// The decodes going on, and when each began.
    private var decoding: [UUID: ContinuousClock.Instant] = [:]
    private var lastUsed: ContinuousClock.Instant

    init(
        model: SpeechModel, engine: any StretchEngine,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.model = model
        self.engine = engine
        self.now = now
        lastUsed = now()
    }

    /// Loaded once. A load that failed is not kept: the next to ask tries
    /// again, so one failed warm-up does not fail every meeting after it.
    func load() async throws {
        let loading = loading ?? Task { [engine] in try await engine.load() }
        self.loading = loading
        do {
            try await loading.value
        } catch {
            if self.loading == loading { self.loading = nil }
            throw error
        }
    }

    func text(of samples: [Float]) async throws -> String {
        let id = UUID()
        decoding[id] = now()
        lastUsed = now()
        defer {
            decoding[id] = nil
            lastUsed = now()
        }
        return try await engine.text(of: samples)
    }

    /// A decode has been going on for longer than `limit`.
    func isWedged(after limit: Duration) -> Bool {
        let now = now()
        return decoding.values.contains { now - $0 > limit }
    }

    /// Nothing decoded for `span`, and nothing being decoded now.
    func isUnused(for span: Duration) -> Bool {
        decoding.isEmpty && now() - lastUsed >= span
    }
}
