import XCTest

final class MCPLocationsTests: XCTestCase {
    private var home: URL!
    private var support: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-home-\(UUID().uuidString)", isDirectory: true)
        support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { [home] in try? FileManager.default.removeItem(at: home!) }
    }

    private func resolve(_ bundleID: String = AppIdentity.releaseBundleID, picked: String? = nil) -> MCPLocations {
        MCPLocations.resolve(bundleID: bundleID, picked: picked, home: home, applicationSupport: support)
    }

    func testThePreferenceIsReadUnderTheKeyTheAppWritesIt() {
        XCTAssertEqual(MCPLocations.meetingsFolderKey, AppSettings.meetingsFolderKey)
    }

    func testAPickedFolderIsWhereTheMeetingsAre() {
        let locations = resolve(picked: "/Volumes/notes/andrew")
        XCTAssertEqual(locations.meetingsParent.path, "/Volumes/notes/andrew")
        XCTAssertEqual(locations.meetingsFolder.path, "/Volumes/notes/andrew/meetings")
    }

    func testNobodyPickingIsTheDefaultFolder() {
        XCTAssertEqual(resolve().meetingsParent.path, home.appendingPathComponent("andrew-dictate").path)
        XCTAssertEqual(resolve(picked: "").meetingsParent.path, home.appendingPathComponent("andrew-dictate").path)
    }

    func testTheFolderTranscriptsWereFirstWrittenToIsKeptWhileItHasThem() throws {
        let legacy = home.appendingPathComponent("Documents/andrew-dictate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        XCTAssertEqual(resolve().meetingsParent.path, legacy.path)
    }

    func testTheLiveFeedsAreInTheSupportFolderOfTheAppAsked() {
        XCTAssertEqual(
            resolve().liveDirectory.path,
            support.appendingPathComponent("Andrew Dictate/live").path)
        XCTAssertEqual(
            resolve("gg.jass.dictate.dev").liveDirectory.path,
            support.appendingPathComponent("Andrew Dictate Dev/live").path)
        XCTAssertEqual(
            resolve("gg.jass.dictate.dev").liveDirectory.path,
            LiveFeed.inSupport(support.appendingPathComponent(AppIdentity.supportDirectoryName(for: "gg.jass.dictate.dev"))).directory.path)
    }

    func testTheAppAFileIsInsideIsFoundFromItsInfoPlist() throws {
        let app = home.appendingPathComponent("Andrew Dictate Dev.app/Contents", isDirectory: true)
        let helper = app.appendingPathComponent("Helpers/andrew-dictate-mcp")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: helper)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "gg.jass.dictate.dev", "CFBundleShortVersionString": "0.13.1",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertEqual(
            MCPLocations.enclosingApp(of: helper),
            MCPLocations.App(bundleID: "gg.jass.dictate.dev", version: "0.13.1"))
    }

    func testAFileOutsideAnyAppIsNoApp() {
        XCTAssertNil(MCPLocations.enclosingApp(of: home.appendingPathComponent("andrew-dictate-mcp")))
        XCTAssertNil(MCPLocations.enclosingApp(of: nil))
    }
}
