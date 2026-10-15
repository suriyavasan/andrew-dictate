import Foundation

/// a chatgpt sign-in, as the keychain keeps it. the access token lasts an
/// hour; the refresh token thirty days, and each refresh hands back a new
/// one, so a mac that rewrites at least once a month never signs in again.
struct ChatGPTSession: Codable, Equatable, Sendable {
    /// the `oaiapp_…` id openai issued this app at first sign-in.
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let email: String?
    /// the id token's `sub`: who this is. email is for showing, not for
    /// telling accounts apart.
    let subject: String
    /// kept so it can be checked again; never sent anywhere.
    let idToken: String
    /// what openai actually granted, which may be less than was asked.
    let scopes: [String]

    /// signed in is not enough: the user can sign in and leave the plan
    /// permission unticked, and then there is nothing to rewrite with.
    var canUsePlan: Bool {
        scopes.contains(ChatGPTOAuth.planScope)
    }

    /// two minutes early, so a token never expires between the check and
    /// the request.
    func needsRefresh(now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) < 120
    }
}

/// which openai registration this mac uses. it outlives signing out:
/// openai's guide asks that signing back in reuse the issued client rather
/// than register the app again.
struct ChatGPTRegistration: Codable, Equatable, Sendable {
    let clientID: String
    /// nil between the redirect and the verified token exchange.
    let subject: String?
    let email: String?
}

