import XCTest

/// a meetings folder to read, made by the app's own writer: one meeting from
/// before names (`them 2`), one with people named, and a few things in the
/// folder that are not meetings.
final class MCPFixture {
    let root: URL
    let utc = TimeZone(secondsFromGMT: 0)!
    let live: URL
    private(set) var old: URL!
    private(set) var named: URL!

    var locations: MCPLocations {
        MCPLocations(meetingsParent: root, liveDirectory: live)
    }

    static let oldID = "2026-09-03-1000-zoom"
    static let namedID = "2026-10-12-0930-meet"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString)", isDirectory: true)
        live = root.appendingPathComponent("support/live", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        old = try write(MeetingTranscript(
            app: "zoom", started: date("2026-09-03T10:00:00Z"), duration: .seconds(600),
            engine: "whisper-large-v3", gaps: [], recovered: false,
            turns: [
                .init(speaker: .you, at: .seconds(4), text: "we need to ship the budget deck by friday"),
                .init(speaker: .them(1), at: .seconds(20), text: "agreed on the budget for Q4, I will send numbers"),
                .init(speaker: .them(2), at: .seconds(95), text: "I can review the contract today"),
            ]))
        named = try write(MeetingTranscript(
            app: "meet", started: date("2026-10-12T09:30:00Z"), duration: .seconds(3_600),
            engine: "whisper-large-v3", gaps: [], recovered: false,
            title: "q4 planning", youName: "Suriya",
            voices: ["them 1": "Priya", "them 2": "Rahul"],
            turns: [
                .init(speaker: .you, at: .seconds(3), text: "let's start with the roadmap"),
                .init(speaker: .them(1), at: .seconds(15), text: "The roadmap needs the Café integration first"),
                .init(speaker: .them(2), at: .seconds(70), text: "I will own the contract review"),
                .init(speaker: .them(1), at: .seconds(300), text: "budget is approved"),
            ]))
        // what a folder of transcripts also holds.
        try "no front matter here\n".write(
            to: root.appendingPathComponent("meetings/notes.md"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    @discardableResult
    func write(_ transcript: MeetingTranscript) throws -> URL {
        try MeetingTranscriptFile.write(transcript, in: root, timeZone: utc)
    }

    func reader(alive: Bool = true) -> MeetingsReader {
        MeetingsReader(locations: locations, isAlive: { _ in alive })
    }

    /// a feed written by the app's own writer.
    func feed(
        app: String = "zoom", youName: String? = "Suriya", lines: [(LiveLine.Speaker, Int, String)] = [],
        end: URL?? = nil
    ) throws -> LiveFeed.Session {
        let feed = LiveFeed(directory: live, processID: 77, timeZone: utc)
        let session = try XCTUnwrap(feed.begin(
            app: app, started: date("2026-10-14T11:00:00Z"), youName: youName))
        for (speaker, at, text) in lines {
            session.record(LiveLine(speaker: speaker, at: .seconds(at), text: text, isConfirmed: true))
        }
        if let end { session.end(saved: end) }
        return session
    }
}

extension XCTestCase {
    func object(_ json: OrderedJSON, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.pretty.utf8)) as? [String: Any],
            file: file, line: line)
    }
}
