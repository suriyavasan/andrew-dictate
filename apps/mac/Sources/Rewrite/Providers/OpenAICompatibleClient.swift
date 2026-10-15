import Foundation

/// openai, openrouter and gemini, which all speak openai's chat
/// completions: one request shape, one answer shape, three base urls. the
/// request and the answer are pure; `send` is the only I/O.
struct OpenAICompatibleClient: RewriteClient {
    let provider: RewriteProvider
    let key: String
    let send: RewriteHTTP.Send

    init(
        provider: RewriteProvider,
        key: String,
        send: @escaping RewriteHTTP.Send = RewriteHTTP.send
    ) {
        self.provider = provider
        self.key = key
        self.send = send
    }

    func rewrite(_ prompt: RewritePrompt, model: String) async throws -> String {
        guard let request = Self.request(
            provider: provider,
            key: key,
            prompt: prompt,
            model: model
        ) else {
            throw RewriteFailure.notSignedIn(provider)
        }
        let (body, response): (Data, HTTPURLResponse)
        do {
            (body, response) = try await send(request)
        } catch {
            throw RewriteHTTP.failure(from: error)
        }
        return try Self.answer(
            provider: provider,
            status: response.statusCode,
            body: body
        )
    }

    // MARK: - where

    /// the openai-shaped root for each. gemini's ends in `/openai`: it is
    /// google's compatibility layer, not its own api.
    static func baseURL(for provider: RewriteProvider) -> URL? {
        switch provider {
        case .openAI:
            URL(string: "https://api.openai.com/v1")
        case .openRouter:
            URL(string: "https://openrouter.ai/api/v1")
        case .gemini:
            URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")
        case .chatGPT, .apple:
            nil
        }
    }

    /// openrouter shows these on the user's activity page, so a request
    /// says which app sent it. nobody else is told.
    static func attributionHeaders(
        for provider: RewriteProvider
    ) -> [(String, String)] {
        guard provider == .openRouter else {
            return []
        }
        return [
            ("HTTP-Referer", "https://dictate.jass.gg"),
            ("X-Title", "Andrew Dictate"),
        ]
    }

    // MARK: - the rewrite

    /// system instructions, then the dictated text; one answer, not a
    /// stream — the paste needs all of it anyway. no temperature and no
    /// token cap: reasoning models refuse the first, and the second can
    /// cut a rewrite off mid-sentence and still return 200.
    static func request(
        provider: RewriteProvider,
        key: String,
        prompt: RewritePrompt,
        model: String
    ) -> URLRequest? {
        guard let base = baseURL(for: provider) else {
            return nil
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt.instructions],
                ["role": "user", "content": prompt.text],
            ],
            "stream": false,
        ]
        if let effort = provider.reasoningEffort(for: model) {
            body["reasoning_effort"] = effort
        }
        var request = RewriteHTTP.jsonRequest(
            base.appending(path: "chat/completions"),
            body: body,
            bearer: key,
            timeout: RewriteHTTP.rewriteTimeout
        )
        for (name, value) in attributionHeaders(for: provider) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// `choices[0].message.content`, trimmed. anything else is a
    /// `RewriteFailure` the pill can say.
    static func answer(
        provider: RewriteProvider,
        status: Int,
        body: Data
    ) throws -> String {
        guard status == 200 else {
            throw failure(provider: provider, status: status, body: body)
        }
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }

                let message: Message?
            }

            let choices: [Choice]?
        }

        // openrouter can answer 200 with an error inside, when the model
        // behind it failed after the request was accepted.
        if let inner = RewriteHTTP.object(body)?["error"] as? [String: Any] {
            let code = (inner["code"] as? Int)
                ?? Int(inner["code"] as? String ?? "")
                ?? 502
            throw failure(provider: provider, status: code, body: body)
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: body)
        else {
            throw RewriteFailure.trouble(provider)
        }
        let text = completion.choices?.first?.message?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw RewriteFailure.emptyAnswer
        }
        return text
    }

    /// a status, read the way each provider means it. gemini says a bad
    /// key with a 400 and `API_KEY_INVALID`, not a 401.
    static func failure(
        provider: RewriteProvider,
        status: Int,
        body: Data
    ) -> RewriteFailure {
        let code = RewriteHTTP.errorCode(in: body)?.lowercased() ?? ""
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
        if text.contains("API_KEY_INVALID") || code == "invalid_api_key" {
            return .rejectedCredentials(provider)
        }
        if code == "model_not_found" {
            return .modelUnavailable(provider)
        }
        switch status {
        case 401:
            return .rejectedCredentials(provider)
        case 402:
            return .outOfCredits(provider)
        case 403:
            // openai and gemini both say a disabled or wrong-project key
            // with a 403; openrouter says a moderation refusal.
            return provider == .openRouter
                ? .notAllowed(provider)
                : .rejectedCredentials(provider)
        case 404:
            return .modelUnavailable(provider)
        case 408:
            return .timedOut
        case 429:
            return code == "insufficient_quota"
                ? .outOfCredits(provider)
                : .rateLimited(provider)
        case 500...599:
            return .trouble(provider)
        default:
            return .unavailable("\(provider.shortName) refused the request")
        }
    }

    // MARK: - the model picker

    /// openrouter's list is public, so its key is optional; the others
    /// need theirs.
    static func modelsRequest(provider: RewriteProvider, key: String?) -> URLRequest? {
        guard let base = baseURL(for: provider) else {
            return nil
        }
        var request = RewriteHTTP.plainRequest(
            base.appending(path: "models"),
            method: "GET",
            timeout: RewriteHTTP.setupTimeout
        )
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in attributionHeaders(for: provider) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// words in an id that mean the model cannot answer a chat: openai's
    /// list carries embeddings, voices and image models beside the text
    /// ones, and gemini's carries its own.
    static let notForChat = [
        "embed", "tts", "whisper", "transcribe", "dall-e", "image", "imagen",
        "veo", "sora", "moderation", "realtime", "audio", "aqa", "babbage",
        "davinci", "search", "computer-use", "live",
    ]

    /// the ids, sorted, deduplicated, chat models only. gemini names its
    /// models `models/gemini-…`, and wants `gemini-…` back.
    static func modelIDs(
        provider: RewriteProvider,
        status: Int,
        body: Data
    ) throws -> [String] {
        guard status == 200 else {
            throw failure(provider: provider, status: status, body: body)
        }
        guard let entries = RewriteHTTP.object(body)?["data"] as? [[String: Any]]
        else {
            throw RewriteFailure.trouble(provider)
        }
        var ids = Set<String>()
        for entry in entries {
            guard var id = entry["id"] as? String, !id.isEmpty else {
                continue
            }
            if id.hasPrefix("models/") {
                id.removeFirst("models/".count)
            }
            if let architecture = entry["architecture"] as? [String: Any],
               let output = architecture["output_modalities"] as? [String],
               !output.contains("text") {
                continue
            }
            let lowered = id.lowercased()
            if notForChat.contains(where: { lowered.contains($0) }) {
                continue
            }
            ids.insert(id)
        }
        return ids.sorted()
    }

    static func listModels(
        provider: RewriteProvider,
        key: String?,
        send: RewriteHTTP.Send = RewriteHTTP.send
    ) async throws -> [String] {
        guard let request = modelsRequest(provider: provider, key: key) else {
            return []
        }
        let (body, response): (Data, HTTPURLResponse)
        do {
            (body, response) = try await send(request)
        } catch {
            throw RewriteHTTP.failure(from: error)
        }
        return try modelIDs(
            provider: provider,
            status: response.statusCode,
            body: body
        )
    }
}
