import Foundation

/// a rewrite on the user's chatgpt plan: the responses api, with the
/// sign-in's access token as the bearer. the plan only answers streamed and
/// unstored requests, so the answer is read as server-sent events and
/// counts only once `response.completed` arrives.
struct ChatGPTClient: RewriteClient {
    let auth: ChatGPTAuth
    let open: RewriteHTTP.Open

    init(auth: ChatGPTAuth, open: @escaping RewriteHTTP.Open = RewriteHTTP.open) {
        self.auth = auth
        self.open = open
    }

    func rewrite(_ prompt: RewritePrompt, model: String) async throws -> String {
        let session = try await auth.validSession()
        guard session.canUsePlan else {
            throw RewriteFailure.notSignedIn(.chatGPT)
        }
        let request = ChatGPTResponses.request(
            prompt: prompt,
            model: model,
            accessToken: session.accessToken
        )
        do {
            let (response, lines) = try await open(request)
            guard response.statusCode == 200 else {
                var body = ""
                for try await line in lines where body.count < 16 * 1024 {
                    body += line + "\n"
                }
                throw ChatGPTResponses.failure(
                    status: response.statusCode,
                    body: Data(body.utf8)
                )
            }
            var reader = ChatGPTResponses.Reader()
            for try await line in lines {
                if try reader.feed(line) {
                    break
                }
            }
            return try reader.finish()
        } catch {
            throw RewriteHTTP.failure(from: error)
        }
    }

    /// the models this account's plan can use, in openai's order, for the
    /// picker. the same endpoint as the api's, but a different answer: a
    /// sign-in's token gets the plan's catalog.
    static func listModels(
        auth: ChatGPTAuth,
        send: RewriteHTTP.Send = RewriteHTTP.send
    ) async throws -> [ChatGPTResponses.Model] {
        let session = try await auth.validSession()
        let (body, response): (Data, HTTPURLResponse)
        do {
            (body, response) = try await send(
                ChatGPTResponses.modelsRequest(accessToken: session.accessToken)
            )
        } catch {
            throw RewriteHTTP.failure(from: error)
        }
        return try ChatGPTResponses.models(status: response.statusCode, body: body)
    }
}

/// the responses api as the chatgpt plan allows it, built and read without
/// touching the network.
enum ChatGPTResponses {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!

