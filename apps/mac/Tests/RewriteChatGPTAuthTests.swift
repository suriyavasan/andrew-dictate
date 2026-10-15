import CryptoKit
import Security
import XCTest

final class RewriteChatGPTAuthTests: XCTestCase {
    private var credentials: InMemoryCredentialStore!
    private var browser: FakeBrowser!
    private var signer: TestSigner!
    private var clock: SignInClock!

    override func setUpWithError() throws {
        credentials = InMemoryCredentialStore()
        browser = FakeBrowser()
        signer = try TestSigner()
        clock = SignInClock(Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// openai's side of a sign-in: the token endpoint and the keys, with
    /// the id token made for whatever attempt the browser was sent on.
    private func openAI(
        subject: String = "user-1",
        scope: String = ChatGPTOAuth.scope,
        nonce: (@Sendable (FakeBrowser) -> String?)? = nil
    ) -> FakeNetwork {
        let browser = browser!
        let signer = signer!
        let clock = clock!
        return FakeNetwork { request in
            switch request.url?.path {
            case "/api/accounts/oauth/token":
                let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                let clientID = form.contains("client_id=oaiapp_new") ? "oaiapp_new" : "?"
                let idToken = try signer.idToken([
                    "iss": "https://auth.openai.com",
                    "aud": clientID,
                    "sub": subject,
                    "email": "jass@example.com",
                    "nonce": (nonce ?? { $0.query("nonce") })(browser) ?? "",
                    "exp": clock.now.timeIntervalSince1970 + 3600,
                    "iat": clock.now.timeIntervalSince1970,
                ])
                let body: [String: Any] = [
                    "access_token": "at-1",
                    "refresh_token": "rt-1",
                    "id_token": idToken,
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "scope": scope,
                ]
                return (200, try JSONSerialization.data(withJSONObject: body))
            case "/.well-known/jwks.json":
                return (200, signer.jwks)
            default:
                return (404, Data())
            }
        }
    }

    /// the browser comes back with this attempt's state, a code, and —
    /// on a first sign-in — the client openai just issued.
    private func listen(
        _ reply: [String: String] = ["code": "the-code", "client_id": "oaiapp_new"]
    ) -> CallbackListen {
        let browser = browser!
        return { path, state in
            XCTAssertEqual(path, "/auth/callback")
            return FakeReceiver(port: 4321) {
                XCTAssertEqual(browser.query("state"), state)
                return [URLQueryItem(name: "state", value: state)]
                    + reply.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
        }
    }

    private func auth(
        network: FakeNetwork,
        listen: CallbackListen? = nil
    ) -> ChatGPTAuth {
        let clock = clock!
        return ChatGPTAuth(
            credentials: credentials,
            openURL: browser.openURL,
            listen: listen ?? self.listen(),
            send: network.send,
            now: { clock.now }
        )
    }

    // MARK: - signing in

    func testASignInRegistersVerifiesAndSaves() async throws {
        let network = openAI()
        let auth = auth(network: network)

        let session = try await auth.signIn()

        XCTAssertEqual(session.clientID, "oaiapp_new")
        XCTAssertEqual(session.accessToken, "at-1")
        XCTAssertEqual(session.refreshToken, "rt-1")
        XCTAssertEqual(session.email, "jass@example.com")
        XCTAssertEqual(session.subject, "user-1")
        XCTAssertEqual(session.expiresAt, clock.now.addingTimeInterval(3600))
        XCTAssertTrue(session.canUsePlan)
        XCTAssertEqual(auth.storedSession(), session)
        XCTAssertEqual(
            try credentials.decoded(ChatGPTRegistration.self, for: CredentialAccount.chatGPTRegistration),
            ChatGPTRegistration(clientID: "oaiapp_new", subject: "user-1", email: "jass@example.com")
        )
        // the redirect went to this receiver's port, and the host id sent is the one kept.
        XCTAssertEqual(browser.query("redirect_uri"), "http://127.0.0.1:4321/auth/callback")
        XCTAssertEqual(
            browser.query("ext_agent_host_id"),
            try credentials.string(for: CredentialAccount.chatGPTHost)
        )
    }

    /// the verifier sent to the token endpoint is the one whose hash the
    /// browser carried.
    func testTheExchangeProvesTheChallenge() async throws {
        let network = openAI()

        try await auth(network: network).signIn()

        let exchange = try XCTUnwrap(network.requests.first { $0.url?.path == "/api/accounts/oauth/token" })
        let form = String(decoding: exchange.httpBody ?? Data(), as: UTF8.self)
        let verifier = try XCTUnwrap(
            form.split(separator: "&")
                .first { $0.hasPrefix("code_verifier=") }?
                .dropFirst("code_verifier=".count)
        )
        XCTAssertEqual(PKCE.challenge(for: String(verifier)), browser.query("code_challenge"))
        XCTAssertTrue(form.contains("code=the-code"))
        XCTAssertTrue(form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A4321%2Fauth%2Fcallback"))
    }

    /// signing in again is the same app to openai: same client, same host.
    func testSigningInAgainReusesTheRegistration() async throws {
        let auth = auth(network: openAI())
        try await auth.signIn()
        let firstHost = browser.query("ext_agent_host_id")

        try await auth.signIn()

        XCTAssertEqual(browser.query("client_id"), "oaiapp_new")
        XCTAssertNil(browser.query("agent_name_hint"))
        XCTAssertEqual(browser.query("login_hint"), "jass@example.com")
        XCTAssertEqual(browser.query("ext_agent_host_id"), firstHost)
        XCTAssertEqual(browser.opened.count, 2)
    }

    func testAnotherAccountOnTheSameRegistrationIsRefused() async throws {
        try credentials.setEncoded(
            ChatGPTRegistration(clientID: "oaiapp_new", subject: "someone-else", email: nil),
            for: CredentialAccount.chatGPTRegistration
        )
        let auth = auth(network: openAI(), listen: listen(["code": "the-code"]))

        await assertSignIn(auth, failsWith: .differentAccount)
        XCTAssertNil(auth.storedSession())
    }

    /// signed in but the plan left unticked: kept, so settings can say
    /// who, but it cannot rewrite, and the next sign-in asks again.
    func testAPlanLeftUntickedIsSaidSo() async throws {
        let auth = auth(network: openAI(scope: "openid profile email offline_access"))

        await assertSignIn(auth, failsWith: .planNotShared)

        XCTAssertEqual(auth.storedSession()?.canUsePlan, false)
        _ = try? await auth.signIn()
        XCTAssertEqual(browser.query("prompt"), "consent")
    }

    func testAReplayedIDTokenIsRefused() async throws {
        let auth = auth(network: openAI(nonce: { _ in "someone-elses-nonce" }))

        await assertSignIn(auth, failsWith: .unverifiedIdentity)
        XCTAssertNil(auth.storedSession())
    }

    func testDecliningInTheBrowserSavesNothing() async throws {
        let network = openAI()
        let auth = auth(network: network, listen: listen(["error": "access_denied"]))

        await assertSignIn(auth, failsWith: .declined)

        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertEqual(credentials.accounts, [CredentialAccount.chatGPTHost])
    }

    func testNoBrowserIsSaidSo() async throws {
        browser.succeeds = false

        await assertSignIn(auth(network: openAI()), failsWith: .browserUnavailable)
    }

    /// the code can expire after openai registered the app; the client id
    /// is kept so the retry does not register a second one.
    func testTheIssuedClientIsKeptEvenIfTheExchangeFails() async throws {
        let network = FakeNetwork { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let auth = auth(network: network)

        await assertSignIn(auth, failsWith: .refused("invalid_grant"))

        XCTAssertEqual(
            try credentials.decoded(ChatGPTRegistration.self, for: CredentialAccount.chatGPTRegistration)?.clientID,
            "oaiapp_new"
        )
    }

    private func assertSignIn(
        _ auth: ChatGPTAuth,
        failsWith expected: SignInFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await auth.signIn()
            XCTFail("signed in", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SignInFailure, expected, file: file, line: line)
        }
    }

    // MARK: - staying signed in

    private func saveSession(expiresIn seconds: TimeInterval, scopes: [String]? = nil) throws {
        try credentials.setEncoded(
            ChatGPTSession(
                clientID: "oaiapp_1",
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expiresAt: clock.now.addingTimeInterval(seconds),
                email: "jass@example.com",
                subject: "user-1",
                idToken: "old-id",
                scopes: scopes ?? ChatGPTOAuth.scope.split(separator: " ").map(String.init)
            ),
            for: CredentialAccount.chatGPTSession
        )
        try credentials.setEncoded(
            ChatGPTRegistration(clientID: "oaiapp_1", subject: "user-1", email: "jass@example.com"),
            for: CredentialAccount.chatGPTRegistration
        )
    }

    private func refreshingNetwork(delay: Duration = .zero) -> FakeNetwork {
        FakeNetwork { request in
            XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
            try await Task.sleep(for: delay)
            return (200, Data(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#.utf8))
        }
    }

    func testAFreshSessionIsUsedAsIs() async throws {
        try saveSession(expiresIn: 600)
        let network = refreshingNetwork()

        let session = try await auth(network: network).validSession()

        XCTAssertEqual(session.accessToken, "old-access")
        XCTAssertTrue(network.requests.isEmpty)
    }

    /// two minutes out, it is refreshed, and the rotated refresh token is
    /// kept with the new access token.
    func testANearlyExpiredSessionIsRefreshed() async throws {
        try saveSession(expiresIn: 90)
        let network = refreshingNetwork()
        let auth = auth(network: network)

        let session = try await auth.validSession()

        XCTAssertEqual(session.accessToken, "new-access")
        XCTAssertEqual(session.refreshToken, "new-refresh")
        XCTAssertEqual(session.expiresAt, clock.now.addingTimeInterval(3600))
        XCTAssertEqual(session.email, "jass@example.com")
        XCTAssertTrue(session.canUsePlan)
        XCTAssertEqual(auth.storedSession(), session)
    }

    /// a refresh token used twice is a revoked session: five rewrites at
    /// once share one refresh.
    func testConcurrentCallersShareOneRefresh() async throws {
        try saveSession(expiresIn: 30)
        let network = refreshingNetwork(delay: .milliseconds(100))
        let auth = auth(network: network)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await auth.validSession().accessToken
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(tokens, Array(repeating: "new-access", count: 5))
        XCTAssertEqual(network.requests.count, 1)
    }

    /// a spent refresh token means sign in again; the registration stays,
    /// so that sign-in is the same app.
    func testASpentRefreshTokenAsksForASignIn() async throws {
        try saveSession(expiresIn: 0)
        let network = FakeNetwork { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let auth = auth(network: network)

        do {
            _ = try await auth.validSession()
            XCTFail("refreshed")
        } catch {
            XCTAssertEqual(error as? RewriteFailure, .rejectedCredentials(.chatGPT))
        }
        XCTAssertNil(auth.storedSession())
        XCTAssertNotNil(try credentials.data(for: CredentialAccount.chatGPTRegistration))
    }

    /// a dropped wi-fi is not a revoked session: nothing is thrown away.
    func testAnOfflineRefreshKeepsTheSession() async throws {
        try saveSession(expiresIn: 0)
        let network = FakeNetwork { _ in throw URLError(.notConnectedToInternet) }
        let auth = auth(network: network)

        do {
            _ = try await auth.validSession()
            XCTFail("refreshed")
        } catch {
            XCTAssertEqual(error as? RewriteFailure, .network)
        }
        XCTAssertNotNil(auth.storedSession())
    }

    func testNoSessionIsNotSignedIn() async {
        do {
            _ = try await auth(network: refreshingNetwork()).validSession()
            XCTFail("signed in")
        } catch {
            XCTAssertEqual(error as? RewriteFailure, .notSignedIn(.chatGPT))
        }
    }

    // MARK: - signing out

    func testSigningOutRevokesAndForgetsTheTokensOnly() async throws {
        try saveSession(expiresIn: 600)
        let network = FakeNetwork { request in
            XCTAssertEqual(request.url?.path, "/api/accounts/oauth/revoke")
            return (200, Data())
        }
        let auth = auth(network: network)
        _ = try await auth.hostID()

        let revoked = await auth.signOut()

        XCTAssertTrue(revoked)
        XCTAssertNil(auth.storedSession())
        XCTAssertEqual(
            credentials.accounts.sorted(),
            [CredentialAccount.chatGPTHost, CredentialAccount.chatGPTRegistration].sorted()
        )
        let form = String(decoding: network.requests.first?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(form.contains("token=old-refresh"))
        XCTAssertTrue(form.contains("client_id=oaiapp_1"))
    }

    /// openai down: tried twice, then signed out here anyway, and said so.
    func testAnUnconfirmedRevocationStillSignsOut() async throws {
        try saveSession(expiresIn: 600)
        let network = FakeNetwork { _ in (503, Data()) }
        let auth = auth(network: network)

        let revoked = await auth.signOut()

        XCTAssertFalse(revoked)
        XCTAssertEqual(network.requests.count, 2)
        XCTAssertNil(auth.storedSession())
    }

    // MARK: - the client

    func testTheClientStreamsARewrite() async throws {
        try saveSession(expiresIn: 600)
        let opener = FakeOpener(status: 200, lines: [
            "event: response.created",
            #"data: {"type":"response.created","response":{}}"#,
            "",
            "event: response.output_text.delta",
            #"data: {"type":"response.output_text.delta","delta":"dear "}"#,
            "",
            #"data: {"type":"response.output_text.delta","delta":"team,"}"#,
            "",
            #"data: {"type":"response.completed","response":{}}"#,
            "",
        ])
        let client = ChatGPTClient(auth: auth(network: refreshingNetwork()), open: opener.open)

        let text = try await client.rewrite(
            RewritePrompt(instructions: "be polite", text: "hey"),
            model: "gpt-6-luna"
        )

        XCTAssertEqual(text, "dear team,")
        let request = try XCTUnwrap(opener.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "be polite")
        XCTAssertEqual(body["input"] as? [[String: String]], [["role": "user", "content": "hey"]])
        XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "none"])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["max_output_tokens"])
    }

    func testThePlansLimitBeforeTheStreamIsSaidSo() async throws {
        try saveSession(expiresIn: 600)
        let opener = FakeOpener(status: 429, lines: [
            #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"…"}}"#,
        ])
        let client = ChatGPTClient(auth: auth(network: refreshingNetwork()), open: opener.open)

        do {
            _ = try await client.rewrite(RewritePrompt(instructions: "", text: "x"), model: "m")
            XCTFail("rewrote")
        } catch {
            XCTAssertEqual(error as? RewriteFailure, .planLimitReached)
            XCTAssertEqual((error as? RewriteFailure)?.pillReason, "chatgpt plan limit reached")
        }
    }

    func testASessionWithoutThePlanCannotRewrite() async throws {
        try saveSession(expiresIn: 600, scopes: ["openid", "email"])
        let opener = FakeOpener(status: 200, lines: [])
        let client = ChatGPTClient(auth: auth(network: refreshingNetwork()), open: opener.open)

        do {
            _ = try await client.rewrite(RewritePrompt(instructions: "", text: "x"), model: "m")
            XCTFail("rewrote")
        } catch {
            XCTAssertEqual(error as? RewriteFailure, .notSignedIn(.chatGPT))
        }
        XCTAssertTrue(opener.requests.isEmpty)
    }

    func testThePlansModelsAreListedWithTheToken() async throws {
        try saveSession(expiresIn: 600)
        let network = FakeNetwork { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
            return (200, Data(#"""
            {"models":[
              {"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list"},
              {"slug":"internal","display_name":"Hidden","visibility":"hide"},
              {"slug":"gpt-6-luna","display_name":"GPT-6 Luna","visibility":"list"}
            ]}
            """#.utf8))
        }

        let models = try await ChatGPTClient.listModels(auth: auth(network: network), send: network.send)

        XCTAssertEqual(models, [
            ChatGPTResponses.Model(slug: "gpt-6.1-sol", displayName: "GPT-6.1 Sol"),
            ChatGPTResponses.Model(slug: "gpt-6-luna", displayName: "GPT-6 Luna"),
        ])
    }
}

// MARK: - fakes the rewrite tests share

/// the network, answered by a closure, with every request kept.
final class FakeNetwork: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    var send: RewriteHTTP.Send {
        { [self] request in
            lock.withLock { recorded.append(request) }
            let (status, body) = try await handler(request)
            return (body, http(status, request.url!))
        }
    }
}

/// a streamed response with these lines.
final class FakeOpener: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let status: Int
    private let lines: [String]

    init(status: Int, lines: [String]) {
        self.status = status
        self.lines = lines
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    var open: RewriteHTTP.Open {
        { [self] request in
            lock.withLock { recorded.append(request) }
            let lines = self.lines
            let stream = AsyncThrowingStream<String, any Error> { continuation in
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            return (http(status, request.url!), stream)
        }
    }
}

func http(_ status: Int, _ url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

/// the browser: remembers what it was asked to open.
final class FakeBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var fails = false

    var succeeds: Bool {
        get { lock.withLock { !fails } }
        set { lock.withLock { fails = !newValue } }
    }

    var opened: [URL] {
        lock.withLock { urls }
    }

    /// a query item of the last url opened.
    func query(_ name: String) -> String? {
        opened.last.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == name }?
                .value
        }
    }

    var openURL: BrowserSignIn.OpenURL {
        { [self] url in
            lock.withLock {
                urls.append(url)
                return !fails
            }
        }
    }
}

/// the loopback, answering with whatever the test says the browser sent.
struct FakeReceiver: CallbackReceiving {
    let port: UInt16
    let reply: @Sendable () async throws -> [URLQueryItem]

    func callback() async throws -> [URLQueryItem] {
        try await reply()
    }

    func cancel() {}
}

final class SignInClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ now: Date) {
        current = now
    }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// an RSA key that signs id tokens the way openai does, and publishes
/// itself as a jwks document.
struct TestSigner: @unchecked Sendable {
    let privateKey: SecKey

    init() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as any Error
        }
        privateKey = key
    }

    var jwks: Data {
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let der = [UInt8](SecKeyCopyExternalRepresentation(publicKey, nil)! as Data)
        var index = 0
        let sequence = Self.read(der, &index)
        index = 0
        let modulus = Data(Self.read(sequence, &index).drop { $0 == 0 })
        let exponent = Data(Self.read(sequence, &index))
        let document: [String: Any] = [
            "keys": [[
                "kty": "RSA",
                "kid": "test",
                "use": "sig",
                "alg": "RS256",
                "n": modulus.base64URLEncodedString,
                "e": exponent.base64URLEncodedString,
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: document)
    }

    func idToken(_ claims: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(
            withJSONObject: ["alg": "RS256", "kid": "test", "typ": "JWT"]
        )
        let payload = try JSONSerialization.data(withJSONObject: claims)
        let input = "\(header.base64URLEncodedString).\(payload.base64URLEncodedString)"
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(input.utf8) as CFData,
            &error
        ) else {
            throw error!.takeRetainedValue() as any Error
        }
        return "\(input).\((signature as Data).base64URLEncodedString)"
    }

    /// one DER tag-length-value, returning the value.
    private static func read(_ bytes: [UInt8], _ index: inout Int) -> [UInt8] {
        index += 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        defer { index += length }
        return Array(bytes[index..<index + length])
    }
}
