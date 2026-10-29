import XCTest

final class OrderedJSONTests: XCTestCase {
    func testKeysStayInTheOrderTheyWereWritten() {
        let value = OrderedJSON.object([
            ("v", .int(1)), ("meeting", .string("m")), ("a", .bool(true)), ("z", .null),
        ])
        XCTAssertEqual(value.rendered, #"{"v":1,"meeting":"m","a":true,"z":null}"#)
    }

    func testAStringIsEscapedToOneLine() throws {
        let text = "he said \"hi\"\\\n\tand left/\u{2028}\u{01}"
        let line = OrderedJSON.object([("text", .string(text))]).rendered
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\u{2028}"))
        // a slash is left alone, and the line reads back as what it was.
        XCTAssertTrue(line.contains("left/"))
        let back = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
        XCTAssertEqual(back?["text"], text)
    }

    func testWordsInOtherScriptsAreKeptAsTheyAre() {
        XCTAssertEqual(OrderedJSON.string("प्रिया café 日本").rendered, "\"प्रिया café 日本\"")
    }

    func testNoneIsNull() {
        XCTAssertEqual(OrderedJSON.orNull(nil).rendered, "null")
        XCTAssertEqual(OrderedJSON.orNull("x").rendered, "\"x\"")
    }

    func testPrettyIndentsAndKeepsTheOrder() throws {
        let value = OrderedJSON.object([
            ("b", .array([.int(1), .object([("c", .string("d"))])])),
            ("a", .array([])),
            ("e", .object([])),
        ])
        XCTAssertEqual(value.pretty, """
        {
          "b": [
            1,
            {
              "c": "d"
            }
          ],
          "a": [],
          "e": {}
        }
        """)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(value.pretty.utf8)))
    }
}
