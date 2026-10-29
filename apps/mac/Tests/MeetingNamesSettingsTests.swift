import XCTest

/// what a transcript calls you, and whether voices are remembered: two
/// settings, stored the way the meeting settings are.
@MainActor
final class MeetingNamesSettingsTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        suiteName = "AndrewDictateTests.MeetingNames.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    private func settings() -> AppSettings {
        AppSettings(userDefaults: userDefaults, accountName: "Suriya Narayanan")
    }

    func testYouAreTheMacAccountsNameUntilSomeoneSaysOtherwise() {
        XCTAssertEqual(settings().yourName, "Suriya Narayanan")
    }

    func testAChosenNameSurvivesARelaunchAndSoDoesAnEmptyOne() {
        let first = settings()
        first.yourName = "Suriya"
        XCTAssertEqual(settings().yourName, "Suriya")

        // emptied on purpose: they stay `you`, and the account name does
        // not come back.
        first.yourName = ""
        XCTAssertEqual(settings().yourName, "")
        XCTAssertNil(SpeakerNames.clean(settings().yourName))
    }

    func testVoicesAreRememberedUntilSomeoneSaysOtherwise() {
        XCTAssertTrue(settings().rememberVoices)
        let first = settings()
        first.rememberVoices = false
        XCTAssertFalse(settings().rememberVoices)
        first.rememberVoices = true
        XCTAssertTrue(settings().rememberVoices)
    }

    /// `SpeakerNaming.live` reads the switch without the settings object.
    func testTheSwitchIsStoredWhereTheRenamerLooks() {
        let first = settings()
        first.rememberVoices = false
        XCTAssertEqual(userDefaults.object(forKey: AppSettings.rememberVoicesKey) as? Bool, false)
    }
}

@MainActor
final class MeetingLibraryNamingTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [String] = []
        var all: [String] { lock.withLock { _all } }
        func add(_ call: String) { lock.withLock { _all.append(call) } }
    }

    private func library(files: MeetingsLibraryModel.Files) -> MeetingsLibraryModel {
        MeetingsLibraryModel(load: { [] }, files: files, delete: { _ in })
    }

    private func files(_ calls: Calls, failing: Bool = false) -> MeetingsLibraryModel.Files {
        MeetingsLibraryModel.Files(
            read: { _ in throw CocoaError(.fileNoSuchFile) },
            stamp: { _ in nil },
            setTitle: { _, _ in },
            nameSpeaker: { shown, name, url in
                calls.add("\(shown)>\(name ?? "-")@\(url.lastPathComponent)")
                if failing { throw CocoaError(.fileWriteUnknown) }
            },
            knownNames: { ["Priya"] })
    }

    func testANameIsGivenToTheFileAndABlankOneTakesTheLabelBack() async {
        let calls = Calls()
        let library = library(files: files(calls))
        let url = URL(fileURLWithPath: "/m/a.md")
        var changed: [URL] = []
        library.onChange = { changed.append($0) }

        let named = await library.nameSpeaker("them 2", as: "  Priya ", in: url)
        let back = await library.nameSpeaker("Priya", as: "", in: url)

        XCTAssertTrue(named)
        XCTAssertTrue(back)
        XCTAssertEqual(calls.all, ["them 2>Priya@a.md", "Priya>-@a.md"])
        XCTAssertEqual(changed, [url, url])
        XCTAssertNil(library.failure)
    }

    func testAFailureIsSaidAndNothingIsToldToChange() async {
        let library = library(files: files(Calls(), failing: true))
        var changed = 0
        library.onChange = { _ in changed += 1 }

        let named = await library.nameSpeaker("them 2", as: "Priya", in: URL(fileURLWithPath: "/m/a.md"))

        XCTAssertFalse(named)
        XCTAssertNotNil(library.failure)
        XCTAssertEqual(changed, 0)
    }

    func testTheSuggestionsAreThePeopleTheMacKnows() {
        XCTAssertEqual(library(files: files(Calls())).knownNames(), ["Priya"])
    }
}
