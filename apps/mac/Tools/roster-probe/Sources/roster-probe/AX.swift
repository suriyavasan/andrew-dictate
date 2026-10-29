import ApplicationServices
import AppKit

/// one accessibility element, read once. everything text-like is kept as a
/// string under its AX attribute name, so two snapshots can be compared
/// attribute by attribute without knowing what the attributes mean.
final class Snap {
    var attrs: [String: String] = [:]
    var frame: CGRect?
    var children: [Snap] = []
    weak var parent: Snap?
    var depth = 0
    /// structural path: "AXWindow[0]/AXGroup#id[2]/…", stable while siblings do not move.
    var path = ""
    var subtreeSize = 1

    // filled in by Roster.annotate
    var name: NameGuess?
    var tileName: String?
    var tilePath: String?
    var rel: String?

    var role: String { attrs["AXRole"] ?? "?" }
    var domId: String? { attrs["AXDOMIdentifier"] }
    var classes: String? { attrs["AXDOMClassList"] }
    var identifier: String? { attrs["AXIdentifier"] }
}

enum AX {
    /// read on every node. one round trip each.
    static let fixed: [String] = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue", "AXHelp",
        "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXSelected", "AXFocused", "AXEnabled",
        "AXExpanded", "AXURL", "AXPlaceholderValue", "AXLabel", "AXARIALive", "AXARIACurrent",
        "AXARIABusy", "AXValueDescription", "AXPosition", "AXSize", "AXChildren",
    ]

    /// attributes whose values are other elements or geometry, which the fixed
    /// read already handles or which are not text.
    static let skip: Set<String> = [
        "AXChildren", "AXParent", "AXWindow", "AXTopLevelUIElement", "AXVisibleChildren",
        "AXChildrenInNavigationOrder", "AXSelectedChildren", "AXLinkedUIElements",
        "AXTitleUIElement", "AXServesAsTitleForUIElements", "AXPosition", "AXSize", "AXFrame",
        "AXActivationPoint", "AXSelectedTextRange", "AXVisibleCharacterRange", "AXSharedFocusElements",
        "AXFocusedUIElement", "AXMainWindow", "AXFocusedWindow", "AXWindows", "AXHighestEditableAncestor",
        "AXStartTextMarker", "AXEndTextMarker", "AXSelectedTextMarkerRange", "AXTextInputMarkedRange",
    ]

    static func trusted() -> Bool { AXIsProcessTrusted() }

    static func requireTrust() throws {
        guard trusted() else {
            throw ProbeError("""
            this terminal is not allowed to use Accessibility.
            System Settings > Privacy & Security > Accessibility > switch on your terminal app
            (Terminal, iTerm, Ghostty, Warp, or the editor that runs this), then run the command again.
            """)
        }
    }

    static func appElement(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 2.0)
        return el
    }

    // MARK: reading values

    static func copy(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func attributeNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success, let names = names as? [String] else { return [] }
        return names
    }

    static func actionNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let names = names as? [String] else { return [] }
        return names
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = copy(el, name) else { return nil }
        return text(v)
    }

    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (copy(el, name) as? [AXUIElement]) ?? []
    }

    static func isError(_ v: CFTypeRef) -> Bool {
        CFGetTypeID(v) == AXValueGetTypeID() && AXValueGetType(v as! AXValue) == .axError
    }

    /// a short, comparable string for simple values; nil for elements, geometry
    /// and anything else that is not text.
    static func text(_ v: CFTypeRef, limit: Int = 300) -> String? {
        let id = CFGetTypeID(v)
        if id == CFStringGetTypeID() { return clip(v as! String, limit) }
        if id == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) ? "true" : "false" }
        if id == CFNumberGetTypeID() { return "\(v as! NSNumber)" }
        if id == CFURLGetTypeID() { return clip((v as! URL).absoluteString, limit) }
        if id == CFAttributedStringGetTypeID() { return clip((v as! NSAttributedString).string, limit) }
        if id == CFArrayGetTypeID() {
            let parts = (v as! [Any]).compactMap { item -> String? in
                if let s = item as? String { return s }
                if let n = item as? NSNumber { return "\(n)" }
                return nil
            }
            return parts.isEmpty ? nil : clip(parts.joined(separator: " "), limit)
        }
        return nil
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…[\(s.count)]"
    }

    // MARK: one element

    struct Read {
        var snap: Snap
        var children: [AXUIElement]
    }

    /// reads an element. `allAttributes` also asks it for its attribute names
    /// and reads every simple one it has beyond the fixed set (the ones nobody
    /// has seen yet are the ones that matter).
    static func read(_ el: AXUIElement, allAttributes: Bool) -> Read {
        var names = fixed
        if allAttributes {
            let extra = attributeNames(el).filter { !fixed.contains($0) && !skip.contains($0) && !$0.hasPrefix("_AXPrimary") && $0 != "AXLayoutCount" }
            names += extra
        }
        let snap = Snap()
        var kids: [AXUIElement] = []
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let list = values as? [CFTypeRef] else {
            // fall back to one attribute at a time (an element that dislikes the batch)
            for name in names {
                guard let v = copy(el, name) else { continue }
                absorb(name, v, into: snap, children: &kids)
            }
            return Read(snap: snap, children: kids)
        }
        for (name, v) in zip(names, list) {
            if isError(v) { continue }
            absorb(name, v, into: snap, children: &kids)
        }
        return Read(snap: snap, children: kids)
    }

    private static func absorb(_ name: String, _ v: CFTypeRef, into snap: Snap, children: inout [AXUIElement]) {
        switch name {
        case "AXChildren":
            children = (v as? [AXUIElement]) ?? []
        case "AXPosition":
            var p = CGPoint.zero
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgPoint, &p) {
                snap.frame = CGRect(origin: p, size: snap.frame?.size ?? .zero)
            }
        case "AXSize":
            var s = CGSize.zero
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgSize, &s) {
                snap.frame = CGRect(origin: snap.frame?.origin ?? .zero, size: s)
            }
        default:
            if let t = text(v), !t.isEmpty { snap.attrs[name] = t }
        }
    }

    // MARK: a tree

    struct Limits {
        var maxDepth = 80
        var maxNodes = 30000
        var deadline: Date
        var allAttributes = true
    }

    struct WalkStats {
        var nodes = 0
        var truncatedDepth = 0
        var truncatedNodes = false
        var timedOut = false
    }

    /// reads an element and everything under it, within the limits, then gives
    /// every node its path.
    static func walk(_ el: AXUIElement, limits: Limits, stats: inout WalkStats, rootKey: String = "W0", rootIndex: Int = 0) -> Snap {
        let root = build(el, parent: nil, depth: 0, limits: limits, stats: &stats)
        assignPaths(root, prefix: "", index: rootIndex, rootKey: rootKey)
        return root
    }

    private static func build(_ el: AXUIElement, parent: Snap?, depth: Int, limits: Limits, stats: inout WalkStats) -> Snap {
        let r = read(el, allAttributes: limits.allAttributes)
        let snap = r.snap
        snap.parent = parent
        snap.depth = depth
        stats.nodes += 1
        if r.children.isEmpty { return snap }
        if depth >= limits.maxDepth { stats.truncatedDepth += 1; return snap }
        for child in r.children {
            if stats.nodes >= limits.maxNodes { stats.truncatedNodes = true; break }
            if Date() > limits.deadline { stats.timedOut = true; break }
            let c = build(child, parent: snap, depth: depth + 1, limits: limits, stats: &stats)
            snap.children.append(c)
            snap.subtreeSize += c.subtreeSize
        }
        return snap
    }

    static func baseKey(_ s: Snap) -> String {
        let id = s.domId ?? s.identifier
        if let id, !id.isEmpty { return "\(s.role)#\(clip(id, 40))" }
        return s.role
    }

    /// "Role#id[n]": n counts earlier siblings with the same role and id.
    private static func assignPaths(_ node: Snap, prefix: String, index: Int, rootKey: String) {
        node.path = prefix + "/" + (prefix.isEmpty ? rootKey : baseKey(node)) + "[\(index)]"
        var seen: [String: Int] = [:]
        for c in node.children {
            let base = baseKey(c)
            let n = seen[base, default: 0]
            seen[base] = n + 1
            assignPaths(c, prefix: node.path, index: n, rootKey: rootKey)
        }
    }

    static func flatten(_ root: Snap) -> [Snap] {
        var out: [Snap] = []
        func go(_ n: Snap) { out.append(n); for c in n.children { go(c) } }
        go(root)
        return out
    }
}