/// sign in with chatgpt, for open-source apps
/// (developers.openai.com/siwc/token-sharing-open-source): a public oauth
/// client with PKCE, registered on the fly the first time, whose tokens can
/// spend the user's chatgpt plan on the responses api. every request and
/// every parser here is pure; `ChatGPTAuth` does the sending.
///
/// the endpoints are pinned from auth.openai.com's openid-configuration as
/// read on 2026-10-16, rather than discovered at runtime: one fewer request
/// on the way to a sign-in, and a change there is a change to read about
/// before shipping.
enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let authorizeEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let revocationEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    static let jwksEndpoint = URL(string: "https://auth.openai.com/.well-known/jwks.json")!

    /// the tokens are for the openai api, and say so.
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scope = "openid profile email offline_access resource.invoke \(planScope)"

    /// the first-time entry point. openai answers it with an `oaiapp_…` id,
    /// which is the one to keep; this one is never saved.
    static let registrationClientID = "dynamic_agent_client"
    /// what the user sees, and can rename, on openai's consent page.
    static let agentName = "Andrew Dictate"

    /// openai matches the redirect exactly, except for the port:
    /// `/auth/callback` on 127.0.0.1, never `localhost`.
    static let callbackPath = "/auth/callback"

    static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(callbackPath)"
    }

    /// this mac's `ext_agent_host_id`: a random uuid as a urn. opaque on
    /// purpose — never an email or a user id.
    static func newHostID() -> String {
        "urn:uuid:\(UUID().uuidString.lowercased())"
    }

    /// the browser's first stop. a returning sign-in uses the issued
    /// client and drops the name hint; the email, if one was verified, is
    /// a `login_hint`. the old id token would skip the account picker as
    /// `id_token_hint`, but it is left out, the way openai's own kit leaves
    /// it out: a url handed to the browser can end up in a process list or
    /// a history sync. `askAgain` puts the plan permission back on screen
    /// for a user who left it unticked last time.
    static func authorizeURL(
        clientID: String?,
        hostID: String,
        redirectURI: String,
        state: String,
        nonce: String,
        challenge: String,
        loginHint: String?,
        askAgain: Bool = false
    ) -> URL {
        var pairs: [(String, String)] = [
            ("client_id", clientID ?? registrationClientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("resource", resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
            ("ext_agent_host_id", hostID),
        ]
        if clientID == nil {
            pairs.append(("agent_name_hint", agentName))
        }
        if let loginHint, !loginHint.isEmpty {
            pairs.append(("login_hint", loginHint))
        }
        if askAgain {
            pairs.append(("prompt", "consent"))
        }
        return RewriteHTTP.url(authorizeEndpoint, query: pairs)
    }

    /// the code and the client to exchange it with, out of the redirect.
    /// the loopback has already matched the state. a first sign-in must
    /// bring an issued id; a returning one may leave it out, and must not
    /// bring a different one.
    static func callback(
        _ items: [URLQueryItem],
        savedClientID: String?
    ) throws -> (code: String, clientID: String) {
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") {
            throw error == "access_denied"
                ? SignInFailure.declined
                : SignInFailure.refused(error)
        }
        let returned = value("client_id")
        guard let code = value("code"), !code.isEmpty,
              let clientID = returned ?? savedClientID,
              clientID != registrationClientID,
              !clientID.isEmpty,
              savedClientID == nil || returned == nil || returned == savedClientID
        else {
            throw SignInFailure.incomplete
        }
        return (code, clientID)
    }

    /// no client secret: an app whose source is public cannot keep one.
    /// the verifier is the proof instead.
    static func codeExchange(
        code: String,
        clientID: String,
        verifier: String,
        redirectURI: String
    ) -> URLRequest {
        RewriteHTTP.formRequest(tokenEndpoint, [
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("resource", resource),
        ])
    }

    /// no `scope`: leaving it out keeps the grant as it was.
    static func refresh(refreshToken: String, clientID: String) -> URLRequest {
        RewriteHTTP.formRequest(tokenEndpoint, [
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("resource", resource),
        ])
    }

    /// ends the renewable session at openai, not just on this mac.
    static func revoke(refreshToken: String, clientID: String) -> URLRequest {
        RewriteHTTP.formRequest(revocationEndpoint, [
            ("token", refreshToken),
            ("token_type_hint", "refresh_token"),
            ("client_id", clientID),
        ])
    }

    static func jwksRequest() -> URLRequest {
        RewriteHTTP.plainRequest(
            jwksEndpoint,
            method: "GET",
            timeout: RewriteHTTP.setupTimeout
        )
    }

    struct Tokens: Equatable, Sendable {
        let accessToken: String
        /// a refresh always rotates it; nil only if openai broke that.
        let refreshToken: String?
        let idToken: String?
        let expiresIn: TimeInterval
        let scopes: [String]
    }

    /// the token endpoint said no. `code` is oauth's `error` string.
    struct Refusal: Error, Equatable, Sendable {
        let status: Int
        let code: String?

        /// the refresh token is spent, expired or revoked: only a new
        /// sign-in helps. anything else — a 5xx, a timeout — keeps it.
        var needsSignIn: Bool {
            [
                "invalid_grant", "invalid_refresh_token", "token_expired",
                "refresh_token_expired", "refresh_token_invalidated",
                "refresh_token_reused",
            ].contains(code ?? "")
        }
    }

    /// a token response, or the refusal it was. a refresh may omit
    /// `scope`, meaning unchanged, so the previous grant fills in.
    static func tokens(
        status: Int,
        body: Data,
        previousScopes: [String] = []
    ) throws -> Tokens {
        guard status == 200 else {
            throw Refusal(status: status, code: RewriteHTTP.errorCode(in: body))
        }
        guard let object = RewriteHTTP.object(body),
              let access = object["access_token"] as? String, !access.isEmpty,
              (object["token_type"] as? String)?.lowercased() == "bearer",
              let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue,
              expiresIn > 0
        else {
            throw Refusal(status: status, code: "invalid_token_response")
        }
        let scopes = (object["scope"] as? String).map {
            $0.split(separator: " ").map(String.init)
        } ?? previousScopes
        return Tokens(
            accessToken: access,
            refreshToken: (object["refresh_token"] as? String).flatMap {
                $0.isEmpty ? nil : $0
            },
            idToken: object["id_token"] as? String,
            expiresIn: expiresIn,
            scopes: scopes
        )
    }
}

