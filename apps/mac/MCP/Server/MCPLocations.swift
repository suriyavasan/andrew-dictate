import Foundation

/// where the app keeps what the server reads, found without the app: this
/// is another process, with no `AppSettings` and no `Bundle.main` of the
/// app's. it asks the same questions the app answers, and takes the same
/// answers. read-only: nothing here creates a folder.
struct MCPLocations: Equatable, Sendable {
    /// the folder the `meetings/` folder is in (settings › meetings › save
    /// folder).
    let meetingsParent: URL
    /// the app's live feeds.
    let liveDirectory: URL

    var meetingsFolder: URL {
        meetingsParent.appendingPathComponent(MeetingTranscriptFile.folderName, isDirectory: true)
    }

    /// what the app says about itself in its `Info.plist`, for a server that
    /// lives inside it.
    struct App: Equatable, Sendable {
        let bundleID: String
        let version: String
    }

    /// the app that holds `executable`, found by walking up to a `.app` with
    /// an `Info.plist` that names itself. nil for a server run from a build
    /// folder or a shell, which then speaks for the shipped app.
    static func enclosingApp(of executable: URL?, fileManager: FileManager = .default) -> App? {
        guard var folder = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else {
            return nil
        }
        while folder.path != "/" {
            if folder.pathExtension == "app" {
                let plist = folder.appendingPathComponent("Contents/Info.plist")
                guard let data = fileManager.contents(atPath: plist.path),
                      let info = try? PropertyListSerialization.propertyList(
                        from: data, format: nil) as? [String: Any],
                      let id = info["CFBundleIdentifier"] as? String
                else { return nil }
                return App(bundleID: id, version: info["CFBundleShortVersionString"] as? String ?? "0")
            }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    /// `picked` is the folder settings holds, if anyone picked one. the
    /// rest is the app's own rule when nobody has (`AppSettings`): the
    /// folder the transcripts were first written to if it still has them,
    /// `~/andrew-dictate` otherwise.
    static func resolve(
        bundleID: String,
        picked: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupport: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        fileManager: FileManager = .default
    ) -> MCPLocations {
        let support = applicationSupport
            .appendingPathComponent(AppIdentity.supportDirectoryName(for: bundleID), isDirectory: true)
        return MCPLocations(
            meetingsParent: parent(picked: picked, home: home, fileManager: fileManager),
            liveDirectory: support.appendingPathComponent("live", isDirectory: true))
    }

    private static func parent(picked: String?, home: URL, fileManager: FileManager) -> URL {
        if let picked, !picked.isEmpty {
            return URL(fileURLWithPath: (picked as NSString).expandingTildeInPath, isDirectory: true)
        }
        let legacy = home.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("andrew-dictate", isDirectory: true)
        var isDirectory: ObjCBool = false
        let written = legacy.appendingPathComponent(MeetingTranscriptFile.folderName, isDirectory: true)
        if fileManager.fileExists(atPath: written.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return legacy
        }
        return home.appendingPathComponent("andrew-dictate", isDirectory: true)
    }

    /// the save folder as the app's preferences hold it. `CFPreferences`
    /// reads another app's domain; `UserDefaults` would treat it as its own.
    static func pickedFolder(bundleID: String) -> String? {
        CFPreferencesCopyAppValue(
            meetingsFolderKey as CFString, bundleID as CFString) as? String
    }

    /// the key `AppSettings` writes it under; a test holds the two together.
    static let meetingsFolderKey = "AndrewDictate.meetingsFolder"
}
