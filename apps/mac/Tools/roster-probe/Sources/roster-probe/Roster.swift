import Foundation

/// finds the nodes that look like a person's name, and the "tile" each belongs
/// to: the largest ancestor that holds that one name and no other. the speaking
/// indicator, if the app exposes one, is something inside (or on) that tile.
enum Roster {
    static let nameAttrs = ["AXTitle", "AXDescription", "AXValue", "AXLabel", "AXHelp", "AXPlaceholderValue"]
    static let skipRoles: Set<String> = ["AXWindow", "AXApplication", "AXScrollBar", "AXMenuBar", "AXMenuBarItem", "AXWebArea"]

    static func annotate(_ roots: [Snap], webOnly: Bool = false) {
        var nameNodes: [Snap] = []
        var all: [Snap] = []
        for r in roots { all += AX.flatten(r) }
        for node in all {
            guard !skipRoles.contains(node.role) else { continue }
            if webOnly && !insideWebArea(node) { continue }
            var best: NameGuess?
            for attr in nameAttrs {
                guard let text = node.attrs[attr], let g = Names.guess(text, attr: attr) else { continue }
                if best == nil || (g.how == "exact" && best?.how != "exact") { best = g }
            }
            if let best { node.name = best; nameNodes.append(node) }
        }

        var namesUnder: [ObjectIdentifier: Set<String>] = [:]
        for node in nameNodes {
            var cur: Snap? = node
            while let c = cur {
                namesUnder[ObjectIdentifier(c), default: []].insert(node.name!.name)
                cur = c.parent
            }
        }
        for node in nameNodes {
            let mine: Set<String> = [node.name!.name]
            var root = node
            var levels = 0
            while let p = root.parent, levels < 12, p.subtreeSize <= 400, namesUnder[ObjectIdentifier(p)] == mine {
                root = p
                levels += 1
            }
            func mark(_ n: Snap) {
                if n.tileName == nil {
                    n.tileName = node.name!.name
                    n.tilePath = root.path
                    n.rel = String(n.path.dropFirst(root.path.count))
                    if n.rel!.isEmpty { n.rel = "." }
                }
                for c in n.children { mark(c) }
            }
            mark(root)
        }
    }

    static func insideWebArea(_ n: Snap) -> Bool {
        var cur = n.parent
        while let c = cur { if c.role == "AXWebArea" { return true }; cur = c.parent }
        return false
    }

    /// distinct names with where they were seen, for the console summary.
    static func summary(_ roots: [Snap]) -> [(name: String, likely: Bool, places: [String])] {
        var order: [String] = []
        var found: [String: (Bool, [String])] = [:]
        for r in roots {
            for n in AX.flatten(r) {
                guard let g = n.name else { continue }
                if found[g.name] == nil { order.append(g.name); found[g.name] = (g.likely, []) }
                found[g.name]!.1.append("\(n.role).\(g.attr)")
            }
        }
        return order.map { ($0, found[$0]!.0, found[$0]!.1) }
    }
}
