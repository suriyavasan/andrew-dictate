import Foundation

/// who rewrites a dictation when fn+ctrl was held. the rawValue is what
/// settings keep and what the keychain files a key under, so a case may be
/// renamed in swift but its rawValue never changes.
enum RewriteProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case chatGPT
    case openAI
    case openRouter
    case gemini
    case apple

    var id: String {
        rawValue
    }

    /// what the settings picker says. lowercase, like the rest of the app.
    var displayName: String {
        switch self {
        case .chatGPT:
            "chatgpt"
        case .openAI:
            "openai api key"
        case .openRouter:
            "openrouter"
        case .gemini:
            "google gemini"
        case .apple:
            "apple, on this mac"
        }
    }

    /// the provider's name inside a sentence on the pill: "openrouter is
    /// rate limiting", never "openai api key is rate limiting".
    var shortName: String {
        switch self {
        case .chatGPT:
            "chatgpt"
        case .openAI:
            "openai"
        case .openRouter:
            "openrouter"
        case .gemini:
            "gemini"
        case .apple:
            "apple's model"
        }
    }

    /// the small, fast tier of each, as of 2026-10. a rewrite is one short
    /// paragraph the user is waiting to paste, so time to first token
    /// matters more than anything a bigger model would add.
    ///
    /// - chatgpt, openai: gpt-6-luna (2026-09), the gpt-6 family's fast
    ///   tier; plus plans list it alongside sol and terra.
    /// - openrouter: the same model, pinned rather than the
    ///   `~openai/gpt-luna-latest` alias, so `reasoningEffort` stays a value
    ///   the model is known to accept.
    /// - gemini: gemini-3.5-flash-lite (2026-07), google's low-latency tier.
    /// - apple: there is one on-device model; the id is ignored.
    var defaultModel: String {
        switch self {
        case .chatGPT, .openAI:
            "gpt-6-luna"
        case .openRouter:
            "openai/gpt-6-luna"
        case .gemini:
            "gemini-3.5-flash-lite"
        case .apple:
            "on-device"
        }
    }

    /// the least thinking the default model allows. luna thinks at medium
    /// unless told otherwise, which is seconds a rewrite does not need;
    /// gemini 3 cannot stop thinking, so it is asked for the least.
    ///
    /// only the default model gets one: a model the user picked may not
    /// know the value, and an unknown effort is a 400 rather than a slower
    /// answer.
    func reasoningEffort(for model: String) -> String? {
        guard model == defaultModel else {
            return nil
        }
        switch self {
        case .chatGPT, .openAI, .openRouter:
            return "none"
        case .gemini:
            return "minimal"
        case .apple:
            return nil
        }
    }

    var needsNetwork: Bool {
        self != .apple
    }

    enum Authentication: Equatable, Sendable {
        /// a browser sign-in; nothing to paste.
        case signIn
        /// a pasted key.
        case apiKey
        /// either: openrouter's sign-in mints a key, so both end as a key.
        case signInOrAPIKey
        /// on this mac, nobody to ask.
        case none
    }

    var authentication: Authentication {
        switch self {
        case .chatGPT:
            .signIn
        case .openAI, .gemini:
            .apiKey
        case .openRouter:
            .signInOrAPIKey
        case .apple:
            .none
        }
    }
}

/// one rewrite: the style's instructions, and what the user said.
struct RewritePrompt: Equatable, Sendable {
    /// the system instructions — the style.
    let instructions: String
    /// the dictated text, already cleaned up.
    let text: String
}

protocol RewriteClient: Sendable {
    /// the model's answer, trimmed and never empty. a failure the user can
    /// act on is a `RewriteFailure`; cancellation is `CancellationError`.
    /// the timeout is the request's: a rewrite is a sentence the user waits
    /// on, a meeting's summary is minutes of talk nobody is waiting on.
    func complete(
        _ prompt: RewritePrompt,
        model: String,
        timeout: TimeInterval
    ) async throws -> String
}

extension RewriteClient {
    /// a rewrite, on the short leash the paste path allows.
    func rewrite(_ prompt: RewritePrompt, model: String) async throws -> String {
        try await complete(prompt, model: model, timeout: RewriteHTTP.rewriteTimeout)
    }
}

/// why a rewrite did not come back, in as few words as the pill has room
/// for. each case names what the user can do next, or that there is
/// nothing to do but wait.
enum RewriteFailure: Error, Equatable, Sendable {
    /// no key saved, or never signed in.
    case notSignedIn(RewriteProvider)
    /// the key or the sign-in was refused: revoked, expired, mistyped.
    case rejectedCredentials(RewriteProvider)
    case rateLimited(RewriteProvider)
    /// the chatgpt plan's own usage cap, which is not a rate limit: it
    /// does not clear in a minute, and chatgpt settings is where to look.
    case planLimitReached
    /// openrouter answers 402 when the account has no credit left.
    case outOfCredits(RewriteProvider)
    /// a policy, region or eligibility refusal. retrying will not help.
    case notAllowed(RewriteProvider)
    /// the model id is not one this account can use.
    case modelUnavailable(RewriteProvider)
    /// already in the pill's words: "openai is having trouble", "turn on
    /// apple intelligence".
    case unavailable(String)
    case emptyAnswer
    case timedOut
    case network

    var pillReason: String {
        switch self {
        case let .notSignedIn(provider):
            switch provider {
            case .chatGPT, .openRouter:
                "sign in to \(provider.shortName)"
            case .openAI:
                "add an openai key"
            case .gemini:
                "add a gemini key"
            case .apple:
                "apple's model isn't ready"
            }
        case let .rejectedCredentials(provider):
            switch provider {
            case .chatGPT:
                "sign in to chatgpt again"
            case .openAI, .openRouter, .gemini, .apple:
                "\(provider.shortName) rejected the key"
            }
        case let .rateLimited(provider):
            "\(provider.shortName) is rate limiting"
        case .planLimitReached:
            "chatgpt plan limit reached"
        case let .outOfCredits(provider):
            "\(provider.shortName) is out of credits"
        case let .notAllowed(provider):
            provider == .chatGPT
                ? "chatgpt plan can't be used here"
                : "\(provider.shortName) refused this account"
        case let .modelUnavailable(provider):
            "\(provider.shortName) doesn't have that model"
        case let .unavailable(reason):
            reason
        case .emptyAnswer:
            "the rewrite came back empty"
        case .timedOut:
            "the rewrite took too long"
        case .network:
            "no internet"
        }
    }

    /// "openai is having trouble": the one sentence every 5xx gets.
    static func trouble(_ provider: RewriteProvider) -> RewriteFailure {
        .unavailable("\(provider.shortName) is having trouble")
    }
}
