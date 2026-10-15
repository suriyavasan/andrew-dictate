import CryptoKit
import Foundation
import Network

/// where a browser sign-in comes back to. the port is known before the
/// browser opens; `callback` waits for the redirect that carries this
/// attempt's state.
protocol CallbackReceiving: Sendable {
    var port: UInt16 { get }
    func callback() async throws -> [URLQueryItem]
    func cancel()
}

/// starts a receiver for one sign-in: the callback path, and the state the
/// redirect has to carry. injected, so tests can stand in for the browser.
typealias CallbackListen = @Sendable (
    _ path: String,
    _ expectedState: String
) async throws -> any CallbackReceiving

enum LoopbackFailure: Error, Equatable, Sendable {
    /// the os would not give us a port.
    case couldNotListen
    /// five minutes and no redirect: the tab was closed, or forgotten.
    case timedOut
}

/// a one-shot http listener for an oauth redirect.
///
/// loopback only: the listener is bound to the loopback interface, so
/// 127.0.0.1 and ::1 both reach it — openai insists on 127.0.0.1, openrouter
/// documents localhost — and nothing on the network can. the port is
/// whatever the os hands out, so a second copy of the app, or anything else
/// on a fixed port, cannot collide with it.
///
/// it answers the callback path with a small page in the app's voice and
/// everything else with a 404, so a favicon request or a stray probe does
/// not use up the attempt. a callback with the wrong state is turned away
/// and the listener keeps waiting for the right one.
final class LoopbackReceiver: CallbackReceiving, @unchecked Sendable {
    let port: UInt16

    private let queue: DispatchQueue
    private let listener: NWListener
    private let path: String
    private let expectedState: String
    // everything below is touched on `queue` only.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var outcome: Result<[URLQueryItem], any Error>?
    private var waiters: [CheckedContinuation<[URLQueryItem], any Error>] = []
    private var timeout: DispatchWorkItem?

    private init(
        port: UInt16,
        queue: DispatchQueue,
        listener: NWListener,
        path: String,
        expectedState: String
    ) {
        self.port = port
        self.queue = queue
        self.listener = listener
        self.path = path
        self.expectedState = expectedState
    }

