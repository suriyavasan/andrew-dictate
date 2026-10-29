import XCTest

final class AgentSetupTests: XCTestCase {
    func testTheHelperIsInsideTheApp() {
        let app = URL(fileURLWithPath: "/Applications/Andrew Dictate.app")
        XCTAssertEqual(
            AgentSetup.helperURL(in: app).path,
            "/Applications/Andrew Dictate.app/Contents/Helpers/andrew-dictate-mcp")
    }

    func testTheCommandIsTheOneThatIsPasted() {
        let helper = AgentSetup.helperURL(in: URL(fileURLWithPath: "/Applications/Andrew Dictate.app"))
        XCTAssertEqual(
            AgentSetup.command(helper: helper, bundleID: AppIdentity.releaseBundleID),
            #"claude mcp add andrew-dictate -- "/Applications/Andrew Dictate.app/Contents/Helpers/andrew-dictate-mcp""#)
    }

    func testADevelopmentBuildHasItsOwnName() {
        let helper = AgentSetup.helperURL(in: URL(fileURLWithPath: "/tmp/Andrew Dictate Dev.app"))
        XCTAssertEqual(
            AgentSetup.command(helper: helper, bundleID: "gg.jass.dictate.dev"),
            #"claude mcp add andrew-dictate-dev -- "/tmp/Andrew Dictate Dev.app/Contents/Helpers/andrew-dictate-mcp""#)
    }

    func testWhatAShellReadsInsideQuotesIsEscaped() {
        XCTAssertEqual(AgentSetup.quoted(#"/a "b"/$c/`d`\e"#), #""/a \"b\"/\$c/\`d\`\\e""#)
    }

    func testTheNameInTheCommandIsTheOneTheServerAnswersTo() {
        // `claude mcp add <name>` and the server's own name are one word.
        XCTAssertEqual(AgentSetup.serverName(bundleID: AppIdentity.releaseBundleID), "andrew-dictate")
    }
}
