import XCTest

final class RewriteOpenAICompatibleTests: XCTestCase {
    private let prompt = RewritePrompt(
        instructions: "rewrite this as a polite email",
        text: "send me the report"
    )

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - the request

    func testEachProviderHasItsOwnEndpoint() {
        let urls = [RewriteProvider.openAI, .openRouter, .gemini].map {
            OpenAICompatibleClient.request(
                provider: $0,
                key: "k",
                prompt: prompt,
                model: "m"
            )?.url?.absoluteString
        }

        XCTAssertEqual(urls, [
            "https://api.openai.com/v1/chat/completions",
            "https://openrouter.ai/api/v1/chat/completions",
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        ])
    }

    /// chatgpt and apple do not speak chat completions.
    func testChatGPTAndAppleHaveNoChatCompletionsRequest() {
        XCTAssertNil(
            OpenAICompatibleClient.request(provider: .chatGPT, key: "k", prompt: prompt, model: "m")
        )
        XCTAssertNil(
            OpenAICompatibleClient.request(provider: .apple, key: "k", prompt: prompt, model: "m")
        )
    }

    func testTheRequestCarriesTheStyleThenTheText() throws {
        let request = OpenAICompatibleClient.request(
            provider: .openAI,
            key: "sk-test",
            prompt: prompt,
            model: "gpt-6-luna"
        )
        let json = try body(request)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])

        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(json["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(messages, [
            ["role": "system", "content": "rewrite this as a polite email"],
            ["role": "user", "content": "send me the report"],
        ])
        XCTAssertEqual(json["reasoning_effort"] as? String, "none")
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["max_tokens"])
    }

    /// a short timeout, and nothing kept between requests.
    func testTheRequestIsQuickAndForgetful() {
        let request = OpenAICompatibleClient.request(
            provider: .gemini,
            key: "k",
            prompt: prompt,
            model: "gemini-3.5-flash-lite"
        )

        XCTAssertEqual(request?.timeoutInterval, 20)
        XCTAssertEqual(request?.httpShouldHandleCookies, false)
        XCTAssertEqual(request?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "andrew-dictate")
    }

    func testAPickedModelIsNotToldAnEffort() throws {
        let json = try body(
            OpenAICompatibleClient.request(
                provider: .openRouter,
                key: "k",
                prompt: prompt,
                model: "anthropic/claude-haiku-5.5"
            )
        )

        XCTAssertNil(json["reasoning_effort"])
    }

    /// openrouter shows the app's name on the user's activity page; the
    /// others are told nothing.
    func testOnlyOpenRouterGetsAttribution() {
        let openRouter = OpenAICompatibleClient.request(
            provider: .openRouter, key: "k", prompt: prompt, model: "m"
        )
        let openAI = OpenAICompatibleClient.request(
            provider: .openAI, key: "k", prompt: prompt, model: "m"
        )

        XCTAssertEqual(
            openRouter?.value(forHTTPHeaderField: "HTTP-Referer"),
            "https://dictate.jass.gg"
        )
        XCTAssertEqual(openRouter?.value(forHTTPHeaderField: "X-Title"), "Andrew Dictate")
        XCTAssertNil(openAI?.value(forHTTPHeaderField: "HTTP-Referer"))
        XCTAssertNil(openAI?.value(forHTTPHeaderField: "X-Title"))
    }

    // MARK: - the answer

    func testTheAnswerIsTheFirstChoiceTrimmed() throws {
        let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"  hi there.\n"}}]}"#.utf8)

        XCTAssertEqual(
            try OpenAICompatibleClient.answer(provider: .openAI, status: 200, body: body),
            "hi there."
        )
    }

    func testAnEmptyAnswerIsAFailure() {
        for body in [
            #"{"choices":[{"message":{"content":"   "}}]}"#,
            #"{"choices":[{"message":{"content":null}}]}"#,
            #"{"choices":[]}"#,
        ] {
            XCTAssertThrowsError(
                try OpenAICompatibleClient.answer(
                    provider: .openAI,
                    status: 200,
                    body: Data(body.utf8)
                ),
                body
            ) {
                XCTAssertEqual($0 as? RewriteFailure, .emptyAnswer)
            }
        }
    }

    func testStatusesMeanWhatTheySay() {
        let cases: [(RewriteProvider, Int, String, RewriteFailure)] = [
            (.openAI, 401, #"{"error":{"code":"invalid_api_key"}}"#, .rejectedCredentials(.openAI)),
            (.openAI, 403, "{}", .rejectedCredentials(.openAI)),
            (.openRouter, 403, "{}", .notAllowed(.openRouter)),
            (.openRouter, 402, "{}", .outOfCredits(.openRouter)),
            (.openAI, 429, #"{"error":{"code":"rate_limit_exceeded"}}"#, .rateLimited(.openAI)),
            (.openAI, 429, #"{"error":{"code":"insufficient_quota"}}"#, .outOfCredits(.openAI)),
            (.openRouter, 429, "{}", .rateLimited(.openRouter)),
            (.gemini, 503, "{}", .unavailable("gemini is having trouble")),
            (.openAI, 500, "", .unavailable("openai is having trouble")),
            (.openAI, 404, #"{"error":{"code":"model_not_found"}}"#, .modelUnavailable(.openAI)),
            (.openAI, 400, "{}", .unavailable("openai refused the request")),
        ]
        for (provider, status, body, expected) in cases {
            XCTAssertThrowsError(
                try OpenAICompatibleClient.answer(
                    provider: provider,
                    status: status,
                    body: Data(body.utf8)
                ),
                "\(provider) \(status)"
            ) {
                XCTAssertEqual($0 as? RewriteFailure, expected, "\(provider) \(status)")
            }
        }
    }

    /// gemini says a bad key with a 400, wrapped in an array.
    func testGeminisBadKeyIsARejectedKey() {
        let body = Data(#"""
        [{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}]
        """#.utf8)

        XCTAssertEqual(
            OpenAICompatibleClient.failure(provider: .gemini, status: 400, body: body),
            .rejectedCredentials(.gemini)
        )
    }

    /// openrouter can say 200 and still carry the upstream model's error.
    func testOpenRoutersErrorInsideA200IsStillAnError() {
        let body = Data(#"{"error":{"code":429,"message":"upstream rate limited"}}"#.utf8)

        XCTAssertThrowsError(
            try OpenAICompatibleClient.answer(provider: .openRouter, status: 200, body: body)
        ) {
            XCTAssertEqual($0 as? RewriteFailure, .rateLimited(.openRouter))
        }
    }

    // MARK: - the client, with the network faked

    func testTheClientSendsAndReads() async throws {
        let network = FakeNetwork { request in
            XCTAssertEqual(request.url?.host, "api.openai.com")
            return (200, Data(#"{"choices":[{"message":{"content":"dear team,"}}]}"#.utf8))
        }
        let client = OpenAICompatibleClient(provider: .openAI, key: "sk", send: network.send)

        let text = try await client.rewrite(prompt, model: "gpt-6-luna")

        XCTAssertEqual(text, "dear team,")
        XCTAssertEqual(network.requests.count, 1)
    }

    func testTransportErrorsBecomePillReasons() async {
        let cases: [(URLError.Code, RewriteFailure)] = [
            (.notConnectedToInternet, .network),
            (.cannotFindHost, .network),
            (.timedOut, .timedOut),
        ]
        for (code, expected) in cases {
            let network = FakeNetwork { _ in throw URLError(code) }
            let client = OpenAICompatibleClient(provider: .gemini, key: "k", send: network.send)
            do {
                _ = try await client.rewrite(prompt, model: "m")
                XCTFail("\(code)")
            } catch {
                XCTAssertEqual(error as? RewriteFailure, expected)
            }
        }
    }

    /// letting go of the key cancels the request: that is not a failure
    /// to show.
    func testACancelledRequestStaysCancelled() async {
        let network = FakeNetwork { _ in throw URLError(.cancelled) }
        let client = OpenAICompatibleClient(provider: .openAI, key: "k", send: network.send)
        do {
            _ = try await client.rewrite(prompt, model: "m")
            XCTFail("no error")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: - the model picker

    func testModelRequests() {
        let openRouter = OpenAICompatibleClient.modelsRequest(provider: .openRouter, key: nil)
        let gemini = OpenAICompatibleClient.modelsRequest(provider: .gemini, key: "g")

        XCTAssertEqual(openRouter?.url?.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(openRouter?.httpMethod, "GET")
        XCTAssertNil(openRouter?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            gemini?.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai/models"
        )
        XCTAssertEqual(gemini?.value(forHTTPHeaderField: "Authorization"), "Bearer g")
    }

    func testOpenAIsListKeepsOnlyChatModelsSorted() throws {
        let body = Data(#"""
        {"object":"list","data":[
          {"id":"gpt-6-sol"},{"id":"text-embedding-3-large"},{"id":"gpt-6-luna"},
          {"id":"tts-1"},{"id":"whisper-1"},{"id":"dall-e-3"},{"id":"gpt-6-luna"},
          {"id":"gpt-realtime"},{"id":"omni-moderation-latest"}
        ]}
        """#.utf8)

        XCTAssertEqual(
            try OpenAICompatibleClient.modelIDs(provider: .openAI, status: 200, body: body),
            ["gpt-6-luna", "gpt-6-sol"]
        )
    }

    /// gemini names its models `models/…` and wants them back without it.
    func testGeminisPrefixIsDropped() throws {
        let body = Data(#"""
        {"object":"list","data":[{"id":"models/gemini-3.8-flash"},{"id":"models/gemini-3.5-flash-lite"},{"id":"models/gemini-embedding-001"}]}
        """#.utf8)

        XCTAssertEqual(
            try OpenAICompatibleClient.modelIDs(provider: .gemini, status: 200, body: body),
            ["gemini-3.5-flash-lite", "gemini-3.8-flash"]
        )
    }

    /// openrouter says what each model outputs; one that cannot write text
    /// cannot rewrite.
    func testOpenRoutersImageOnlyModelsAreDropped() throws {
        let body = Data(#"""
        {"data":[
          {"id":"openai/gpt-6-luna","architecture":{"output_modalities":["text"]}},
          {"id":"black-forest-labs/flux","architecture":{"output_modalities":["image"]}},
          {"id":"anthropic/claude-haiku-5.5"}
        ]}
        """#.utf8)

        XCTAssertEqual(
            try OpenAICompatibleClient.modelIDs(provider: .openRouter, status: 200, body: body),
            ["anthropic/claude-haiku-5.5", "openai/gpt-6-luna"]
        )
    }

    func testAModelListRefusalIsAFailure() {
        XCTAssertThrowsError(
            try OpenAICompatibleClient.modelIDs(provider: .openAI, status: 401, body: Data())
        ) {
            XCTAssertEqual($0 as? RewriteFailure, .rejectedCredentials(.openAI))
        }
    }

    // MARK: - the encoder everything shares

    /// a `+` in an email must not reach a form decoder as a space.
    func testFormEncodingEscapesEverythingButUnreserved() {
        XCTAssertEqual(
            RewriteHTTP.form([("login_hint", "a+b@c.com"), ("scope", "openid email"), ("x", "a/b:c")]),
            "login_hint=a%2Bb%40c.com&scope=openid%20email&x=a%2Fb%3Ac"
        )
    }

    func testErrorCodesAreFoundWherePutThere() {
        XCTAssertEqual(RewriteHTTP.errorCode(in: Data(#"{"error":"invalid_grant"}"#.utf8)), "invalid_grant")
        XCTAssertEqual(
            RewriteHTTP.errorCode(in: Data(#"{"error":{"code":"model_not_found"}}"#.utf8)),
            "model_not_found"
        )
        XCTAssertEqual(
            RewriteHTTP.errorCode(in: Data(#"[{"error":{"code":400,"status":"INVALID_ARGUMENT"}}]"#.utf8)),
            "INVALID_ARGUMENT"
        )
        XCTAssertNil(RewriteHTTP.errorCode(in: Data(#"{"detail":"not allowed"}"#.utf8)))
        XCTAssertNil(RewriteHTTP.errorCode(in: Data("<html>".utf8)))
    }
}
