import XCTest

/// the notes a model writes, cut into what the window draws.
final class MeetingNotesBlocksTests: XCTestCase {
    func testTheAutoTemplateShape() {
        let blocks = MeetingNotesBlocks.blocks("""
        ## Meeting Summary
        We agreed to ship on friday.

        ## Action Items
        - [ ] Ana sends the invoice
        - [x] Raj books the room
        - plain point
        """)

        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Meeting Summary"),
            .paragraph("We agreed to ship on friday."),
            .heading(level: 2, text: "Action Items"),
            .bullet(text: "Ana sends the invoice", depth: 0, checked: false),
            .bullet(text: "Raj books the room", depth: 0, checked: true),
            .bullet(text: "plain point", depth: 0, checked: nil),
        ])
    }

    func testNoneNotedIsItsOwnPiece() {
        XCTAssertEqual(
            MeetingNotesBlocks.blocks("### Decisions\nNone noted."),
            [.heading(level: 3, text: "Decisions"), .noneNoted])
    }

    func testIndentedPointsAreDeeper() {
        XCTAssertEqual(
            MeetingNotesBlocks.blocks("- top\n  - inside\n    * deeper"),
            [.bullet(text: "top", depth: 0, checked: nil),
             .bullet(text: "inside", depth: 1, checked: nil),
             .bullet(text: "deeper", depth: 2, checked: nil)])
    }

    func testNumberedPointsKeepTheirNumbers() {
        XCTAssertEqual(
            MeetingNotesBlocks.blocks("1. first\n2. second"),
            [.numbered(number: 1, text: "first", depth: 0),
             .numbered(number: 2, text: "second", depth: 0)])
    }

    func testRulesAndBlankLinesSayNothing() {
        XCTAssertEqual(MeetingNotesBlocks.blocks("a\n\n---\n\nb"), [.paragraph("a"), .paragraph("b")])
    }

    func testAQuoteAndABareBoxAndAHashWithNoWords() {
        XCTAssertEqual(MeetingNotesBlocks.blocks("> said so"), [.quote("said so")])
        XCTAssertEqual(
            MeetingNotesBlocks.blocks("- [ ]"), [.bullet(text: "", depth: 0, checked: false)])
        XCTAssertEqual(MeetingNotesBlocks.blocks("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(MeetingNotesBlocks.blocks("#"), [.paragraph("#")])
    }

    func testInlineMarkdownIsLeftForTheViewToStyle() {
        XCTAssertEqual(
            MeetingNotesBlocks.blocks("- **Ana** owns `deploy`"),
            [.bullet(text: "**Ana** owns `deploy`", depth: 0, checked: nil)])
    }

    func testCarriageReturnsAreIgnored() {
        XCTAssertEqual(MeetingNotesBlocks.blocks("a\r\nb"), [.paragraph("a"), .paragraph("b")])
    }
}
