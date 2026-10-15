import Foundation

/// what every provider's I/O shares: one way to send, one way to read a
/// failure off a URLError, one way to encode a form. the builders and
/// parsers stay pure; this file is where the network is.
enum RewriteHTTP {
    /// a request in, the body and the response out. injected everywhere, so
    /// tests hand back canned answers and the app hands back the network.
    typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// a request in, the status and the body line by line out, for the
    /// one provider that has to stream (chatgpt's responses api).
    typealias Open = @Sendable (URLRequest) async throws -> (
        HTTPURLResponse,
        AsyncThrowingStream<String, any Error>
    )

    /// a rewrite is a sentence or two: 20 seconds without a byte is a
    /// provider that is not going to answer in time to be useful.
    static let rewriteTimeout: TimeInterval = 20

    /// a meeting's summary reads an hour of talk and writes a page, with
    /// nobody waiting on the paste: three minutes without a byte is a
    /// provider that is not going to answer.
    static let summaryTimeout: TimeInterval = 180

    /// sign-in and model lists are not on the paste path, so they get
    /// longer.
    static let setupTimeout: TimeInterval = 30

    /// an ephemeral session: no cookies, no cache, nothing on disk. the
    /// dictated text and the bearer token pass through and are gone.
    static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// the live `Send` and `Open`, as values: what every initializer
    /// defaults to.
    static let send: Send = { try await sendOverNetwork($0) }
    static let open: Open = { try await openOverNetwork($0) }

    /// redirects are refused: a 30x would carry the dictated text, and the
    /// key, to a host nobody chose.
    static func sendOverNetwork(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = ephemeralSession()
        defer {
            session.finishTasksAndInvalidate()
        }
        let (data, response) = try await session.data(
            for: request,
            delegate: NoRedirects.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// the body as lines, as they arrive. the stream owns
    /// the session, and ending the stream early — the reader saw
    /// `response.completed`, or the task was cancelled — ends the request.
    static func openOverNetwork(_ request: URLRequest) async throws -> (
        HTTPURLResponse,
        AsyncThrowingStream<String, any Error>
    ) {
        let session = ephemeralSession()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(
                for: request,
                delegate: NoRedirects.shared
            )
        } catch {
            session.invalidateAndCancel()
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            session.invalidateAndCancel()
            throw URLError(.badServerResponse)
        }
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let pump = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                session.finishTasksAndInvalidate()
            }
            continuation.onTermination = { _ in
                pump.cancel()
                session.invalidateAndCancel()
            }
        }
        return (http, lines)
    }

    /// what a thrown error means to the pill. a `RewriteFailure` passes
    /// through; cancellation stays cancellation, because the user let go
    /// of the key and nothing failed.
    static func failure(from error: any Error) -> any Error {
        if error is RewriteFailure || error is CancellationError {
            return error
        }
        guard let urlError = error as? URLError else {
            return RewriteFailure.network
        }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return RewriteFailure.timedOut
        default:
            return RewriteFailure.network
        }
    }

    // MARK: - encoding

    /// RFC 3986's unreserved set. everything else is escaped, `+` included:
    /// a form decoder reads a bare `+` in `user+tag@mail.com` as a space.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// `a=1&b=2`, in the order given, every name and value escaped. used
    /// for query strings and form bodies alike.
    static func form(_ pairs: [(String, String)]) -> String {
        pairs
            .map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
    }

    static func url(_ base: URL, query pairs: [(String, String)]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = form(pairs)
        return components.url!
    }

    static func formRequest(
        _ url: URL,
        _ pairs: [(String, String)],
        timeout: TimeInterval = setupTimeout
    ) -> URLRequest {
        var request = plainRequest(url, method: "POST", timeout: timeout)
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data(form(pairs).utf8)
        return request
    }

    /// no cookies, no cache, a pinned user agent and language: URLSession's
    /// defaults would send the build number, the darwin version and the
    /// region to every provider.
    static func plainRequest(
        _ url: URL,
        method: String,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("andrew-dictate", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func jsonRequest(
        _ url: URL,
        body: [String: Any],
        bearer: String?,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = plainRequest(url, method: "POST", timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )
        return request
    }

    static func object(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// the machine-readable code in an error body, wherever this provider
    /// put it: `{"error": "invalid_grant"}` (oauth), `{"error": {"code":
    /// …}}` (openai), `[{"error": {"status": …}}]` (gemini).
    static func errorCode(in body: Data) -> String? {
        let parsed = try? JSONSerialization.jsonObject(with: body)
        var node: Any? = (parsed as? [Any])?.first ?? parsed
        for _ in 0..<4 {
            guard let object = node as? [String: Any] else {
                return nil
            }
            if let code = object["error"] as? String {
                return code
            }
            if let inner = object["error"] ?? object["detail"],
               inner is [String: Any] {
                node = inner
                continue
            }
            if let code = object["code"] as? String {
                return code
            }
            return object["status"] as? String
        }
        return nil
    }
}

/// a 30x is answered with "no": the response that carried it comes back as
/// the response, and the request never leaves for the new host.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirects()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension Data {
    /// base64url without padding (RFC 4648 §5): what PKCE, JWTs and JWKs
    /// all speak.
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 {
            return nil
        }
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
