import ApplicationServices
import AppKit

enum DumpCommand {
    static func run(_ args: Args) throws {
        let (target, enabler, flags) = try Session.open(args)
        defer { enabler.restore() }
        let depth = try args.int("depth", default: 80)
        let maxNodes = try args.int("max-nodes", default: 40000)
        let seconds = try args.double("budget", default: 60)
        let out = try Files.outputPath(args.string("out"), stem: "dump-\(args.string("app") ?? "app")", ext: "json")

        var limits = AX.Limits(deadline: Date().addingTimeInterval(seconds))
        limits.maxDepth = depth
        limits.maxNodes = maxNodes
        limits.allAttributes = !args.switches.contains("fixed-attrs")

        if !flags.isEmpty { print("accessibility flags on \(target.name): \(flags.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }.joined(separator: "; "))") }
        let cap = Capture.takeWaitingForWeb(target, windowFilter: args.string("window"), limits: limits, wait: true)

        guard !cap.items.isEmpty else {
            let titles = cap.allWindows.map { "\"\($0.title)\"" }.joined(separator: ", ")
            throw ProbeError("no window selected. \(target.name) windows: \(titles.isEmpty ? "none visible to accessibility" : titles). use --window <part of a title>.")
        }

        var doc: [String: Any] = [
            "tool": "roster-probe", "version": 1,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "app": ["name": target.name, "bundleId": target.bundleId, "pid": Int(target.pid)],
            "accessibilityFlags": flags,
            "options": ["depth": depth, "maxNodes": maxNodes, "allAttributes": limits.allAttributes, "window": args.string("window") ?? ""],
            "stats": [
                "nodes": cap.stats.nodes, "milliseconds": cap.millis,
                "cutAtDepth": cap.stats.truncatedDepth, "cutAtNodeLimit": cap.stats.truncatedNodes, "timedOut": cap.stats.timedOut,
            ],
        ]
        doc["windows"] = cap.items.map { item -> [String: Any] in
            ["title": item.window.title, "frame": Json.rect(item.window.frame) as Any, "tree": node(item.root)]
        }
        Files.createPrivate(out)
        try Json.data(doc, pretty: true).write(to: URL(fileURLWithPath: out))

        report(cap, target: target, out: out)
    }

    /// the one JSON shape for a node. `attrs` holds everything not named above it.
    static func node(_ s: Snap) -> [String: Any] {
        var d: [String: Any] = ["role": s.role, "path": s.path]
        let named: [(String, String)] = [
            ("subrole", "AXSubrole"), ("roleDescription", "AXRoleDescription"), ("title", "AXTitle"),
            ("description", "AXDescription"), ("value", "AXValue"), ("help", "AXHelp"),
            ("identifier", "AXIdentifier"), ("domIdentifier", "AXDOMIdentifier"), ("domClassList", "AXDOMClassList"),
            ("selected", "AXSelected"), ("focused", "AXFocused"), ("enabled", "AXEnabled"),
        ]
        var used: Set<String> = ["AXRole"]
        for (key, attr) in named {
            used.insert(attr)
            if let v = s.attrs[attr] { d[key] = v }
        }
        let rest = s.attrs.filter { !used.contains($0.key) }
        if !rest.isEmpty { d["attrs"] = rest }
        if let f = Json.rect(s.frame) { d["frame"] = f }
        if let n = s.name {
            d["nameGuess"] = ["name": n.name, "how": n.how, "attr": n.attr, "likely": n.likely]
        }
        if let t = s.tileName { d["tile"] = ["name": t, "rel": s.rel ?? ""] }
        if !s.children.isEmpty { d["children"] = s.children.map(node) }
        return d
    }

    static func report(_ cap: Capture, target: Target, out: String) {
        var roles: [String: Int] = [:]
        var webAreas = 0, webNodes = 0, withDom = 0, withClasses = 0
        for item in cap.items {
            for n in AX.flatten(item.root) {
                roles[n.role, default: 0] += 1
                if n.role == "AXWebArea" { webAreas += 1; webNodes += n.subtreeSize }
                if n.domId != nil { withDom += 1 }
                if n.classes != nil { withClasses += 1 }
            }
        }
        print("wrote \(out)")
        print("\(target.name): \(cap.items.count) window(s), \(cap.stats.nodes) nodes in \(cap.millis) ms"
              + (cap.stats.truncatedNodes ? "  [cut at the node limit: raise --max-nodes]" : "")
              + (cap.stats.timedOut ? "  [ran out of time: raise --budget]" : "")
              + (cap.stats.truncatedDepth > 0 ? "  [\(cap.stats.truncatedDepth) branches cut at --depth]" : ""))
        for item in cap.items { print("  window \"\(item.window.title)\"  \(item.root.subtreeSize) nodes") }
        print("web areas: \(webAreas) (\(webNodes) nodes under them); nodes with AXDOMIdentifier: \(withDom); with AXDOMClassList: \(withClasses)")
        if Apps.isBrowser(target.bundleId), webAreas == 0 || webNodes <= webAreas * 2 {
            print("warning: the page's accessibility tree is empty. bring the call tab to the front and run it again; see the README.")
        }
        let top = roles.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("roles: \(top)")
        let names = Roster.summary(cap.items.map { $0.root })
        if names.isEmpty {
            print("name-like nodes: none")
        } else {
            print("name-like nodes (\(names.count)):")
            for n in names.prefix(40) {
                print("  \(n.likely ? "likely  " : "possible") \(n.name)  [\(Set(n.places).sorted().joined(separator: ", "))] x\(n.places.count)")
            }
        }
        print("contains names and on-screen text: keep it out of the repo.")
    }
}
