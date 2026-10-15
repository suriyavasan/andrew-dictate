import Foundation

/// whether a provider can take a rewrite right now, for the settings row.
enum RewriteStatus: Equatable, Sendable {
    /// `detail` is who or what: the signed-in email, "key ending 3f9a".
    case ready(detail: String?)
    /// no key, never signed in, or signed in without the plan permission.
    case needsSetup
    /// set up as far as the user can, but not usable yet — apple's model
    /// downloading, say. the reason is already in the pill's words.
    case unavailable(String)
}

/// pasted (or openrouter-minted) api keys: saved trimmed, read back, shown
/// only by their last four.
enum RewriteKeys {
    static func save(
        _ key: String,
        for provider: RewriteProvider,
        in credentials: any CredentialStoring
    ) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try remove(for: provider, in: credentials)
            return
        }
        try credentials.setString(trimmed, for: CredentialAccount.key(provider))
    }

    static func remove(
        for provider: RewriteProvider,
        in credentials: any CredentialStoring
    ) throws {
        try credentials.remove(CredentialAccount.key(provider))
    }

    static func key(
        for provider: RewriteProvider,
        in credentials: any CredentialStoring
    ) -> String? {
        guard provider.authentication == .apiKey
            || provider.authentication == .signInOrAPIKey
        else {
            return nil
        }
        let key = try? credentials.string(for: CredentialAccount.key(provider))
        return key.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "key ending 3f9a": enough to tell two keys apart, not enough to use.
    static func detail(for key: String) -> String {
        "key ending \(key.suffix(4))"
    }
}

/// which client answers for a provider, and whether it can.
enum RewriteClients {
    /// a client for the provider as it is set up now. a provider with no
    /// key still gets a client — one that answers `notSignedIn` — so the
    /// caller's path is the same either way and the pill says what to do.
    /// `send` and `open` are the network, swapped out by tests.
    static func client(
        for provider: RewriteProvider,
        credentials: any CredentialStoring,
        chatGPT: ChatGPTAuth,
        send: @escaping RewriteHTTP.Send = RewriteHTTP.send,
        open: @escaping RewriteHTTP.Open = RewriteHTTP.open
    ) -> any RewriteClient {
        switch provider {
        case .chatGPT:
            return ChatGPTClient(auth: chatGPT, open: open)
        case .apple:
            return AppleRewriteClient()
        case .openAI, .openRouter, .gemini:
            guard let key = RewriteKeys.key(for: provider, in: credentials) else {
                return UnconfiguredClient(provider: provider)
            }
            return OpenAICompatibleClient(provider: provider, key: key, send: send)
        }
    }

    /// what the settings row says, without touching the network. a chatgpt
    /// session past its expiry is still ready: the next rewrite refreshes
    /// it.
    static func status(
        of provider: RewriteProvider,
        credentials: any CredentialStoring,
        chatGPT: ChatGPTAuth,
        apple: @Sendable () -> AppleModelAvailability = { .current }
    ) -> RewriteStatus {
        switch provider {
        case .chatGPT:
            guard let session = chatGPT.storedSession(), session.canUsePlan else {
                return .needsSetup
            }
            return .ready(detail: session.email)
        case .apple:
            if let reason = apple().reason {
                return .unavailable(reason)
            }
            return .ready(detail: nil)
        case .openAI, .openRouter, .gemini:
            guard let key = RewriteKeys.key(for: provider, in: credentials) else {
                return .needsSetup
            }
            return .ready(detail: RewriteKeys.detail(for: key))
        }
    }
}

/// a provider chosen but never set up: every rewrite says so.
struct UnconfiguredClient: RewriteClient {
    let provider: RewriteProvider

    func rewrite(_ prompt: RewritePrompt, model: String) async throws -> String {
        throw RewriteFailure.notSignedIn(provider)
    }
}
