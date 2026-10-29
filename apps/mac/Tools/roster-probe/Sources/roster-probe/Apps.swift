import ApplicationServices
import AppKit

struct Target {
    let app: NSRunningApplication
    var pid: pid_t { app.processIdentifier }
    var bundleId: String { app.bundleIdentifier ?? "?" }
    var name: String { app.localizedName ?? bundleId }
    var element: AXUIElement { AX.appElement(pid) }
}

enum Apps {
    /// short names for the call apps, and the bundle ids they may run under.
    static let aliases: [String: [String]] = [
        "zoom": ["us.zoom.xos"],
        "chrome": ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"],
        "arc": ["company.thebrowser.Browser"],
        "safari": ["com.apple.Safari", "com.apple.SafariTechnologyPreview"],
        "teams": ["com.microsoft.teams2", "com.microsoft.teams"],
        "edge": ["com.microsoft.edgemac"],
        "brave": ["com.brave.Browser"],
        "firefox": ["org.mozilla.firefox"],
        "webex": ["Cisco-Systems.Spark"],
        "slack": ["com.tinyspeck.slackmacgap"],
        "facetime": ["com.apple.FaceTime"],
    ]

    static var callCapable: Set<String> { Set(aliases.values.flatMap { $0 }) }

    /// bundle ids that build their web accessibility tree only when a client asks.
    static func needsEnabling(_ bundleId: String) -> Bool {
        let b = bundleId.lowercased()
        return b.hasPrefix("com.google.chrome") || b.hasPrefix("company.thebrowser") || b.hasPrefix("com.microsoft.edgemac")
            || b.hasPrefix("com.brave") || b.hasPrefix("com.microsoft.teams") || b == "us.zoom.xos"
            || b.hasPrefix("com.tinyspeck") || b.hasPrefix("cisco-systems") || b.hasPrefix("org.mozilla")
    }

    static func isBrowser(_ bundleId: String) -> Bool {
        let b = bundleId.lowercased()
        return b.hasPrefix("com.google.chrome") || b.hasPrefix("company.thebrowser") || b.hasPrefix("com.apple.safari")
            || b.hasPrefix("com.microsoft.edgemac") || b.hasPrefix("com.brave") || b.hasPrefix("org.mozilla")
    }

    static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    static func resolve(_ spec: String) throws -> Target {
        let all = running()
        let wanted = aliases[spec.lowercased()] ?? [spec]
        for id in wanted {
            if let app = all.first(where: { $0.bundleIdentifier?.lowercased() == id.lowercased() }) { return Target(app: app) }
        }
        // a name, as a last resort ("Microsoft Teams", "Google Chrome")
        let needle = spec.lowercased()
        let byName = all.filter { ($0.localizedName ?? "").lowercased().contains(needle) }
        if byName.count == 1 { return Target(app: byName[0]) }
        if byName.count > 1 {
            let names = byName.map { "\($0.localizedName ?? "?") (\($0.bundleIdentifier ?? "?"))" }.joined(separator: ", ")
            throw ProbeError("'\(spec)' matches several apps: \(names). pass the bundle id.")
        }
        let known = aliases.keys.sorted().joined(separator: ", ")
        throw ProbeError("no running app matches '\(spec)'. open it first, or pass a bundle id. short names: \(known)")
    }

    // MARK: windows

    struct Window {
        let element: AXUIElement
        let title: String
        let frame: CGRect?
        let minimized: Bool
        let main: Bool
        let focused: Bool
        let subrole: String?
    }

    static func windows(of target: Target) -> [Window] {
        let app = target.element
        var list = AX.elements(app, "AXWindows")
        let main = AX.copy(app, "AXMainWindow").map { $0 as! AXUIElement }
        let focused = AX.copy(app, "AXFocusedWindow").map { $0 as! AXUIElement }
        for extra in [main, focused].compactMap({ $0 }) where !list.contains(where: { CFEqual($0, extra) }) {
            list.append(extra)
        }
        return list.map { el in
            var frame: CGRect?
            var p = CGPoint.zero, s = CGSize.zero
            if let pv = AX.copy(el, "AXPosition"), let sv = AX.copy(el, "AXSize"),
               AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) {
                frame = CGRect(origin: p, size: s)
            }
            return Window(
                element: el,
                title: AX.string(el, "AXTitle") ?? "",
                frame: frame,
                minimized: (AX.copy(el, "AXMinimized") as? Bool) ?? false,
                main: main.map { CFEqual($0, el) } ?? false,
                focused: focused.map { CFEqual($0, el) } ?? false,
                subrole: AX.string(el, "AXSubrole"))
        }
    }

    static let meetingHints = ["meet", "meeting", "zoom", "teams", "call", "webex", "huddle"]

    /// the windows to read. `--window` filters by title substring. without it:
    /// windows whose title looks like a call, else the focused / main window,
    /// else every window of a native app.
    static func select(_ all: [Window], filter: String?, browser: Bool) -> [Window] {
        if let f = filter?.lowercased(), !f.isEmpty {
            return all.filter { $0.title.lowercased().contains(f) }
        }
        let visible = all.filter { !$0.minimized }
        let hinted = visible.filter { w in meetingHints.contains { w.title.lowercased().contains($0) } }
        if !hinted.isEmpty { return hinted }
        if browser {
            if let w = visible.first(where: { $0.focused }) ?? visible.first(where: { $0.main }) ?? visible.first { return [w] }
            return []
        }
        return visible
    }
}

// MARK: list

enum ListCommand {
    static func run(_ args: Args) throws {
        try AX.requireTrust()
        let all = Apps.running()
        let wanted = args.switches.contains("all")
            ? all : all.filter { Apps.callCapable.contains($0.bundleIdentifier ?? "") }
        if wanted.isEmpty {
            print("no call-capable app is running (zoom, chrome, arc, safari, teams, …). --all lists every app.")
            return
        }
        for app in wanted.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            let t = Target(app: app)
            let short = Apps.aliases.first(where: { $0.value.contains(t.bundleId) })?.key
            print("\(t.name)  pid \(t.pid)  \(t.bundleId)" + (short.map { "  --app \($0)" } ?? ""))
            let windows = Apps.windows(of: t)
            if windows.isEmpty { print("    (no windows visible to accessibility)") }
            for (i, w) in windows.enumerated() {
                var flags: [String] = []
                if w.focused { flags.append("focused") }
                if w.main { flags.append("main") }
                if w.minimized { flags.append("minimized") }
                if let sr = w.subrole { flags.append(sr) }
                let size = w.frame.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
                print("    [\(i)] \"\(w.title)\"  \(size)  \(flags.joined(separator: " "))")
            }
        }
    }
}