    /// the style goes in `instructions` — the plan rejects a system-role
    /// message — and the dictated text is the one user message. `store`
    /// false and `stream` true are required; temperature and an output cap
    /// are refused outright, so neither is sent.
    static func request(
        prompt: RewritePrompt,
        model: String,
        accessToken: String
    ) -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "instructions": prompt.instructions,
            "input": [
                ["role": "user", "content": prompt.text],
            ],
            "store": false,
            "stream": true,
        ]
        if let effort = RewriteProvider.chatGPT.reasoningEffort(for: model) {
            body["reasoning"] = ["effort": effort]
        }
        var request = RewriteHTTP.jsonRequest(
            endpoint,
            body: body,
            bearer: accessToken,
            timeout: RewriteHTTP.rewriteTimeout
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    static func modelsRequest(accessToken: String) -> URLRequest {
        var request = RewriteHTTP.plainRequest(
            modelsEndpoint,
            method: "GET",
            timeout: RewriteHTTP.setupTimeout
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    struct Model: Equatable, Sendable, Identifiable {
        /// what the request's `model` takes.
        let slug: String
        /// what the picker shows.
        let displayName: String

        var id: String {
            slug
        }
    }

    /// `models[]` with `visibility: "list"`, in the server's order — not
    /// openai api's `data[]`. the rest are hidden for a reason.
    static func models(status: Int, body: Data) throws -> [Model] {
        guard status == 200 else {
            throw failure(status: status, body: body)
        }
        guard let entries = RewriteHTTP.object(body)?["models"] as? [[String: Any]] else {
            throw RewriteFailure.trouble(.chatGPT)
        }
        return entries.compactMap { entry in
            guard entry["visibility"] as? String == "list",
                  let slug = entry["slug"] as? String, !slug.isEmpty
            else {
                return nil
            }
            let name = (entry["display_name"] as? String).flatMap {
                $0.isEmpty ? nil : $0
            }
            return Model(slug: slug, displayName: name ?? slug)
        }
    }

    // MARK: - failures

    /// a refusal before the stream opened, by its `error.code` when there
    /// is one and its status when there is not — admission errors come as
    /// `{"detail": "…"}` with no code at all.
    static func failure(status: Int, body: Data) -> RewriteFailure {
        if let failure = failure(code: RewriteHTTP.errorCode(in: body)) {
            return failure
        }
        switch status {
        case 401:
            return .rejectedCredentials(.chatGPT)
        case 403:
            return .notAllowed(.chatGPT)
        case 404:
            return .modelUnavailable(.chatGPT)
        case 429:
            return .rateLimited(.chatGPT)
        case 500...599:
            return .trouble(.chatGPT)
        default:
            return .unavailable("chatgpt refused the request")
        }
    }

    /// the codes openai documents for plan use, read the way its guide
    /// says to act on them. nil for a code that says nothing the status
    /// does not.
    static func failure(code: String?) -> RewriteFailure? {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            .planLimitReached
        case "subscription_sharing_user_not_eligible",
             "subscription_sharing_route_not_supported",
             "subscription_sharing_v2_client_not_enabled",
             "chatpass_v2_scope_not_authorized",
             "chatpass_v2_invalid_authorization_context":
            .notAllowed(.chatGPT)
        case "subscription_sharing_invalid_user", "invalid_token", "invalid_api_key":
            .rejectedCredentials(.chatGPT)
        case "subscription_sharing_usage_unavailable",
             "subscription_sharing_user_unavailable":
            .trouble(.chatGPT)
        case "model_not_found":
            .modelUnavailable(.chatGPT)
        case "rate_limit_exceeded":
            .rateLimited(.chatGPT)
        default:
            nil
        }
    }

    // MARK: - the stream

    /// reads server-sent events a line at a time. an event's json is
    /// handled as soon as it parses, so it works whether or not the blank
    /// line between events survived the line splitter (URLSession's
    /// `lines` drops it).
    struct Reader: Equatable, Sendable {
        private(set) var text = ""
        private(set) var completed = false
        private var pending = ""

        init() {}

        /// true once the answer is whole; read no further.
        mutating func feed(_ line: String) throws -> Bool {
            if line.isEmpty {
                return try dispatch()
            }
            guard line.hasPrefix("data:") else {
                // `event:`, `id:`, `retry:` and `:` comments: the json says
                // its own type, so nothing here is needed.
                return false
            }
            var data = line.dropFirst("data:".count)
            if data.first == " " {
                data = data.dropFirst()
            }
            if data == "[DONE]" {
                pending = ""
                return completed
            }
            pending += pending.isEmpty ? String(data) : "\n" + data
            guard RewriteHTTP.object(Data(pending.utf8)) != nil else {
                return false
            }
            return try dispatch()
        }

        /// the text, if `response.completed` came. a stream that just
        /// stopped is not an answer, however much text it had.
        mutating func finish() throws -> String {
            if !completed {
                _ = try dispatch()
            }
            guard completed else {
                throw RewriteFailure.unavailable("chatgpt stopped partway")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw RewriteFailure.emptyAnswer
            }
            return trimmed
        }

        private mutating func dispatch() throws -> Bool {
            defer {
                pending = ""
            }
            guard !pending.isEmpty,
                  let event = RewriteHTTP.object(Data(pending.utf8))
            else {
                return completed
            }
            switch event["type"] as? String {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
            case "response.completed":
                if text.isEmpty {
                    text = Self.outputText(of: event["response"])
                }
                completed = true
            case "response.failed":
                let error = (event["response"] as? [String: Any])?["error"]
                let code = (error as? [String: Any])?["code"] as? String
                throw ChatGPTResponses.failure(code: code)
                    ?? .unavailable("chatgpt couldn't finish")
            case "error":
                let code = (event["code"] as? String)
                    ?? ((event["error"] as? [String: Any])?["code"] as? String)
                throw ChatGPTResponses.failure(code: code)
                    ?? .unavailable("chatgpt couldn't finish")
            case "response.incomplete":
                throw RewriteFailure.unavailable("chatgpt stopped partway")
            default:
                break
            }
            return completed
        }

        /// the text out of a finished response object, for a stream whose
        /// deltas never came: `output[].content[]` of type `output_text`.
        static func outputText(of response: Any?) -> String {
            let output = (response as? [String: Any])?["output"] as? [[String: Any]] ?? []
            return output
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }
                .joined()
        }
    }
}
