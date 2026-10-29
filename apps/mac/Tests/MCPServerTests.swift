import XCTest

final class MCPServerTests: XCTestCase {
    private var fixture: MCPFixture!
    private var server: MCPServer!

    override func setUpWithError() throws {
        fixture = try MCPFixture()
        server = MCPServer(reader: fixture.reader(), version: "9.9")
    }

    private func ask(_ message: String) throws -> [String: Any] {
        let line = try XCTUnwrap(server.respond(to: message), "no answer to \(message)")
        XCTAssertFalse(line.contains("\n"), "one line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func call(_ name: String, _ arguments: String = "{}") throws -> (text: String, isError: Bool) {
        let answer = try ask(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
        let result = try XCTUnwrap(answer["result"] as? [String: Any])
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["type"] as? String, "text")
        return (try XCTUnwrap(content["text"] as? String), result["isError"] as? Bool ?? false)
    }

    private func errorCode(_ answer: [String: Any]) -> Int? {
        (answer["error"] as? [String: Any])?["code"] as? Int
    }

    // MARK: - the handshake

    func testInitializeAnswersWithTheVersionToolsAndWhoItIs() throws {
        let answer = try ask(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#)
        XCTAssertEqual(answer["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(answer["id"] as? Int, 1)
        let result = try XCTUnwrap(answer["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "andrew-dictate")
        XCTAssertEqual(info["version"] as? String, "9.9")
        XCTAssertTrue((result["instructions"] as? String)?.contains("“them 2”") ?? false)
    }

    func testAnOlderRevisionIsAnsweredInItsOwnAndAnUnknownOneInOurs() throws {
        let older = try ask(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        XCTAssertEqual((older["result"] as? [String: Any])?["protocolVersion"] as? String, "2024-11-05")
        let future = try ask(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2031-01-01"}}"#)
        XCTAssertEqual((future["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
    }

    func testNotificationsAreTakenAndNeverAnswered() {
        XCTAssertNil(server.respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.respond(to: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#))
        XCTAssertNil(server.respond(to: #"{"jsonrpc":"2.0","method":"something/unknown"}"#))
    }

    func testPingIsEmpty() throws {
        let answer = try ask(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
        XCTAssertEqual(answer["id"] as? String, "abc")
        XCTAssertEqual((answer["result"] as? [String: Any])?.count, 0)
    }

    // MARK: - json-rpc errors

    func testWhatIsNotJsonIsAParseErrorWithNoId() throws {
        let answer = try ask("{not json")
        XCTAssertEqual(errorCode(answer), -32700)
        XCTAssertTrue(answer["id"] is NSNull)
    }

    func testWhatIsNotARequestIsInvalid() throws {
        XCTAssertEqual(errorCode(try ask("[1,2]")), -32600)
        XCTAssertEqual(errorCode(try ask("\"hi\"")), -32600)
        XCTAssertEqual(errorCode(try ask(#"{"id":1,"method":"ping"}"#)), -32600)
        XCTAssertEqual(errorCode(try ask(#"{"jsonrpc":"2.0","id":1}"#)), -32600)
        XCTAssertEqual(errorCode(try ask(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#)), -32600)
    }

    func testAMethodItDoesNotHaveIsNotFound() throws {
        let answer = try ask(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)
        XCTAssertEqual(errorCode(answer), -32601)
        XCTAssertEqual(answer["id"] as? Int, 4)
    }

    func testAResponseFromTheClientIsNotAnswered() {
        XCTAssertNil(server.respond(to: #"{"jsonrpc":"2.0","id":1,"result":{}}"#))
    }

    // MARK: - the tools

    func testTheFourToolsAreListedReadOnlyWithSchemas() throws {
        let answer = try ask(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((answer["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, [
            "list_meetings", "get_meeting", "search_meetings", "get_live_meeting",
        ])
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"])
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        }
        XCTAssertEqual(
            (tools[1]["inputSchema"] as? [String: Any])?["required"] as? [String], ["id"])
    }

    func testEveryDescriptionSaysWhereNamesComeFromAndWhatThemTwoIs() throws {
        let answer = try ask(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((answer["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for tool in tools {
            let words = try XCTUnwrap(tool["description"] as? String)
            XCTAssertTrue(words.contains("call app's own window"), tool["name"] as? String ?? "")
            XCTAssertTrue(words.contains("remembers"), tool["name"] as? String ?? "")
            XCTAssertTrue(words.contains("by hand"), tool["name"] as? String ?? "")
            XCTAssertTrue(words.contains("“them 2”"), tool["name"] as? String ?? "")
            XCTAssertTrue(words.contains("not named"), tool["name"] as? String ?? "")
        }
    }

    func testListMeetingsThroughTheWire() throws {
        let result = try call("list_meetings", #"{"limit":1}"#)
        XCTAssertFalse(result.isError)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        XCTAssertEqual((json["meetings"] as? [[String: Any]])?.first?["id"] as? String, MCPFixture.namedID)
    }

    func testGetMeetingThroughTheWire() throws {
        let markdown = try call("get_meeting", #"{"id":"\#(MCPFixture.namedID)"}"#)
        XCTAssertFalse(markdown.isError)
        XCTAssertTrue(markdown.text.hasPrefix("---\napp: meet\n"))
        let turns = try call("get_meeting", #"{"id":"\#(MCPFixture.oldID)","format":"turns"}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(turns.text.utf8)) as? [String: Any])
        XCTAssertEqual((json["turns"] as? [[String: Any]])?.count, 3)
    }

    func testSearchThroughTheWire() throws {
        let result = try call("search_meetings", #"{"query":"roadmap","speaker":"Priya"}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        let match = try XCTUnwrap((json["matches"] as? [[String: Any]])?.first)
        XCTAssertEqual(match["speaker"] as? String, "Priya")
        XCTAssertEqual(match["meeting"] as? String, MCPFixture.namedID)
    }

    func testTheLiveMeetingThroughTheWire() throws {
        _ = try fixture.feed(lines: [(.them, 2, "can you hear me")])
        let result = try call("get_live_meeting", #"{"after_seq":0}"#)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        XCTAssertEqual(json["recording"] as? Bool, true)
        XCTAssertEqual((json["lines"] as? [[String: Any]])?.first?["text"] as? String, "can you hear me")
        let nothing = try call("get_live_meeting")
        XCTAssertFalse(nothing.isError)
    }

    func testAToolCalledWrongSaysSoToTheModelAsAToolError() throws {
        for (name, arguments) in [
            ("get_meeting", "{}"),
            ("get_meeting", #"{"id":"nope"}"#),
            ("get_meeting", #"{"id":"\#(MCPFixture.oldID)","format":"pdf"}"#),
            ("list_meetings", #"{"since":"last tuesday"}"#),
            ("list_meetings", #"{"limit":"ten"}"#),
            ("list_meetings", #"{"limit":2.5}"#),
            ("list_meetings", #"{"limit":true}"#),
            ("search_meetings", "{}"),
            ("search_meetings", #"{"query":""}"#),
            ("get_live_meeting", #"{"after_seq":"x"}"#),
        ] {
            let result = try call(name, arguments)
            XCTAssertTrue(result.isError, "\(name) \(arguments)")
            XCTAssertFalse(result.text.isEmpty)
        }
    }

    func testAToolThatIsNotThereIsInvalidParams() throws {
        let answer = try ask(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"delete_meeting","arguments":{"id":"x"}}}"#)
        XCTAssertEqual(errorCode(answer), -32602)
        XCTAssertEqual(errorCode(try ask(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#)), -32602)
    }

    func testThereIsNoToolThatWrites() throws {
        let answer = try ask(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((answer["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertTrue(name.hasPrefix("list_") || name.hasPrefix("get_") || name.hasPrefix("search_"), name)
        }
    }
}
