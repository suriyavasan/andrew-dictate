import Foundation

/// the one line that teaches an agent about the mcp server in this app, as
/// settings › meetings shows it. pure, so the exact text people paste into a
/// terminal can be pinned in a test.
enum AgentSetup {
    /// the server's executable, in the app's `Contents/Helpers`.
    static let helperName = "andrew-dictate-mcp"

    /// where the build puts it, inside the app at `app`.
    static func helperURL(in app: URL) -> URL {
        app.appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperName)
    }

    /// what the agent calls the server. a development build is a different
    /// app with its own meetings, and sits beside the shipped one under its
    /// own name rather than replacing it.
    static func serverName(bundleID: String) -> String {
        bundleID == AppIdentity.releaseBundleID ? "andrew-dictate" : "andrew-dictate-dev"
    }

    /// `claude mcp add andrew-dictate -- "/Applications/Andrew Dictate.app/…"`.
    /// the path is quoted because the app's name has a space in it, and
    /// whatever a shell would still read inside quotes is escaped.
    static func command(helper: URL, bundleID: String = AppIdentity.bundleID) -> String {
        "claude mcp add \(serverName(bundleID: bundleID)) -- \(quoted(helper.path(percentEncoded: false)))"
    }

    static func quoted(_ path: String) -> String {
        var out = "\""
        for character in path {
            if "\\\"$`".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out + "\""
    }
}
