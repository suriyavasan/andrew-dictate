import XCTest

final class RewriteProviderTests: XCTestCase {
    /// settings stores the rawValue and the keychain files keys under it:
    /// renaming one would forget every saved choice and key.
    func testRawValuesArePinned() {
        XCTAssertEqual(
            RewriteProvider.allCases.map(\.rawValue),
            ["chatGPT", "openAI", "openRouter", "gemini", "apple"]
        )
    }

    func testDisplayNamesAreLowercase() {
        XCTAssertEqual(RewriteProvider.chatGPT.displayName, "chatgpt")
        XCTAssertEqual(RewriteProvider.openAI.displayName, "openai api key")
        XCTAssertEqual(RewriteProvider.openRouter.displayName, "openrouter")
        XCTAssertEqual(RewriteProvider.gemini.displayName, "google gemini")
        XCTAssertEqual(RewriteProvider.apple.displayName, "apple, on this mac")
        for provider in RewriteProvider.allCases {
            XCTAssertEqual(provider.displayName, provider.displayName.lowercased())
        }
    }

    func testEachProviderSaysHowItAuthenticates() {
        XCTAssertEqual(RewriteProvider.chatGPT.authentication, .signIn)
        XCTAssertEqual(RewriteProvider.openAI.authentication, .apiKey)
        XCTAssertEqual(RewriteProvider.openRouter.authentication, .signInOrAPIKey)
        XCTAssertEqual(RewriteProvider.gemini.authentication, .apiKey)
        XCTAssertEqual(RewriteProvider.apple.authentication, .none)
    }

    /// apple is the one that works on a plane.
    func testOnlyAppleRunsOffline() {
        XCTAssertEqual(
            RewriteProvider.allCases.filter { !$0.needsNetwork },
            [.apple]
        )
    }

    /// openrouter's ids carry the vendor; the others' do not.
    func testDefaultModelsAreTheFastTier() {
        XCTAssertEqual(RewriteProvider.chatGPT.defaultModel, "gpt-6-luna")
        XCTAssertEqual(RewriteProvider.openAI.defaultModel, "gpt-6-luna")
        XCTAssertEqual(RewriteProvider.openRouter.defaultModel, "openai/gpt-6-luna")
        XCTAssertEqual(RewriteProvider.gemini.defaultModel, "gemini-3.5-flash-lite")
    }

    /// a model the user picked may not accept "none"; an unknown effort is
    /// a 400, which is worse than a slow answer.
    func testOnlyTheDefaultModelIsToldHowHardToThink() {
        XCTAssertEqual(RewriteProvider.openAI.reasoningEffort(for: "gpt-6-luna"), "none")
        XCTAssertEqual(
            RewriteProvider.gemini.reasoningEffort(for: "gemini-3.5-flash-lite"),
            "minimal"
        )
        XCTAssertNil(RewriteProvider.openAI.reasoningEffort(for: "gpt-4o"))
        XCTAssertNil(RewriteProvider.apple.reasoningEffort(for: "on-device"))
    }

    // MARK: - the pill

    func testPillReasonsNameTheNextMove() {
        XCTAssertEqual(
            RewriteFailure.rejectedCredentials(.chatGPT).pillReason,
            "sign in to chatgpt again"
        )
        XCTAssertEqual(
            RewriteFailure.rateLimited(.openRouter).pillReason,
            "openrouter is rate limiting"
        )
        XCTAssertEqual(RewriteFailure.network.pillReason, "no internet")
        XCTAssertEqual(
            RewriteFailure.planLimitReached.pillReason,
            "chatgpt plan limit reached"
        )
        XCTAssertEqual(RewriteFailure.notSignedIn(.openAI).pillReason, "add an openai key")
        XCTAssertEqual(RewriteFailure.notSignedIn(.chatGPT).pillReason, "sign in to chatgpt")
        XCTAssertEqual(
            RewriteFailure.rejectedCredentials(.gemini).pillReason,
            "gemini rejected the key"
        )
        XCTAssertEqual(
            RewriteFailure.outOfCredits(.openRouter).pillReason,
            "openrouter is out of credits"
        )
        XCTAssertEqual(
            RewriteFailure.unavailable("turn on apple intelligence").pillReason,
            "turn on apple intelligence"
        )
        XCTAssertEqual(
            RewriteFailure.trouble(.openAI).pillReason,
            "openai is having trouble"
        )
    }

    /// the pill is a few words wide, and the app never shouts.
    func testEveryPillReasonIsShortAndLowercase() {
        var failures: [RewriteFailure] = [
            .planLimitReached, .emptyAnswer, .timedOut, .network,
        ]
        for provider in RewriteProvider.allCases {
            failures += [
                .notSignedIn(provider), .rejectedCredentials(provider),
                .rateLimited(provider), .outOfCredits(provider),
                .notAllowed(provider), .modelUnavailable(provider),
                .trouble(provider),
            ]
        }
        for failure in failures {
            let reason = failure.pillReason
            XCTAssertEqual(reason, reason.lowercased(), reason)
            XCTAssertLessThanOrEqual(reason.split(separator: " ").count, 6, reason)
        }
    }
}
