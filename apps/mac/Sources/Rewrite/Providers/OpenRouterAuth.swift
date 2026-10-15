import Foundation

/// sign in with openrouter (openrouter.ai/docs/use-cases/oauth-pkce): the
/// browser asks the user, openrouter mints an api key for this app, and
/// the key is saved exactly as a pasted one would be. after that there is
/// no session to keep — the key is the sign-in, until the user deletes it
/// on openrouter.
struct OpenRouterAuth: Sendable {
    static let authorizeEndpoint = URL(string: "https://openrouter.ai/auth")!
    static let keysEndpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    static let callbackPath = "/callback"
    /// the minted key's name on the user's keys page.
    static let keyLabel = "Andrew Dictate"

    private let credentials: any CredentialStoring
    private let openURL: BrowserSignIn.OpenURL
    private let listen: CallbackListen
    private let send: RewriteHTTP.Send

    init(
        credentials: any CredentialStoring,
        openURL: @escaping BrowserSignIn.OpenURL = BrowserSignIn.openInBrowser,
        listen: @escaping CallbackListen = BrowserSignIn.listenOnLoopback,
        send: @escaping RewriteHTTP.Send = RewriteHTTP.send
    ) {
        self.credentials = credentials
        self.openURL = openURL
        self.listen = listen
        self.send = send
    }

    /// any port on localhost is accepted for an app without a site of its
    /// own; it shows up on openrouter as `localhost:<port>`.
    static func callbackURL(port: UInt16) -> String {
        "http://localhost:\(port)\(callbackPath)"
    }

    /// `state` comes back on the redirect when the user allows, and not
    /// when they refuse — the loopback lets a stateless refusal through
    /// for that reason.
    static func authorizeURL(callbackURL: String, challenge: String, state: String) -> URL {
        RewriteHTTP.url(authorizeEndpoint, query: [
            ("callback_url", callbackURL),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("key_label", keyLabel),
        ])
    }

    static func keyRequest(code: String, verifier: String) -> URLRequest {
        RewriteHTTP.jsonRequest(
            keysEndpoint,
            body: [
                "code": code,
                "code_verifier": verifier,
                "code_challenge_method": "S256",
            ],
            bearer: nil,
            timeout: RewriteHTTP.setupTimeout
        )
    }

    /// `{"key": "sk-or-…"}`, or why not. a 403 is a code that expired
    /// (ten minutes) or a verifier that does not match.
    static func key(status: Int, body: Data) throws -> String {
        guard status == 200 else {
            throw SignInFailure.refused(
                RewriteHTTP.errorCode(in: body) ?? "\(status)"
            )
        }
        guard let key = RewriteHTTP.object(body)?["key"] as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SignInFailure.incomplete
        }
        return key
    }

    /// the browser round trip, ending in a key saved under openrouter's
    /// account. returns the key, so the caller can show its last four.
    @discardableResult
    func signIn() async throws -> String {
        let state = PKCE.randomToken()
        let pkce = PKCE.make()
        let receiver: any CallbackReceiving
        do {
            receiver = try await listen(Self.callbackPath, state)
        } catch {
            throw SignInFailure.couldNotListen
        }
        let url = Self.authorizeURL(
            callbackURL: Self.callbackURL(port: receiver.port),
            challenge: pkce.challenge,
            state: state
        )
        let items = try await BrowserSignIn.redirect(
            from: receiver,
            opening: url,
            with: openURL
        )
        guard let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            throw SignInFailure.declined
        }
        let key: String
        do {
            let (body, response) = try await send(
                Self.keyRequest(code: code, verifier: pkce.verifier)
            )
            key = try Self.key(status: response.statusCode, body: body)
        } catch let failure as SignInFailure {
            throw failure
        } catch is CancellationError {
            throw SignInFailure.cancelled
        } catch {
            throw SignInFailure.network
        }
        try RewriteKeys.save(key, for: .openRouter, in: credentials)
        return key
    }
}