    /// listening, with its port, or `couldNotListen`. the clock starts now.
    static func start(
        path: String,
        expectedState: String,
        timeout: Duration = .seconds(300)
    ) async throws -> LoopbackReceiver {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw LoopbackFailure.couldNotListen
        }
        let queue = DispatchQueue(label: "gg.jass.dictate.loopback")

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed, .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: LoopbackFailure.couldNotListen)
                    }
                default:
                    break
                }
            }
            // nothing connects before `ready`, and nothing is accepted
            // until the receiver exists to answer it.
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }
            listener.start(queue: queue)
        }
        guard port != 0 else {
            listener.cancel()
            throw LoopbackFailure.couldNotListen
        }

        let receiver = LoopbackReceiver(
            port: port,
            queue: queue,
            listener: listener,
            path: path,
            expectedState: expectedState
        )
        queue.async {
            listener.newConnectionHandler = { [weak receiver] connection in
                guard let receiver else {
                    connection.cancel()
                    return
                }
                receiver.accept(connection)
            }
            listener.stateUpdateHandler = { [weak receiver] state in
                if case .failed = state {
                    receiver?.finish(.failure(LoopbackFailure.couldNotListen))
                }
            }
            let expiry = DispatchWorkItem { [weak receiver] in
                receiver?.finish(.failure(LoopbackFailure.timedOut))
            }
            receiver.timeout = expiry
            let (seconds, attoseconds) = timeout.components
            queue.asyncAfter(
                deadline: .now() + .nanoseconds(
                    Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
                ),
                execute: expiry
            )
        }
        return receiver
    }

    /// the redirect's query items, once a request with this attempt's
    /// state arrives. an `error` item is still an answer — the caller
    /// decides what a refusal means.
    func callback() async throws -> [URLQueryItem] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let outcome = self.outcome {
                        continuation.resume(with: outcome)
                    } else {
                        self.waiters.append(continuation)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async {
            self.finish(.failure(CancellationError()))
        }
    }

    // MARK: - on the queue

    private func finish(_ result: Result<[URLQueryItem], any Error>) {
        guard outcome == nil else {
            return
        }
        outcome = result
        timeout?.cancel()
        listener.newConnectionHandler = nil
        listener.cancel()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(with: result)
        }
        // a successful answer closes its own connection once the page is
        // sent; anything still open is a browser's idle preconnect.
        if case .failure = result {
            closeAll()
        }
    }

    private func closeAll() {
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard outcome == nil else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8192
        ) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let chunk {
                buffer.append(chunk)
            }
            if let request = Self.parse(buffer) {
                self.answer(request, on: connection)
            } else if error != nil || isComplete || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ request: Request, on connection: NWConnection) {
        let verdict = outcome == nil
            ? Self.verdict(
                for: request,
                path: path,
                port: port,
                expectedState: expectedState
            )
            : .notFound
        connection.send(
            content: Self.response(for: verdict),
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
        if case let .accept(items) = verdict {
            connections[ObjectIdentifier(connection)] = nil
            finish(.success(items))
            closeAll()
        }
    }

    // MARK: - pure: reading a request, deciding, answering

    struct Request: Equatable, Sendable {
        let method: String
        let path: String
        let query: [URLQueryItem]
        let host: String?
    }

    /// the request line and the host header, once the headers are all in;
    /// nil until then. a body, if any, is never read.
    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            return Request(method: "", path: "", query: [], host: nil)
        }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var host: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2,
               pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "host" {
                host = pair[1].trimmingCharacters(in: .whitespaces).lowercased()
            }
        }
        return Request(
            method: String(parts[0]),
            path: components?.path ?? target,
            query: components?.queryItems ?? [],
            host: host
        )
    }

    enum Verdict: Equatable, Sendable {
        case accept([URLQueryItem])
        case notFound
        case badRequest
    }

    /// this attempt's redirect, or not.
    ///
    /// the host header has to name loopback and this port: a web page that
    /// rebinds its own domain to 127.0.0.1 can reach the port, but it sends
    /// its own name as the host. a code only ever comes with this attempt's
    /// state. a redirect with no state and no code is a refusal —
    /// openrouter drops `state` when the user says no — and it is let
    /// through, because it carries nothing to steal and leaving it would
    /// hold the sign-in open for five minutes.
    static func verdict(
        for request: Request,
        path: String,
        port: UInt16,
        expectedState: String
    ) -> Verdict {
        guard request.method == "GET", request.path == path else {
            return .notFound
        }
        let hosts = ["127.0.0.1", "localhost", "[::1]"].map { "\($0):\(port)" }
        guard let host = request.host, hosts.contains(host) else {
            return .badRequest
        }
        let states = request.query.filter { $0.name == "state" }
        let codes = request.query.filter { $0.name == "code" }
        guard states.count <= 1, codes.count <= 1 else {
            return .badRequest
        }
        if let state = states.first?.value {
            guard same(state, expectedState) else {
                return .badRequest
            }
        } else if !codes.isEmpty {
            return .badRequest
        }
        return .accept(request.query)
    }

    /// equal or not, in time that does not depend on where they differ.
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in a.indices {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }

    /// what the browser tab shows, in the app's voice. a refusal says so,
    /// rather than claiming a sign-in that did not happen.
    static func page(for verdict: Verdict) -> String {
        let message: String
        switch verdict {
        case let .accept(items):
            message = items.contains { $0.name == "error" } || !items.contains { $0.name == "code" }
                ? "sign-in was cancelled. you can close this tab and go back to andrew dictate."
                : "signed in. you can close this tab and go back to andrew dictate."
        case .notFound:
            message = "nothing here."
        case .badRequest:
            message = "this sign-in link is from another attempt. go back to andrew dictate and start again."
        }
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <title>andrew dictate</title><style>\
        body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:30rem;\
        margin:20vh auto;padding:0 24px;color:#1d1d1f;background:#fbfaf7}\
        @media(prefers-color-scheme:dark){body{color:#f5f5f7;background:#161616}}\
        </style></head><body><p>\(message)</p>\
        <script>\(scrubScript)</script></body></html>
        """
    }

    /// takes the code and state out of the address bar and the tab's
    /// history, so a later screen share or history sync does not carry them.
    static let scrubScript = #"history.replaceState(null,"","/");"#

    static func response(for verdict: Verdict) -> Data {
        let status = switch verdict {
        case .accept:
            "200 OK"
        case .notFound:
            "404 Not Found"
        case .badRequest:
            "400 Bad Request"
        }
        let body = Data(page(for: verdict).utf8)
        let scriptHash = Data(SHA256.hash(data: Data(scrubScript.utf8)))
            .base64EncodedString()
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Content-Security-Policy: default-src 'none'; "
                + "script-src 'sha256-\(scriptHash)'; style-src 'unsafe-inline'; "
                + "frame-ancestors 'none'; base-uri 'none'",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(head.utf8) + body
    }
}

/// the first caller wins; for the listener's state handler, which can fire
/// `ready` and later `cancelled` into one continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