/// the chatgpt sign-in and its upkeep: signing in through the browser,
/// keeping the hour-long access token fresh, signing out. an actor, so a
/// refresh is single-flight — a rotating refresh token used twice is a
/// revoked session, and two rewrites at once would otherwise both try.
actor ChatGPTAuth {
    private let credentials: any CredentialStoring
    private let openURL: BrowserSignIn.OpenURL
    private let listen: CallbackListen
    private let send: RewriteHTTP.Send
    private let now: @Sendable () -> Date

    private var refreshing: Task<ChatGPTSession, any Error>?
    private var pendingSignIn: (any CallbackReceiving)?

    init(
        credentials: any CredentialStoring,
        openURL: @escaping BrowserSignIn.OpenURL = BrowserSignIn.openInBrowser,
        listen: @escaping CallbackListen = BrowserSignIn.listenOnLoopback,
        send: @escaping RewriteHTTP.Send = RewriteHTTP.send,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.openURL = openURL
        self.listen = listen
        self.send = send
        self.now = now
    }

    /// what the keychain holds now, without refreshing it. for settings,
    /// which wants an email to show and must not wait on the network.
    nonisolated func storedSession() -> ChatGPTSession? {
        try? credentials.decoded(
            ChatGPTSession.self,
            for: CredentialAccount.chatGPTSession
        )
    }

    /// this mac's host id: read, or made and kept on first use.
    func hostID() throws -> String {
        if let saved = try credentials.string(for: CredentialAccount.chatGPTHost) {
            return saved
        }
        let made = ChatGPTOAuth.newHostID()
        try credentials.setString(made, for: CredentialAccount.chatGPTHost)
        return made
    }

    // MARK: - signing in

    /// the whole browser round trip, ending in a saved session that can
    /// spend the plan. a second call while one is waiting replaces it —
    /// the user closed the tab and clicked again.
    ///
    /// `asNewAccount` registers afresh instead of reusing this mac's
    /// registration: for switching to a different chatgpt account.
    @discardableResult
    func signIn(asNewAccount: Bool = false) async throws -> ChatGPTSession {
        pendingSignIn?.cancel()
        let host = try hostID()
        let registration = asNewAccount
            ? nil
            : try? credentials.decoded(
                ChatGPTRegistration.self,
                for: CredentialAccount.chatGPTRegistration
            )
        let previous = storedSession()
        let state = PKCE.randomToken()
        let nonce = PKCE.randomToken()
        let pkce = PKCE.make()

        let receiver: any CallbackReceiving
        do {
            receiver = try await listen(ChatGPTOAuth.callbackPath, state)
        } catch {
            throw SignInFailure.couldNotListen
        }
        pendingSignIn = receiver
        let redirectURI = ChatGPTOAuth.redirectURI(port: receiver.port)
        let url = ChatGPTOAuth.authorizeURL(
            clientID: registration?.clientID,
            hostID: host,
            redirectURI: redirectURI,
            state: state,
            nonce: nonce,
            challenge: pkce.challenge,
            loginHint: registration?.email,
            askAgain: previous.map { !$0.canUsePlan } ?? false
        )
        let items = try await BrowserSignIn.redirect(
            from: receiver,
            opening: url,
            with: openURL
        )
        let (code, clientID) = try ChatGPTOAuth.callback(
            items,
            savedClientID: registration?.clientID
        )
        // kept before the exchange: a code can expire after the app was
        // registered, and the retry should not register it twice.
        if registration?.clientID != clientID {
            try credentials.setEncoded(
                ChatGPTRegistration(clientID: clientID, subject: nil, email: nil),
                for: CredentialAccount.chatGPTRegistration
            )
        }

        let tokens: ChatGPTOAuth.Tokens
        do {
            let (body, response) = try await send(
                ChatGPTOAuth.codeExchange(
                    code: code,
                    clientID: clientID,
                    verifier: pkce.verifier,
                    redirectURI: redirectURI
                )
            )
            tokens = try ChatGPTOAuth.tokens(status: response.statusCode, body: body)
        } catch let refusal as ChatGPTOAuth.Refusal {
            throw SignInFailure.refused(refusal.code ?? "\(refusal.status)")
        } catch {
            throw Self.signInFailure(from: error)
        }
        guard let idToken = tokens.idToken, let refreshToken = tokens.refreshToken else {
            throw SignInFailure.incomplete
        }
        let identity = try await verified(idToken, clientID: clientID, nonce: nonce)
        if let known = registration?.subject, known != identity.subject {
            throw SignInFailure.differentAccount
        }
        try credentials.setEncoded(
            ChatGPTRegistration(
                clientID: clientID,
                subject: identity.subject,
                email: identity.email
            ),
            for: CredentialAccount.chatGPTRegistration
        )
        let session = ChatGPTSession(
            clientID: clientID,
            accessToken: tokens.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(tokens.expiresIn),
            email: identity.email,
            subject: identity.subject,
            idToken: idToken,
            scopes: tokens.scopes
        )
        try save(session)
        pendingSignIn = nil
        // signed in either way, so settings can show who; but a session
        // without the plan scope cannot rewrite, and the user should hear so.
        guard session.canUsePlan else {
            throw SignInFailure.planNotShared
        }
        return session
    }

    /// the signature against openai's published keys, then the claims
    /// against this attempt.
    private func verified(
        _ idToken: String,
        clientID: String,
        nonce: String
    ) async throws -> IDToken {
        let jwks: Data
        do {
            let (body, response) = try await send(ChatGPTOAuth.jwksRequest())
            guard response.statusCode == 200 else {
                throw SignInFailure.unverifiedIdentity
            }
            jwks = body
        } catch {
            throw Self.signInFailure(from: error)
        }
        do {
            let token = try IDToken.decode(idToken)
            try token.checkSignature(jwks: jwks)
            try token.checkClaims(
                issuer: ChatGPTOAuth.issuer,
                clientID: clientID,
                nonce: nonce,
                now: now()
            )
            return token
        } catch {
            throw SignInFailure.unverifiedIdentity
        }
    }

    // MARK: - staying signed in

    /// a session whose access token has at least two minutes left,
    /// refreshed if it had less. callers that arrive while a refresh runs
    /// wait for that one instead of starting their own.
    func validSession() async throws -> ChatGPTSession {
        if let refreshing {
            return try await refreshing.value
        }
        guard let session = storedSession() else {
            throw RewriteFailure.notSignedIn(.chatGPT)
        }
        guard session.needsRefresh(now: now()) else {
            return session
        }
        let task = Task {
            try await self.refresh(session)
        }
        refreshing = task
        defer {
            refreshing = nil
        }
        return try await task.value
    }

    /// trades the refresh token for a new pair and saves both together.
    ///
    /// a refreshed id token is read for its email but its signature is not
    /// checked: it came straight from the token endpoint over tls, which
    /// openid connect core §3.1.3.7 accepts in place of the signature, and
    /// a failed key fetch here would strand the rotated refresh token. the
    /// account it names still has to be the one that signed in.
    private func refresh(_ session: ChatGPTSession) async throws -> ChatGPTSession {
        let tokens: ChatGPTOAuth.Tokens
        do {
            let (body, response) = try await send(
                ChatGPTOAuth.refresh(
                    refreshToken: session.refreshToken,
                    clientID: session.clientID
                )
            )
            tokens = try ChatGPTOAuth.tokens(
                status: response.statusCode,
                body: body,
                previousScopes: session.scopes
            )
        } catch let refusal as ChatGPTOAuth.Refusal {
            if refusal.needsSignIn {
                try? credentials.remove(CredentialAccount.chatGPTSession)
                throw RewriteFailure.rejectedCredentials(.chatGPT)
            }
            switch refusal.status {
            case 429:
                throw RewriteFailure.rateLimited(.chatGPT)
            case 500...599:
                throw RewriteFailure.trouble(.chatGPT)
            default:
                throw RewriteFailure.rejectedCredentials(.chatGPT)
            }
        } catch {
            throw RewriteHTTP.failure(from: error)
        }

        var email = session.email
        var idToken = session.idToken
        if let fresh = tokens.idToken {
            guard let token = try? IDToken.decode(fresh),
                  (try? token.checkClaims(
                      issuer: ChatGPTOAuth.issuer,
                      clientID: session.clientID,
                      nonce: nil,
                      now: now()
                  )) != nil,
                  token.subject == session.subject
            else {
                try? credentials.remove(CredentialAccount.chatGPTSession)
                throw RewriteFailure.rejectedCredentials(.chatGPT)
            }
            email = token.email ?? email
            idToken = fresh
        }
        let refreshed = ChatGPTSession(
            clientID: session.clientID,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? session.refreshToken,
            expiresAt: now().addingTimeInterval(tokens.expiresIn),
            email: email,
            subject: session.subject,
            idToken: idToken,
            scopes: tokens.scopes
        )
        try save(refreshed)
        return refreshed
    }

    // MARK: - signing out

    /// revokes the session at openai, then forgets the tokens here. the
    /// registration and the host id stay, so signing back in is the same
    /// app to openai. false if openai never confirmed the revocation — the
    /// tokens are gone from this mac either way, and the user can still
    /// disconnect the app in chatgpt settings.
    @discardableResult
    func signOut() async -> Bool {
        pendingSignIn?.cancel()
        pendingSignIn = nil
        refreshing?.cancel()
        refreshing = nil
        guard let session = storedSession() else {
            return true
        }
        var revoked = false
        for attempt in 0..<2 where !revoked {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(300))
            }
            let response = try? await send(
                ChatGPTOAuth.revoke(
                    refreshToken: session.refreshToken,
                    clientID: session.clientID
                )
            ).1
            if response?.statusCode == 200 {
                revoked = true
            } else if let status = response?.statusCode, status < 500 {
                break
            }
        }
        try? credentials.remove(CredentialAccount.chatGPTSession)
        return revoked
    }

    // MARK: -

    private func save(_ session: ChatGPTSession) throws {
        try credentials.setEncoded(session, for: CredentialAccount.chatGPTSession)
    }

    private static func signInFailure(from error: any Error) -> SignInFailure {
        if let failure = error as? SignInFailure {
            return failure
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .cancelled
        }
        return .network
    }
}