/// the flags that make Chromium and Electron apps build their web accessibility
/// tree for a client that asks. they are read first, set only if they were off,
/// and put back by `restore`.
final class Enabler {
    private var changed: [(AXUIElement, String, Bool)] = []

    static let flags = ["AXEnhancedUserInterface", "AXManualAccessibility"]

    func enable(_ app: AXUIElement) -> [String: String] {
        var report: [String: String] = [:]
        for flag in Enabler.flags {
            let before = AX.copy(app, flag)
            let was = (before as? Bool) ?? (before as? NSNumber)?.boolValue
            if was == true { report[flag] = "already on"; continue }
            // Chromium answers a successful set with an error code (-25208), so the
            // return value cannot be trusted: read the flag back instead.
            let err = AXUIElementSetAttributeValue(app, flag as CFString, kCFBooleanTrue)
            let after = AX.copy(app, flag)
            let now = (after as? Bool) ?? (after as? NSNumber)?.boolValue
            if now == true {
                changed.append((app, flag, false))
                report[flag] = "set (was \(was.map { $0 ? "on" : "off" } ?? "unreadable"))"
            } else if err == .success {
                // electron apps take AXManualAccessibility but never read it back
                changed.append((app, flag, false))
                report[flag] = "set (cannot be read back)"
            } else {
                report[flag] = "not accepted (\(err.rawValue))"
            }
        }
        return report
    }

    func restore() {
        for (app, flag, was) in changed {
            AXUIElementSetAttributeValue(app, flag as CFString, was ? kCFBooleanTrue : kCFBooleanFalse)
        }
        changed.removeAll()
    }
}
