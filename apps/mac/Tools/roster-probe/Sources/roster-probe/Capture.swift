import ApplicationServices
import AppKit

/// one reading of the call app's windows, shared by dump and watch.
struct Capture {
    struct Item {
        var window: Apps.Window
        var root: Snap
    }
    var items: [Item]
    var stats: AX.WalkStats
    var millis: Int
    var allWindows: [Apps.Window]

    /// numbers windows so a window keeps its number while its title changes and
    /// while the windows reorder.
    final class Registry {
        private var known: [AXUIElement] = []
        func number(_ el: AXUIElement) -> Int {
            if let i = known.firstIndex(where: { CFEqual($0, el) }) { return i }
            known.append(el)
            return known.count - 1
        }
    }

    static func take(_ target: Target, windowFilter: String?, limits: AX.Limits, registry: Registry = Registry()) -> Capture {
        let started = Date()
        let all = Apps.windows(of: target)
        let chosen = Apps.select(all, filter: windowFilter, browser: Apps.isBrowser(target.bundleId))
        var stats = AX.WalkStats()
        var items: [Item] = []
        for w in chosen {
            let root = AX.walk(w.element, limits: limits, stats: &stats, rootKey: "W\(registry.number(w.element))", rootIndex: 0)
            items.append(Item(window: w, root: root))
        }
        Roster.annotate(items.map { $0.root }, webOnly: Apps.isBrowser(target.bundleId))
        return Capture(items: items, stats: stats, millis: Int(Date().timeIntervalSince(started) * 1000), allWindows: all)
    }

    var hasWebContent: Bool {
        items.contains { AX.flatten($0.root).contains { $0.role == "AXWebArea" && !$0.children.isEmpty } }
    }

    /// true when the app should have a web tree (a browser) and none has appeared yet.
    static func takeWaitingForWeb(_ target: Target, windowFilter: String?, limits: AX.Limits, wait: Bool, registry: Registry = Registry()) -> Capture {
        var cap = take(target, windowFilter: windowFilter, limits: limits, registry: registry)
        guard wait, Apps.isBrowser(target.bundleId) else { return cap }
        var tries = 0
        while !cap.hasWebContent && tries < 6 {
            tries += 1
            Thread.sleep(forTimeInterval: 0.8)
            var l = limits
            l.deadline = Date().addingTimeInterval(20)
            cap = take(target, windowFilter: windowFilter, limits: l, registry: registry)
        }
        return cap
    }
}

enum Session {
    /// resolves the app, turns on its web accessibility if asked to, and hands back
    /// the object that puts the flags back.
    static func open(_ args: Args) throws -> (target: Target, enabler: Enabler, report: [String: String]) {
        try AX.requireTrust()
        guard let spec = args.string("app") else { throw ProbeError("--app is required (zoom, chrome, arc, safari, teams, or a bundle id)") }
        let target = try Apps.resolve(spec)
        let enabler = Enabler()
        var report: [String: String] = [:]
        if !args.switches.contains("no-enable"), Apps.needsEnabling(target.bundleId) {
            report = enabler.enable(target.element)
        }
        return (target, enabler, report)
    }
}

enum Json {
    static func data(_ object: Any, pretty: Bool) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    static func line(_ object: Any) -> Data {
        var d = (try? data(object, pretty: false)) ?? Data("{}".utf8)
        d.append(0x0a)
        return d
    }

    static func rect(_ r: CGRect?) -> [String: Int]? {
        guard let r else { return nil }
        return ["x": Int(r.minX), "y": Int(r.minY), "w": Int(r.width), "h": Int(r.height)]
    }
}
