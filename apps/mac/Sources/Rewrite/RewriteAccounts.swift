import Foundation

/// who can rewrite, as settings shows it and the rewrite asks it: the keys
/// and sign-ins in the keychain, a sign-in waiting on the browser, and the
/// client a take is handed.
///
/// the keychain is read on `refresh`, not on every redraw: an ad-hoc signed
/// build can ask the user once per read after an update, and a settings
/// tab must not turn that into a stream of dialogs.
@MainActor
final class RewriteAccounts: ObservableObject {
    static let shared = RewriteAccounts(
        credentials: KeychainCredentialStore(bundleID: AppIdentity.bundleID)
    )

    /// what the settings row shows under the provider picker.
    enum Status: Equatable {
        /// `detail` is who or what: the signed-in email, "key ending 3f9a".
        case ready(detail: String?)
        /// a browser sign-in is waiting; the message says on what.
        case working(String)
        /// set up as far as the user can, not usable yet.
        case unavailable(String)
        /// nothing saved yet. `problem` is why the last try did not take.
        case needsSetup(problem: String?)
    }

    @Published private var statuses: [RewriteProvider: RewriteStatus] = [:]
    @Published private var signingIn: RewriteProvider?
    @Published private var problems: [RewriteProvider: String] = [:]

    private let credentials: any CredentialStoring
    private let chatGPT: ChatGPTAuth
    private let openRouter: OpenRouterAuth
    private let apple: @Sendable () -> AppleModelAvailability
    private var signInTask: Task<Void, Never>?

    init(
        credentials: any CredentialStoring,
        apple: @escaping @Sendable () -> AppleModelAvailability = { .current }
    ) {
        self.credentials = credentials
        self.apple = apple
        chatGPT = ChatGPTAuth(credentials: credentials)
        openRouter = OpenRouterAuth(credentials: credentials)
    }

    func status(of provider: RewriteProvider) -> Status {
        if signingIn == provider {
            return .working("waiting for \(provider.signInName) in your browser…")
        }
        switch statuses[provider] ?? read(provider) {
        case let .ready(detail):
            return .ready(detail: detail)
        case let .unavailable(reason):
            return .unavailable(reason)
        case .needsSetup:
            return .needsSetup(problem: problems[provider])
        }
    }

    /// reads every provider's standing from the keychain again.
    func refresh() {
        statuses = Dictionary(
            uniqueKeysWithValues: RewriteProvider.allCases.map { ($0, read($0)) }
        )
    }

    // MARK: - setting up

    /// the browser round trip for chatgpt or openrouter. a second sign-in
    /// replaces the first: the user closed the tab and clicked again.
    func signIn(_ provider: RewriteProvider) async {
        guard provider.canSignIn else { return }
        signInTask?.cancel()
        problems[provider] = nil
        signingIn = provider
        let task = Task { [chatGPT, openRouter] in
            do {
                switch provider {
                case .chatGPT:
                    try await chatGPT.signIn()
                default:
                    try await openRouter.signIn()
                }
            } catch {
                let failure = error as? SignInFailure ?? .network
                if failure != .cancelled {
                    self.problems[provider] = failure.reason
                }
            }
        }
        signInTask = task
        await task.value
        if signingIn == provider {
            signingIn = nil
        }
        refresh()
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signingIn = nil
    }

    func saveKey(_ key: String, for provider: RewriteProvider) {
        do {
            try RewriteKeys.save(key, for: provider, in: credentials)
            problems[provider] = nil
        } catch {
            problems[provider] = "couldn't save the key in your keychain"
        }
        refresh()
    }

    /// a key is forgotten; a chatgpt sign-in is revoked at openai too, and
    /// forgotten here whether or not openai answers.
    func signOut(_ provider: RewriteProvider) {
        problems[provider] = nil
        switch provider {
        case .chatGPT:
            Task {
                await chatGPT.signOut()
                refresh()
            }
        case .openAI, .openRouter, .gemini:
            try? RewriteKeys.remove(for: provider, in: credentials)
            refresh()
        case .apple:
            break
        }
    }

    // MARK: - using it

    /// the models the provider offers this account, for the model menu.
    /// empty when it can't say: no key yet, offline, or apple's one model.
    func models(for provider: RewriteProvider) async -> [String] {
        switch provider {
        case .apple:
            return []
        case .chatGPT:
            guard chatGPT.storedSession() != nil else { return [] }
            let listed = try? await ChatGPTClient.listModels(auth: chatGPT)
            return listed?.map(\.slug) ?? []
        case .openAI, .openRouter, .gemini:
            let key = RewriteKeys.key(for: provider, in: credentials)
            guard key != nil || provider == .openRouter else { return [] }
            let listed = try? await OpenAICompatibleClient.listModels(
                provider: provider,
                key: key
            )
            return listed ?? []
        }
    }

    /// the client a take is handed, or why there is none — before the
    /// picker goes up, so a rewrite that cannot happen does not ask you to
    /// pick a style for it.
    func connect(
        _ provider: RewriteProvider,
        model: String
    ) async -> Result<RewriteConnection, RewriteFailure> {
        switch read(provider) {
        case .needsSetup:
            return .failure(.notSignedIn(provider))
        case let .unavailable(reason):
            return .failure(.unavailable(reason))
        case .ready:
            break
        }
        let client = RewriteClients.client(
            for: provider,
            credentials: credentials,
            chatGPT: chatGPT
        )
        return .success(
            RewriteConnection(client: client, model: model, provider: provider)
        )
    }

    private func read(_ provider: RewriteProvider) -> RewriteStatus {
        RewriteClients.status(
            of: provider,
            credentials: credentials,
            chatGPT: chatGPT,
            apple: apple
        )
    }
}

// MARK: - what settings says about each

extension RewriteProvider {
    /// apple has one model; every other provider can be told which.
    var needsModelChoice: Bool {
        self != .apple
    }

    var canSignIn: Bool {
        authentication == .signIn || authentication == .signInOrAPIKey
    }

    var acceptsKey: Bool {
        authentication == .apiKey || authentication == .signInOrAPIKey
    }

    /// the name on the sign-in button: "sign in with chatgpt…".
    var signInName: String {
        shortName
    }

    /// where a key is made, for the "get a key" link.
    var keyPage: URL? {
        switch self {
        case .openAI:
            URL(string: "https://platform.openai.com/api-keys")
        case .openRouter:
            URL(string: "https://openrouter.ai/settings/keys")
        case .gemini:
            URL(string: "https://aistudio.google.com/apikey")
        case .chatGPT, .apple:
            nil
        }
    }

    /// the line under "who rewrites it": who pays, and what it takes.
    var setupExplanation: String {
        switch self {
        case .chatGPT:
            "sign in and your chatgpt plan pays for rewrites and summaries. no api key, no bill."
        case .openAI:
            "an api key from platform.openai.com, billed to that account."
        case .openRouter:
            "sign in to make a key, or paste one. many models, one key."
        case .gemini:
            "a key from google ai studio. the free tier covers a lot of rewriting and summarizing."
        case .apple:
            "apple intelligence, on this mac. free and private, and the smallest model of these."
        }
    }
}
