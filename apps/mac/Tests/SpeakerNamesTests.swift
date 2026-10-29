import XCTest

final class SpeakerNamesTests: XCTestCase {
    func testAPlainNameIsKept() {
        XCTAssertEqual(SpeakerNames.clean("Priya"), "Priya")
        XCTAssertEqual(SpeakerNames.clean("  Priya   Nair "), "Priya Nair")
        XCTAssertEqual(SpeakerNames.clean("Siobhán O'Brien"), "Siobhán O'Brien")
        XCTAssertEqual(SpeakerNames.clean("प्रिया"), "प्रिया")
    }

    func testWhatWouldBreakALineIsTakenOut() {
        // a colon would end the name where the words begin; a comma or a
        // bracket would end an item of `speakers: [...]`.
        XCTAssertEqual(SpeakerNames.clean("Smith, John"), "Smith John")
        XCTAssertEqual(SpeakerNames.clean("Dr: Rao"), "Dr Rao")
        XCTAssertEqual(SpeakerNames.clean("Priya [guest]"), "Priya guest")
        XCTAssertEqual(SpeakerNames.clean("Priya\nNair\t"), "Priya Nair")
        XCTAssertEqual(SpeakerNames.clean("- Priya"), "Priya")
        XCTAssertEqual(SpeakerNames.clean("*&Priya"), "Priya")
    }

    func testANameIsCutAtTheLimit() throws {
        let long = try XCTUnwrap(SpeakerNames.clean(String(repeating: "a", count: 200)))
        XCTAssertEqual(long.count, SpeakerNames.nameLimit)
    }

    func testNothingLeftIsNoName() {
        XCTAssertNil(SpeakerNames.clean(nil))
        XCTAssertNil(SpeakerNames.clean(""))
        XCTAssertNil(SpeakerNames.clean("  : , "))
    }

    func testALabelCannotBeAName() {
        for label in ["you", "You", "them", "THEM 3", "them 12"] {
            XCTAssertNil(SpeakerNames.clean(label), label)
        }
        XCTAssertEqual(SpeakerNames.clean("them all"), "them all")
        XCTAssertEqual(SpeakerNames.clean("Thema"), "Thema")
    }

    func testTheLabelsTheAppWrites() {
        XCTAssertTrue(SpeakerNames.isOriginal("you"))
        XCTAssertTrue(SpeakerNames.isOriginal("them"))
        XCTAssertTrue(SpeakerNames.isOriginal("them 2"))
        XCTAssertFalse(SpeakerNames.isOriginal("them 0"))
        XCTAssertFalse(SpeakerNames.isOriginal("them x"))
        XCTAssertFalse(SpeakerNames.isOriginal("Priya"))
    }

    func testLabelsSortYouThenTheFarSideByNumber() {
        let labels = ["them 10", "them 2", "you", "them"]
        XCTAssertEqual(labels.sorted { SpeakerNames.rank($0) < SpeakerNames.rank($1) },
                       ["you", "them", "them 2", "them 10"])
    }
}
