import Foundation

// andrew-dictate-mcp: the meetings on this mac, over the model context
// protocol, for an agent (`claude mcp add andrew-dictate -- <this file>`).
// stdio only: a message a line in, an answer a line out. read-only. it is
// started by the agent, once per session, and ends when the agent closes
// its input.
//
//   --bundle-id <id>   read the preferences and the live feeds of that app,
//                      for a build that is not the shipped one. by default,
//                      the app this file is inside.

var bundleOverride: String?
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    switch flag {
    case "--bundle-id":
        bundleOverride = arguments.popFirst()
    case "--help", "-h":
        print("andrew-dictate-mcp [--bundle-id <id>]: the meetings on this mac, over mcp on stdio.")
        exit(0)
    default:
        FileHandle.standardError.write(Data("andrew-dictate-mcp: unknown option \(flag)\n".utf8))
        exit(64)
    }
}

let app = MCPLocations.enclosingApp(of: Bundle.main.executableURL)
let bundleID = bundleOverride ?? app?.bundleID ?? AppIdentity.releaseBundleID
let locations = MCPLocations.resolve(
    bundleID: bundleID, picked: MCPLocations.pickedFolder(bundleID: bundleID))
let server = MCPServer(reader: MeetingsReader(locations: locations), version: app?.version ?? "0")

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let answer = server.respond(to: line) {
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
    }
}
