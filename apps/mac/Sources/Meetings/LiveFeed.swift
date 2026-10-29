import Foundation
import os

/// the meeting being recorded, as a file an agent can follow: one json
/// object per line, appended as each live line is settled, in
/// `<support>/live/<meeting>.jsonl`, with `current.jsonl` beside them
/// pointing at the one recording now. an agent that runs `tail -f` on it, or
/// asks the mcp server for it, knows who said what before the meeting has
/// a transcript.
///
/// ```
/// {"v":1,"event":"start","meeting":"2026-10-29-1402-zoom","app":"zoom","started":"…","pid":412,"you":"Suriya"}
/// {"v":1,"meeting":"…","app":"zoom","started":"…","seq":1,"at":"00:00:07","wall":"…","side":"them","speaker":"them","text":"…"}
/// {"v":1,"event":"end","meeting":"…","ended":"…","lines":214,"saved":"/…/2026-10-29-1402-zoom.md"}
/// ```
///
/// only settled lines are written, once each, so a reader never has to
/// take a line back. nothing is written before a meeting starts or after it
/// ends, nothing here is logged, and a failure to write stops the feed
/// quietly: the meeting is the thing that must not be lost, not its mirror.
/// the folder is 0700 and each file 0600, like every file here that holds
/// what people said.
struct LiveFeed: Sendable {
    static let folderName = "live"
    /// the symlink to the feed of the meeting recording now.
    static let currentName = "current.jsonl"
    static let fileExtension = "jsonl"
    static let version = 1
    /// feeds kept on disk, the newest: a meeting an agent wants after the
    /// fact is in its transcript, and these hold the same words.
    static let keptFeeds = 20

    let directory: URL
    var keep = LiveFeed.keptFeeds
    /// told to readers, who ask whether it is alive: a crash leaves a feed
    /// with no end, and `current.jsonl` pointing at it.
    var processID: Int32 = ProcessInfo.processInfo.processIdentifier
    var timeZone: TimeZone = .current
    var now: @Sendable () -> Date = { Date() }

    private static let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "feed")

    static func inSupport(_ support: URL = AppIdentity.supportDirectory) -> LiveFeed {
        LiveFeed(directory: support.appendingPathComponent(folderName, isDirectory: true))
    }

    var current: URL {
        directory.appendingPathComponent(Self.currentName)
    }

    /// opens a feed for a meeting that is starting and writes its first
    /// line. nil when the folder or the file cannot be made: the meeting
    /// goes on without one.
    func begin(app: String, started: Date, youName: String?) -> Session? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // a folder that was already there keeps the mode it had: the
            // mac's umask is no promise about this one.
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            Self.logger.error("the live feed's folder could not be made")
            return nil
        }
        let id = freeID(app: app, started: started)
        let url = directory.appendingPathComponent("\(id).\(Self.fileExtension)")
        guard fileManager.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            Self.logger.error("a live feed could not be made")
            return nil
        }
        let session = Session(
            feed: self, id: id, url: url, handle: handle, app: app,
            started: started, youName: youName)
        session.writeStart()
        point(at: url)
        prune(keeping: url)
        return session
    }

    /// `2026-10-29-1402-zoom`: the name the meeting's file will most likely
    /// have, so an agent can tell the live meeting from its transcript. a
    /// second meeting in the same minute is `-2`.
    private func freeID(app: String, started: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd-HHmm"
        let stem = format.string(from: started) + "-" + MeetingTranscriptFile.slug(app)
        var id = stem
        var n = 2
        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(id).\(Self.fileExtension)").path) {
            id = "\(stem)-\(n)"
            n += 1
        }
        return id
    }

    /// `current.jsonl` is made beside the feed and moved over the old one,
    /// so a reader never finds it missing between two meetings.
    private func point(at url: URL) {
        let temporary = directory.appendingPathComponent(".current-\(processID).tmp")
        try? FileManager.default.removeItem(at: temporary)
        do {
            try FileManager.default.createSymbolicLink(
                atPath: temporary.path, withDestinationPath: url.lastPathComponent)
            guard rename(temporary.path, current.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
        } catch {
            Self.logger.error("the live feed's current link could not be made")
        }
    }

    /// the newest `keep` feeds stay, the one just begun among them. the
    /// names begin with the date, so the oldest sort first.
    func prune(keeping alive: URL? = nil) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        let feeds = names
            .filter { $0.hasSuffix(".\(Self.fileExtension)") && $0 != Self.currentName }
            .sorted(by: >)
        for name in feeds.dropFirst(max(keep, 1)) where name != alive?.lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// one meeting's feed, open from its start to its end. used on the main
    /// actor, where the lines arrive.
    final class Session {
        let id: String
        let url: URL

        private let feed: LiveFeed
        private var handle: FileHandle?
        private let app: String
        private let started: Date
        private let youName: String
        private let clock: ISO8601DateFormatter
        private var written: Set<UUID> = []
        private(set) var lines = 0

        fileprivate init(
            feed: LiveFeed, id: String, url: URL, handle: FileHandle,
            app: String, started: Date, youName: String?
        ) {
            self.feed = feed
            self.id = id
            self.url = url
            self.handle = handle
            self.app = app
            self.started = started
            self.youName = SpeakerNames.clean(youName) ?? MeetingTurn.Speaker.you.label
            clock = MeetingTranscriptFile.iso8601(feed.timeZone)
        }

        var isOpen: Bool { handle != nil }

        fileprivate func writeStart() {
            append(.object([
                ("v", .int(LiveFeed.version)),
                ("event", .string("start")),
                ("meeting", .string(id)),
                ("app", .string(app)),
                ("started", .string(clock.string(from: started))),
                ("pid", .int(Int(feed.processID))),
                ("you", .string(youName)),
            ]))
        }

        /// a settled line, once. a tentative one is left for when it settles,
        /// and a line already written is never written again.
        func record(_ line: LiveLine) {
            guard isOpen, line.isConfirmed, !written.contains(line.id) else { return }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            written.insert(line.id)
            lines += 1
            let side = line.speaker == .you ? "you" : "them"
            append(.object([
                ("v", .int(LiveFeed.version)),
                ("meeting", .string(id)),
                ("app", .string(app)),
                ("started", .string(clock.string(from: started))),
                ("seq", .int(lines)),
                ("at", .string(line.at.stamp)),
                ("wall", .string(clock.string(from: started.addingTimeInterval(line.at.totalSeconds)))),
                ("side", .string(side)),
                ("speaker", .string(line.speaker == .you ? youName : side)),
                ("text", .string(text)),
            ]))
        }

        /// the meeting is over: its last line, the transcript it became (nil
        /// when it became none), and `current.jsonl` is let go if it is
        /// still this meeting's. a second call does nothing.
        func end(saved: URL?) {
            guard isOpen else { return }
            append(.object([
                ("v", .int(LiveFeed.version)),
                ("event", .string("end")),
                ("meeting", .string(id)),
                ("ended", .string(clock.string(from: feed.now()))),
                ("lines", .int(lines)),
                ("saved", .orNull(saved?.path(percentEncoded: false))),
            ]))
            try? handle?.close()
            handle = nil
            let current = feed.current
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path))
                == url.lastPathComponent {
                try? FileManager.default.removeItem(at: current)
            }
        }

        private func append(_ value: OrderedJSON) {
            guard let handle else { return }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((value.rendered + "\n").utf8))
            } catch {
                // the feed stops here and the meeting does not notice.
                LiveFeed.logger.error("the live feed could not be written, so it stops")
                try? handle.close()
                self.handle = nil
            }
        }
    }
}
