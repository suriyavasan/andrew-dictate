import XCTest

final class VoiceBookTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("voices.json") }
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-book-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func book() -> VoiceBook {
        VoiceBook(url: url, now: { [day] in day })
    }

    func testAnEmptyBookKnowsNobody() {
        XCTAssertTrue(book().people().isEmpty)
    }

    func testAVoiceLearnedIsThereInAnotherBookOnTheSameFile() throws {
        book().learn([3, 0, 0], as: "Priya")
        let people = book().people()
        XCTAssertEqual(people.map(\.name), ["Priya"])
        XCTAssertEqual(people[0].samples, 1)
        XCTAssertEqual(people[0].updated, day)
        // stored at unit length, so each voice weighs the same.
        XCTAssertEqual(people[0].centroid, [1, 0, 0])
    }

    func testTheFileIsPrivate() throws {
        book().learn([1, 0, 0], as: "Priya")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(folder, 0o700)
    }

    func testAnotherVoiceOfThePersonIsAveraged() {
        let book = book()
        book.learn([1, 0], as: "Priya")
        book.learn([0, 1], as: "Priya")
        let priya = book.people()[0]
        XCTAssertEqual(priya.samples, 2)
        XCTAssertEqual(priya.centroid[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(priya.centroid[1], 0.5, accuracy: 1e-6)
    }

    func testAPersonIsFoundWithoutRegardToCaseAndKeepsTheirSpelling() {
        let book = book()
        book.learn([1, 0], as: "Priya")
        book.learn([1, 0], as: "priya")
        XCTAssertEqual(book.people().map(\.name), ["Priya"])
        XCTAssertEqual(book.people()[0].samples, 2)
    }

    func testAVoiceTakenBackOutLeavesTheAverageAsItWas() {
        let book = book()
        book.learn([1, 0], as: "Priya")
        let before = book.people()[0].centroid
        book.learn([0, 1], as: "Priya")
        book.unlearn([0, 1], from: "Priya")
        let after = book.people()[0]
        XCTAssertEqual(after.samples, 1)
        XCTAssertEqual(after.centroid[0], before[0], accuracy: 1e-6)
        XCTAssertEqual(after.centroid[1], before[1], accuracy: 1e-6)
    }

    func testAPersonLeftWithNoVoicesIsForgotten() {
        let book = book()
        book.learn([1, 0], as: "Priya")
        book.unlearn([1, 0], from: "Priya")
        XCTAssertTrue(book.people().isEmpty)
    }

    func testTakingBackFromSomeoneNotThereDoesNothing() {
        let book = book()
        book.learn([1, 0], as: "Priya")
        book.unlearn([1, 0], from: "Rahul")
        XCTAssertEqual(book.people().map(\.name), ["Priya"])
    }

    func testOnePersonCanBeForgottenAndThenEveryone() {
        let book = book()
        book.learn([1, 0], as: "Priya")
        book.learn([0, 1], as: "Rahul")
        book.forget("priya")
        XCTAssertEqual(book.people().map(\.name), ["Rahul"])
        book.forgetAll()
        XCTAssertTrue(book.people().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPeopleAreListedByName() {
        let book = book()
        book.learn([1, 0], as: "rahul")
        book.learn([0, 1], as: "Priya")
        XCTAssertEqual(book.people().map(\.name), ["Priya", "rahul"])
    }

    func testAVoiceThatCannotBeUsedIsNotLearned() {
        let book = book()
        book.learn([], as: "Priya")
        book.learn([0, 0], as: "Priya")
        book.learn([.nan, 1], as: "Priya")
        XCTAssertTrue(book.people().isEmpty)
    }

    func testAnEmbedderThatChangedStartsThePersonAgain() {
        let book = book()
        book.learn([1, 0], as: "Priya")
        book.learn([0, 0, 1], as: "Priya")
        let priya = book.people()[0]
        XCTAssertEqual(priya.samples, 1)
        XCTAssertEqual(priya.centroid, [0, 0, 1])
    }

    func testABookThatCannotBeReadIsEmptyAndTheNextVoiceReplacesIt() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let book = book()
        XCTAssertTrue(book.people().isEmpty)
        book.learn([1, 0], as: "Priya")
        XCTAssertEqual(book.people().map(\.name), ["Priya"])
    }
}

final class MeetingVoicePrintsTests: XCTestCase {
    private var dir: URL!
    private var prints: MeetingVoicePrints!
    private let transcript = URL(fileURLWithPath: "/meetings/2026-10/2026-10-29-1000-zoom.md")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-prints-\(UUID().uuidString)")
        prints = MeetingVoicePrints(folder: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAMeetingsVoicesAreKeptForItsTranscript() {
        let took = prints.keep(
            ["them 1": [1, 0], "them 2": [0, 1]], taught: ["them 1": "Priya"],
            for: transcript, replacing: false)
        XCTAssertEqual(took, ["them 1", "them 2"])
        let kept = prints.prints(for: transcript)
        XCTAssertEqual(kept["them 1"], .init(embedding: [1, 0], taught: "Priya"))
        XCTAssertEqual(kept["them 2"], .init(embedding: [0, 1], taught: nil))
        XCTAssertTrue(prints.prints(for: URL(fileURLWithPath: "/other.md")).isEmpty)
    }

    func testTheFilesArePrivate() throws {
        prints.keep(["them 1": [1, 0]], taught: [:], for: transcript, replacing: false)
        let file = dir.appendingPathComponent(transcript.lastPathComponent + ".json")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
    }

    func testASessionRecordedIntoTheFileAddsOnlyLabelsItHasNot() {
        prints.keep(["them 1": [1, 0]], taught: ["them 1": "Priya"], for: transcript, replacing: false)
        let took = prints.keep(
            ["them 1": [0, 1], "them 2": [0, 1]], taught: ["them 1": "Rahul"],
            for: transcript, replacing: false)
        XCTAssertEqual(took, ["them 2"])
        let kept = prints.prints(for: transcript)
        XCTAssertEqual(kept["them 1"], .init(embedding: [1, 0], taught: "Priya"))
        XCTAssertEqual(kept["them 2"]?.embedding, [0, 1])
    }

    func testATranscriptMadeAgainReplacesThem() {
        prints.keep(["them 1": [1, 0]], taught: [:], for: transcript, replacing: false)
        prints.keep(["them 2": [0, 1]], taught: [:], for: transcript, replacing: true)
        XCTAssertEqual(Set(prints.prints(for: transcript).keys), ["them 2"])
    }

    func testWhatItWasTaughtAsCanBeChanged() {
        prints.keep(["them 1": [1, 0]], taught: [:], for: transcript, replacing: false)
        prints.setTaught("Priya", label: "them 1", for: transcript)
        XCTAssertEqual(prints.prints(for: transcript)["them 1"]?.taught, "Priya")
        prints.setTaught(nil, label: "them 1", for: transcript)
        XCTAssertNil(prints.prints(for: transcript)["them 1"]?.taught)
        prints.setTaught("Nobody", label: "them 9", for: transcript)
        XCTAssertNil(prints.prints(for: transcript)["them 9"])
    }

    func testTheyGoWithTheMeetingAndAllOfThemGoTogether() {
        let other = URL(fileURLWithPath: "/meetings/2026-10/2026-10-30-1000-zoom.md")
        prints.keep(["them 1": [1, 0]], taught: [:], for: transcript, replacing: false)
        prints.keep(["them 1": [1, 0]], taught: [:], for: other, replacing: false)
        prints.discard(for: transcript)
        XCTAssertTrue(prints.prints(for: transcript).isEmpty)
        XCTAssertFalse(prints.prints(for: other).isEmpty)
        prints.discardAll()
        XCTAssertTrue(prints.prints(for: other).isEmpty)
    }

    func testNothingHeardKeepsNothing() {
        prints.keep([:], taught: [:], for: transcript, replacing: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testAnOldMeetingsPrintsAreSweptAwayByTheNextMeeting() throws {
        let old = URL(fileURLWithPath: "/meetings/2026-01/old.md")
        prints.keep(["them 1": [1, 0]], taught: [:], for: old, replacing: false)
        let file = dir.appendingPathComponent("old.md.json")
        let longAgo = Date().addingTimeInterval(-MeetingVoicePrints.keptFor - 3_600)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: file.path)
        prints.keep(["them 1": [1, 0]], taught: [:], for: transcript, replacing: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(prints.prints(for: transcript).isEmpty)
    }
}
