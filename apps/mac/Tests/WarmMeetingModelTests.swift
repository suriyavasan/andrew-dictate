import XCTest

/// The meeting model, loaded once and kept: what a meeting reads with when
/// it was warmed before the press, what it does with an engine that hangs,
/// and when it is let go. Against a fake engine, which counts its loads.
final class WarmMeetingModelTests: XCTestCase {
    /// Warmed when the meetings window opened, the model the meeting asks
    /// for at the press is the one already loading: one load, not two.
    func testAMeetingAfterAWarmUpReadsWithTheModelAlreadyLoaded() async throws {
        let made = Made()
        let warm = WarmMeetingModel(make: { _ in made.engine() })

        await warm.warm(.whisperLargeV3)
        let engine = await warm.engine(for: .whisperLargeV3)
        try await engine.load()
        _ = try await engine.text(of: [0.1])

        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made.engines.first?.loads, 1)
    }

    /// A second meeting, and the reading again of a thin one, share it.
    func testTheNextMeetingGetsTheSameEngine() async throws {
        let made = Made()
        let warm = WarmMeetingModel(make: { _ in made.engine() })

        let first = await warm.engine(for: .whisperLargeV3)
        try await first.load()
        let second = await warm.engine(for: .whisperLargeV3)
        try await second.load()

        XCTAssertTrue(first === second)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made.engines.first?.loads, 1)
    }

    /// `record with` another model: that one is kept from then on.
    func testAnotherModelReplacesTheOneKept() async {
        let made = Made()
        let warm = WarmMeetingModel(make: { _ in made.engine() })

        _ = await warm.engine(for: .whisperLargeV3)
        _ = await warm.engine(for: .parakeetV3)

        XCTAssertEqual(made.count, 2)
        let kept = await warm.kept
        XCTAssertEqual(kept, .parakeetV3)
    }

    /// A load that failed is not the model's answer for good: the meeting
    /// that needs it tries again.
    func testALoadThatFailedIsTriedAgain() async throws {
        let made = Made(failFirstLoad: true)
        let warm = WarmMeetingModel(make: { _ in made.engine() })
        let engine = await warm.engine(for: .whisperLargeV3)

        do {
            try await engine.load()
            XCTFail("the first load fails")
        } catch {}
        try await engine.load()

        XCTAssertEqual(made.engines.first?.loads, 2)
    }

    /// A decode that never comes back must not be handed to every meeting
    /// after it: the next to ask gets an engine of its own.
    func testAnEngineWithADecodeThatNeverCameBackIsNotHandedOutAgain() async throws {
        let made = Made()
        let warm = WarmMeetingModel(wedgedAfter: .milliseconds(50), make: { _ in made.engine() })
        let wedged = await warm.engine(for: .whisperLargeV3)
        made.engines.first?.hangs = true
        let stuck = Task { try await wedged.text(of: [0.1]) }
        try await Task.sleep(for: .milliseconds(150))

        let next = await warm.engine(for: .whisperLargeV3)

        XCTAssertFalse(next === wedged)
        XCTAssertEqual(made.count, 2)
        stuck.cancel()
    }

    /// Unused for `linger`, it is let go; in use, it is not.
    func testAModelUnusedForItsLingerIsLetGo() async throws {
        let made = Made()
        let warm = WarmMeetingModel(linger: .milliseconds(100), make: { _ in made.engine() })
        _ = await warm.engine(for: .whisperLargeV3)

        try await Task.sleep(for: .milliseconds(400))

        let kept = await warm.kept
        XCTAssertNil(kept)
    }

    func testAModelInUseIsNotLetGo() async throws {
        let made = Made()
        let warm = WarmMeetingModel(linger: .milliseconds(100), make: { _ in made.engine() })
        let engine = await warm.engine(for: .whisperLargeV3)
        made.engines.first?.hangs = true
        let decoding = Task { try await engine.text(of: [0.1]) }

        try await Task.sleep(for: .milliseconds(400))

        let kept = await warm.kept
        XCTAssertEqual(kept, .whisperLargeV3, "a decode going on is use")
        decoding.cancel()
    }
}

// MARK: - fakes

private final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeStretchEngine] = []
    private let failFirstLoad: Bool

    init(failFirstLoad: Bool = false) {
        self.failFirstLoad = failFirstLoad
    }

    var count: Int { lock.withLock { made.count } }
    var engines: [FakeStretchEngine] { lock.withLock { made } }

    func engine() -> FakeStretchEngine {
        let engine = FakeStretchEngine(failFirstLoad: failFirstLoad)
        lock.withLock { made.append(engine) }
        return engine
    }
}

private struct LoadFailed: Error {}

private final class FakeStretchEngine: StretchEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0
    private var _hangs = false
    private let failFirstLoad: Bool

    init(failFirstLoad: Bool) {
        self.failFirstLoad = failFirstLoad
    }

    var loads: Int { lock.withLock { _loads } }

    /// Every decode from now on waits until it is cancelled.
    var hangs: Bool {
        get { lock.withLock { _hangs } }
        set { lock.withLock { _hangs = newValue } }
    }

    func load() async throws {
        let first = lock.withLock { () -> Bool in
            _loads += 1
            return _loads == 1
        }
        if first, failFirstLoad { throw LoadFailed() }
    }

    func text(of samples: [Float]) async throws -> String {
        if hangs { try await Task.sleep(for: .seconds(600)) }
        return "words"
    }
}
