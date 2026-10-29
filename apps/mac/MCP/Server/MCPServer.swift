import Foundation

/// mcp over stdio, by hand: json-rpc 2.0, one message to a line, no
/// dependencies. one line in, at most one line out, and nothing else is ever
/// written where the client reads: a stray print would corrupt the stream.
///
/// what it answers: `initialize`, `ping`, `tools/list`, `tools/call`; it
/// takes `notifications/initialized` and any other notification silently.
/// everything else is “method not found”. it never writes, and nothing it
/// reads is logged.
struct MCPServer {
    static let protocolVersion = "2025-06-18"
    /// older revisions of the same handshake, answered in their own version
    /// when a client asks for one; the tools mean the same in all of them.
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private enum Code {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    let reader: MeetingsReader
    var version = "0"
    private let tools = MCPTools()

    init(reader: MeetingsReader, version: String = "0") {
        self.reader = reader
        self.version = version
    }

    /// the line to write back, or nil when none is owed (a notification).
    func respond(to line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return failure(id: .null, Code.parse, "that was not json.")
        }
        guard let message = parsed as? [String: Any] else {
            // a batch was dropped from the protocol in 2025-06-18.
            return failure(id: .null, Code.invalidRequest, "a request is one json object.")
        }
        let hasID = message["id"] != nil
        let id = hasID ? Self.id(message["id"]) : nil
        guard hasID == false || id != nil else {
            return failure(id: .null, Code.invalidRequest, "id is a string or a whole number.")
        }
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            // a response from the client to a request this server never made.
            if message["method"] == nil, message["result"] != nil || message["error"] != nil {
                return nil
            }
            return failure(id: id ?? .null, Code.invalidRequest, "not a json-rpc 2.0 request.")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return nil }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return success(id: id, .object([
                ("protocolVersion", .string(
                    asked.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.protocolVersion)),
                ("capabilities", .object([("tools", .object([("listChanged", .bool(false))]))])),
                ("serverInfo", .object([
                    ("name", .string("andrew-dictate")),
                    ("title", .string("andrew dictate meetings")),
                    ("version", .string(version)),
                ])),
                ("instructions", .string(MCPTools.instructions)),
            ]))
        case "ping":
            return success(id: id, .object([]))
        case "tools/list":
            return success(id: id, .object([("tools", tools.listed())]))
        case "tools/call":
            guard let name = params["name"] as? String else {
                return failure(id: id, Code.invalidParams, "tools/call needs a tool name.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let outcome = tools.call(name, arguments, on: reader) else {
                return failure(id: id, Code.invalidParams, "no tool called “\(name)”.")
            }
            switch outcome {
            case .success(let text): return success(id: id, Self.content(text, isError: false))
            case .failure(let problem): return success(id: id, Self.content(problem.message, isError: true))
            }
        default:
            return failure(id: id, Code.methodNotFound, "this server has no “\(method)”.")
        }
    }

    private static func content(_ text: String, isError: Bool) -> OrderedJSON {
        .object([
            ("content", .array([.object([("type", .string("text")), ("text", .string(text))])])),
            ("isError", .bool(isError)),
        ])
    }

    private static func id(_ raw: Any?) -> OrderedJSON? {
        if let text = raw as? String { return .string(text) }
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let int = Int(exactly: number.doubleValue) {
            return .int(int)
        }
        return nil
    }

    private func success(id: OrderedJSON, _ result: OrderedJSON) -> String {
        OrderedJSON.object([
            ("jsonrpc", .string("2.0")), ("id", id), ("result", result),
        ]).rendered
    }

    private func failure(id: OrderedJSON, _ code: Int, _ message: String) -> String {
        OrderedJSON.object([
            ("jsonrpc", .string("2.0")), ("id", id),
            ("error", .object([("code", .int(code)), ("message", .string(message))])),
        ]).rendered
    }
}
