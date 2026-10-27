import XCTest

final class RewriteChatGPTOAuthTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    private func form(_ request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var pairs: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            pairs[parts[0].removingPercentEncoding!] = parts.count > 1
                ? parts[1].removingPercentEncoding!
                : ""
        }
        return pairs
    }

    // MARK: - the authorize url

    /// the first sign-in registers the app: the dynamic client, the app's
    /// name for the consent page, and this mac's host id.
    func testAFirstSignInRegisters() {
        let url = ChatGPTOAuth.authorizeURL(
            clientID: nil,
            hostID: "urn:uuid:1b4e28ba-2fa1-41d2-883f-0016d3cca427",
            redirectURI: "http://127.0.0.1:51423/auth/callback",
            state: "the-state",
            nonce: "the-nonce",
            challenge: "the-challenge",
            loginHint: nil
        )
        let items = query(url)

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/api/accounts/authorize")
        XCTAssertEqual(items, [
            "client_id": "dynamic_agent_client",
            "response_type": "code",
            "redirect_uri": "http://127.0.0.1:51423/auth/callback",
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": "https://api.openai.com/v1",
            "state": "the-state",
            "nonce": "the-nonce",
            "code_challenge_method": "S256",
            "code_challenge": "the-challenge",
            "ext_agent_host_id": "urn:uuid:1b4e28ba-2fa1-41d2-883f-0016d3cca427",
            "agent_name_hint": "Andrew Dictate",
        ])
    }

    /// signing back in is the same app: the issued client, no name hint,
    /// the verified email as a hint. never the old id token in a url.
    func testAReturningSignInReusesTheClient() {
        let url = ChatGPTOAuth.authorizeURL(
            clientID: "oaiapp_abc123",
            hostID: "urn:uuid:x",
            redirectURI: "http://127.0.0.1:6000/auth/callback",
            state: "s",
            nonce: "n",
            challenge: "c",
            loginHint: "jass+dictate@example.com"
        )
        let items = query(url)

        XCTAssertEqual(items["client_id"], "oaiapp_abc123")
        XCTAssertNil(items["agent_name_hint"])
        XCTAssertNil(items["id_token_hint"])
        XCTAssertNil(items["prompt"])
        XCTAssertEqual(items["login_hint"], "jass+dictate@example.com")
        XCTAssertEqual(items["ext_agent_host_id"], "urn:uuid:x")
        // a bare + would arrive as a space.
        XCTAssertTrue(url.absoluteString.contains("login_hint=jass%2Bdictate%40example.com"))
        XCTAssertTrue(url.absoluteString.contains("scope=openid%20profile"))
    }

    func testLeavingThePlanUntickedAsksAgainNextTime() {
        let url = ChatGPTOAuth.authorizeURL(
            clientID: "oaiapp_abc",
            hostID: "h",
            redirectURI: "r",
            state: "s",
            nonce: "n",
            challenge: "c",
            loginHint: nil,
            askAgain: true
        )

        XCTAssertEqual(query(url)["prompt"], "consent")
    }

    /// openai matches the redirect exactly, bar the port.
    func testTheRedirectIsLoopbackIPv4OnTheAuthCallbackPath() {
        XCTAssertEqual(
            ChatGPTOAuth.redirectURI(port: 1455),
            "http://127.0.0.1:1455/auth/callback"
        )
    }

    func testTheHostIDIsAUUIDURN() {
        let id = ChatGPTOAuth.newHostID()

        XCTAssertTrue(id.hasPrefix("urn:uuid:"))
        XCTAssertNotNil(UUID(uuidString: String(id.dropFirst("urn:uuid:".count))))
        XCTAssertNotEqual(id, ChatGPTOAuth.newHostID())
    }

    // MARK: - the redirect

    private func items(_ pairs: [String: String]) -> [URLQueryItem] {
        pairs.map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    func testANewRegistrationBringsItsClient() throws {
        let result = try ChatGPTOAuth.callback(
            items(["code": "abc", "state": "s", "client_id": "oaiapp_new"]),
            savedClientID: nil
        )

        XCTAssertEqual(result.code, "abc")
        XCTAssertEqual(result.clientID, "oaiapp_new")
    }

    /// a returning sign-in may leave the client out.
    func testAReturningSignInKeepsTheSavedClient() throws {
        let result = try ChatGPTOAuth.callback(
            items(["code": "abc", "state": "s"]),
            savedClientID: "oaiapp_saved"
        )

        XCTAssertEqual(result.clientID, "oaiapp_saved")
    }

    func testRedirectsThatCannotBeUsed() {
        let cases: [([String: String], String?, SignInFailure)] = [
            (["error": "access_denied", "state": "s"], nil, .declined),
            (["error": "server_error"], nil, .refused("server_error")),
            // a first sign-in with no issued client is not finished.
            (["code": "abc"], nil, .incomplete),
            // the entry point is never the client to exchange with.
            (["code": "abc", "client_id": "dynamic_agent_client"], nil, .incomplete),
            // nor may a returning sign-in switch clients under us.
            (["code": "abc", "client_id": "oaiapp_other"], "oaiapp_saved", .incomplete),
            (["client_id": "oaiapp_new"], nil, .incomplete),
        ]
        for (pairs, saved, expected) in cases {
            XCTAssertThrowsError(
                try ChatGPTOAuth.callback(items(pairs), savedClientID: saved),
                "\(pairs)"
            ) {
                XCTAssertEqual($0 as? SignInFailure, expected, "\(pairs)")
            }
        }
    }

    // MARK: - the token endpoint

    func testTheCodeExchange() {
        let request = ChatGPTOAuth.codeExchange(
            code: "the-code",
            clientID: "oaiapp_1",
            verifier: "the-verifier",
            redirectURI: "http://127.0.0.1:5000/auth/callback"
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://auth.openai.com/api/accounts/oauth/token"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        XCTAssertEqual(form(request), [
            "grant_type": "authorization_code",
            "client_id": "oaiapp_1",
            "code": "the-code",
            "code_verifier": "the-verifier",
            "redirect_uri": "http://127.0.0.1:5000/auth/callback",
            "resource": "https://api.openai.com/v1",
        ])
    }

    /// no scope on a refresh: leaving it out keeps the grant.
    func testTheRefresh() {
        XCTAssertEqual(
            form(ChatGPTOAuth.refresh(refreshToken: "rt", clientID: "oaiapp_1")),
            [
                "grant_type": "refresh_token",
                "client_id": "oaiapp_1",
                "refresh_token": "rt",
                "resource": "https://api.openai.com/v1",
            ]
        )
    }

    func testTheRevocation() {
        let request = ChatGPTOAuth.revoke(refreshToken: "rt", clientID: "oaiapp_1")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://auth.openai.com/api/accounts/oauth/revoke"
        )
        XCTAssertEqual(form(request), [
            "token": "rt",
            "token_type_hint": "refresh_token",
            "client_id": "oaiapp_1",
        ])
    }

    func testATokenResponseIsRead() throws {
        let body = Data(#"""
        {"access_token":"at","refresh_token":"rt","id_token":"it","token_type":"Bearer",
         "expires_in":3600,"scope":"openid email chatgpt.tokens.use.direct","earliest_refresh_at":1790032532}
        """#.utf8)

        let tokens = try ChatGPTOAuth.tokens(status: 200, body: body)

        XCTAssertEqual(tokens, ChatGPTOAuth.Tokens(
            accessToken: "at",
            refreshToken: "rt",
            idToken: "it",
            expiresIn: 3600,
            scopes: ["openid", "email", "chatgpt.tokens.use.direct"]
        ))
    }

    /// a refresh may leave scope out, meaning unchanged.
    func testAMissingScopeKeepsThePreviousGrant() throws {
        let body = Data(#"{"access_token":"at","refresh_token":"rt2","token_type":"bearer","expires_in":3600}"#.utf8)

        let tokens = try ChatGPTOAuth.tokens(status: 200, body: body, previousScopes: ["a", "b"])

        XCTAssertEqual(tokens.scopes, ["a", "b"])
        XCTAssertNil(tokens.idToken)
    }

    func testRefusalsSayWhetherOnlyASignInHelps() {
        let spent = Data(#"{"error":"refresh_token_reused","error_description":"…"}"#.utf8)
        XCTAssertThrowsError(try ChatGPTOAuth.tokens(status: 400, body: spent)) {
            let refusal = $0 as? ChatGPTOAuth.Refusal
            XCTAssertEqual(refusal?.code, "refresh_token_reused")
            XCTAssertEqual(refusal?.needsSignIn, true)
        }
        XCTAssertThrowsError(try ChatGPTOAuth.tokens(status: 503, body: Data())) {
            XCTAssertEqual(($0 as? ChatGPTOAuth.Refusal)?.needsSignIn, false)
        }
        // a 200 that is not a token response is not a token response.
        XCTAssertThrowsError(
            try ChatGPTOAuth.tokens(status: 200, body: Data(#"{"access_token":"at"}"#.utf8))
        )
    }

    // MARK: - the id token

    func testAGoodIDTokenChecksOut() throws {
        let signer = try TestSigner()
        let jwt = try signer.idToken([
            "iss": "https://auth.openai.com",
            "aud": "oaiapp_1",
            "sub": "user-1",
            "email": "jass@example.com",
            "nonce": "n1",
            "exp": Date().timeIntervalSince1970 + 3600,
            "iat": Date().timeIntervalSince1970,
        ])

        let token = try IDToken.decode(jwt)
        XCTAssertNoThrow(try token.checkSignature(jwks: signer.jwks))
        XCTAssertNoThrow(
            try token.checkClaims(
                issuer: "https://auth.openai.com",
                clientID: "oaiapp_1",
                nonce: "n1",
                now: Date()
            )
        )
        XCTAssertEqual(token.email, "jass@example.com")
        XCTAssertEqual(token.subject, "user-1")
    }

    func testABadIDTokenDoesNot() throws {
        let signer = try TestSigner()
        let stranger = try TestSigner()
        let now = Date()
        let claims: [String: Any] = [
            "iss": "https://auth.openai.com",
            "aud": "oaiapp_1",
            "sub": "user-1",
            "nonce": "n1",
            "exp": now.timeIntervalSince1970 + 3600,
        ]
        func check(
            _ changes: [String: Any],
            nonce: String? = "n1",
            signedBy key: TestSigner? = nil
        ) throws {
            let merged = claims.merging(changes) { _, new in new }
            let token = try IDToken.decode((key ?? signer).idToken(merged))
            try token.checkSignature(jwks: signer.jwks)
            try token.checkClaims(
                issuer: "https://auth.openai.com",
                clientID: "oaiapp_1",
                nonce: nonce,
                now: now
            )
        }

        XCTAssertThrowsError(try check([:], signedBy: stranger)) {
            XCTAssertEqual($0 as? IDToken.Problem, .badSignature)
        }
        XCTAssertThrowsError(try check(["iss": "https://evil.example"])) {
            XCTAssertEqual($0 as? IDToken.Problem, .wrongIssuer)
        }
        XCTAssertThrowsError(try check(["aud": "oaiapp_other"])) {
            XCTAssertEqual($0 as? IDToken.Problem, .wrongAudience)
        }
        XCTAssertThrowsError(try check(["aud": ["oaiapp_1", "oaiapp_other"]])) {
            XCTAssertEqual($0 as? IDToken.Problem, .wrongAudience)
        }
        XCTAssertThrowsError(try check(["exp": now.timeIntervalSince1970 - 60])) {
            XCTAssertEqual($0 as? IDToken.Problem, .expired)
        }
        XCTAssertThrowsError(try check(["nonce": "replayed"])) {
            XCTAssertEqual($0 as? IDToken.Problem, .wrongNonce)
        }
        // a refreshed token answers no request of ours, so no nonce check.
        XCTAssertNoThrow(try check(["nonce": "anything"], nonce: nil))
        XCTAssertThrowsError(try IDToken.decode("not.a.jwt")) {
            XCTAssertEqual($0 as? IDToken.Problem, .malformed)
        }
    }

    /// `alg: none` is the oldest trick there is.
    func testOnlyRS256IsAccepted() throws {
        let signer = try TestSigner()
        let header = Data(#"{"alg":"none","kid":"test"}"#.utf8).base64URLEncodedString
        let payload = Data(#"{"iss":"https://auth.openai.com","aud":"a","sub":"s","exp":9999999999}"#.utf8)
            .base64URLEncodedString

        let token = try IDToken.decode("\(header).\(payload).")

        XCTAssertThrowsError(try token.checkSignature(jwks: signer.jwks)) {
            XCTAssertEqual($0 as? IDToken.Problem, .unsupportedAlgorithm)
        }
    }

    /// against openai's real published key: the DER the jwk becomes has
    /// to be one Security accepts.
    func testOpenAIsPublishedKeyBecomesASecKey() throws {
        let n = "zc-mA_FoZ5fu_xalTkhlF4xBN07TrkOSaZy9U-gNzbQJ4dxy5CDzxR6-qYKhJGYVBORyqgGLZBCjrrjp57k1Wi-M413neq2-cq4erDpdUA82dJn4tBL_YFH9W845Duna8UDdGI7OODRj-LtcCk6T1CgHdXypsXXMI55xb-WlZ8rwWuMcw2XylEyC8_MDLhmDXP0Y7BA2_24A2NtxHu0eRQyBPpWpZdh0kjbbAzoUBocHQnMid1kjhcDkswdl3lrNouEf2L29GU6k7p6p5OIQ7JR9ybgvSIMlE8v9_Y1cgFsdlWcvu5Tk9-xR5DoOKYyxHcIdzlIPIMnwYJXM-OS5OQ"

        let key = IDToken.rsaPublicKey(
            modulus: try XCTUnwrap(Data(base64URLEncoded: n)),
            exponent: try XCTUnwrap(Data(base64URLEncoded: "AQAB"))
        )

        XCTAssertNotNil(key)
        XCTAssertEqual(key.map(SecKeyGetBlockSize), 256)
    }

    func testDERLengths() {
        XCTAssertEqual(DER.length(5), Data([0x05]))
        XCTAssertEqual(DER.length(0x80), Data([0x81, 0x80]))
        XCTAssertEqual(DER.length(0x0102), Data([0x82, 0x01, 0x02]))
        // a high bit gets a leading zero so the integer stays positive.
        XCTAssertEqual(DER.integer(Data([0xFF])), Data([0x02, 0x02, 0x00, 0xFF]))
        XCTAssertEqual(DER.integer(Data([0x00, 0x01])), Data([0x02, 0x01, 0x01]))
    }
}
