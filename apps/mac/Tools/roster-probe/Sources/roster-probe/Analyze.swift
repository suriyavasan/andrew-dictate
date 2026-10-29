import Foundation

/// reads a watch log and says what it found. everything here is a heuristic over
/// the events, so the numbers are printed, not hidden behind a verdict.
enum AnalyzeCommand {
    struct Ev {
        let t: Double
        let kind: String
        let d: [String: Any]
        func s(_ k: String) -> String? { d[k] as? String }
        func b(_ k: String) -> Bool? { d[k] as? Bool }
    }

    struct Sighting {
        var name: String
        var path: String
        var rel: String
        var role: String
        var attr: String
        var how: String
        var likely: Bool
        var classes: String
        var domId: String
        var from: Double
        var to: Double?
    }

    static func run(_ args: Args) throws {
        guard let file = args.positional.first else { throw ProbeError("analyze needs a watch log: roster-probe analyze file.jsonl") }
        let spanLimit = try args.int("spans", default: 8)
        let text = try String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8)
        var events: [Ev] = []
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let kind = obj["kind"] as? String else { continue }
            let t = (obj["t"] as? NSNumber)?.doubleValue ?? 0
            events.append(Ev(t: t, kind: kind, d: obj))
        }
        guard !events.isEmpty else { throw ProbeError("no events in \(file)") }

        var report: [String] = []
        func say(_ s: String = "") { report.append(s); print(s) }

        let start = events.first { $0.kind == "start" }
        let end = events.first { $0.kind == "end" }
        let duration = end?.t ?? events.map { $0.t }.max() ?? 0
        let startDate = start.flatMap { $0.s("iso") }.flatMap { iso($0) }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        func clockOnly(_ t: Double) -> String {
            guard let d = startDate else { return "?" }
            return clock.string(from: d.addingTimeInterval(t))
        }
        func at(_ t: Double) -> String {
            let sec = String(format: "%.1fs", t)
            guard let d = startDate else { return sec }
            return "\(sec) \(clock.string(from: d.addingTimeInterval(t)))"
        }

        // MARK: coverage
        say("== coverage")
        say("app: \(start?.s("app") ?? "?")   log: \(String(format: "%.1f", duration)) s")
        if let end {
            say("samples: \(end.d["samples"] ?? "?")   nodes per sample: \(end.d["nodes"] ?? "?")   read time per sample: median \(end.d["walkMsMedian"] ?? "?") ms, max \(end.d["walkMsMax"] ?? "?") ms")
            if end.b("stoppedEarly") == true { say("stopped early with Ctrl-C") }
        } else {
            say("no end record: the run was killed. results below are still valid.")
        }
        let cut = events.filter { $0.kind == "tick" && $0.b("cut") == true }.count
        if cut > 0 { say("warning: \(cut) tick(s) hit the node or time limit: the tree was cut. raise --max-nodes or narrow with --window.") }
        let bulk = events.filter { $0.kind == "bulk" }.reduce(0) { $0 + (($1.d["dropped"] as? Int) ?? 0) }
        if bulk > 0 { say("note: \(bulk) change events were dropped in busy samples (the tree was rebuilt: a panel opened, or tiles moved).") }
        let muted = events.filter { $0.kind == "muted" }.count
        if muted > 0 { say("note: \(muted) attribute(s) changed so often they were muted (clocks, counters).") }

        // MARK: names
        var sightings: [Sighting] = []
        var open: [String: Int] = [:]
        for e in events where e.kind == "name" {
            guard let path = e.s("path"), let name = e.s("name") else { continue }
            if e.b("present") == true {
                if let i = open[path] { sightings[i].to = e.t }
                sightings.append(Sighting(
                    name: name, path: path, rel: e.s("rel") ?? "", role: e.s("role") ?? "?", attr: e.s("nameAttr") ?? "?",
                    how: e.s("nameHow") ?? "?", likely: e.b("nameLikely") ?? false, classes: e.s("classes") ?? "",
                    domId: e.s("domId") ?? "", from: e.t, to: nil))
                open[path] = sightings.count - 1
            } else if let i = open[path] {
                sightings[i].to = e.t
                open[path] = nil
            }
        }
        say()
        say("== names (nodes whose text looks like a person's name)")
        let byName = Dictionary(grouping: sightings, by: { $0.name })
        let nameRows = byName.map { (name: $0.key, items: $0.value) }.sorted {
            let a = $0.items.contains { $0.likely }, b = $1.items.contains { $0.likely }
            return a != b ? a : ($0.items.first!.from, $0.name) < ($1.items.first!.from, $1.name)
        }
        if nameRows.isEmpty { say("none found. the tree has no text that looks like a name; look at the baseline dump.") }
        for row in nameRows {
            let secs = union(row.items.map { ($0.from, $0.to ?? duration) })
            let places = Set(row.items.map { "\($0.role).\($0.attr)" }).sorted().joined(separator: ", ")
            let flag = row.items.contains { $0.likely } ? "likely  " : (row.items.first!.how == "self" ? "self    " : "possible")
            say(String(format: "  %@ %@  seen %.0f s of %.0f s  at %@  (%d place%@)", flag, row.name, secs, duration, places, row.items.count, row.items.count == 1 ? "" : "s"))
        }

        // a label whose text changes over time at one path: speaker view, or a list that reorders
        say()
        say("== labels that change who they name (speaker view shows the active speaker like this)")
        let byPath = Dictionary(grouping: sightings, by: { $0.path })
        let changing = byPath.filter { Set($0.value.map { $0.name }).count >= 2 && $0.value.count >= 3 }
            .sorted { $0.value.count > $1.value.count }
        if changing.isEmpty { say("  none") }
        for (path, items) in changing.prefix(5) {
            say("  \(shortPath(path))   [\(items[0].role) \(items[0].classes)]  \(items.count) changes, \(Set(items.map { $0.name }).count) names")
            for s in items.sorted(by: { $0.from < $1.from }).prefix(spanLimit * 2) {
                say("      \(at(s.from))  \(s.name)")
            }
        }

        // MARK: toggles
        struct Step { var t: Double; var old: String; var new: String; var name: String; var classes: String; var domId: String; var ident: String; var role: String; var path: String }
        struct Key: Hashable { var rel: String; var attr: String; var role: String; var extra: String }
        var groups: [Key: [String: [Step]]] = [:]   // key -> tilePath -> steps
        var outside: [Key: [Step]] = [:]
        for e in events where ["changed", "appeared", "disappeared"].contains(e.kind) {
            let attr: String, old: String, new: String
            switch e.kind {
            case "changed": attr = e.s("attr") ?? "?"; old = e.s("old") ?? "∅"; new = e.s("new") ?? "∅"
            case "appeared": attr = "(present)"; old = "absent"; new = "present"
            default: attr = "(present)"; old = "present"; new = "absent"
            }
            if attr == "position" || attr == "size" || attr == "frame" { continue }
            let step = Step(t: e.t, old: old, new: new, name: e.s("tile") ?? "", classes: e.s("classes") ?? "",
                            domId: e.s("domId") ?? "", ident: e.s("ident") ?? "", role: e.s("role") ?? "?", path: e.s("path") ?? "")
            let extra = attr == "(present)" ? step.classes : ""
            if let tilePath = e.s("tilePath") {
                groups[Key(rel: e.s("rel") ?? "", attr: attr, role: step.role, extra: extra), default: [:]][tilePath, default: []].append(step)
            } else {
                outside[Key(rel: e.s("path") ?? "", attr: attr, role: step.role, extra: extra), default: []].append(step)
            }
        }

        struct Candidate {
            var key: Key
            var values: [String: Double]
            var active: String
            var perName: [String: (changes: Int, spans: [(Double, Double)])]
            var overlap: Double
            var example: Step
            var instances: Int
        }
        var candidates: [Candidate] = []
        var highCardinality: [(Key, Int, Int)] = []
        for (key, instances) in groups {
            var values: [String: Double] = [:]
            var timelines: [String: [(Double, Double, String)]] = [:]
            for (tilePath, steps) in instances {
                let sorted = steps.sorted { $0.t < $1.t }
                var cur = sorted[0].old
                var from = 0.0
                var line: [(Double, Double, String)] = []
                for s in sorted { line.append((from, s.t, cur)); values[cur, default: 0] += s.t - from; cur = s.new; from = s.t }
                line.append((from, duration, cur)); values[cur, default: 0] += duration - from
                timelines[tilePath] = line
            }
            if values.count > 6 {
                highCardinality.append((key, values.count, instances.values.reduce(0) { $0 + $1.count }))
                continue
            }
            guard values.count >= 2 else { continue }
            let active = values.min { $0.value < $1.value }!.key
            var perName: [String: (changes: Int, spans: [(Double, Double)])] = [:]
            for (tilePath, steps) in instances {
                let name = steps[0].name
                var entry = perName[name] ?? (0, [])
                entry.changes += steps.count
                entry.spans += timelines[tilePath]!.filter { $0.2 == active }.map { ($0.0, $0.1) }.filter { $0.1 > $0.0 }
                perName[name] = entry
            }
            // how much of the "active" time has two names active at once
            var marks: [(Double, Int)] = []
            for (_, v) in perName { for sp in v.spans { marks.append((sp.0, 1)); marks.append((sp.1, -1)) } }
            marks.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            var level = 0, last = 0.0, any = 0.0, many = 0.0
            for (t, d) in marks {
                if level >= 1 { any += t - last }
                if level >= 2 { many += t - last }
                level += d; last = t
            }
            let first = instances.values.first!.first!
            candidates.append(Candidate(key: key, values: values, active: active, perName: perName,
                                        overlap: any > 0 ? many / any : 0, example: first, instances: instances.count))
        }
        func risesCount(_ c: Candidate) -> Int { c.perName.values.filter { $0.spans.count >= 1 && $0.changes >= 1 }.count }
        func totalChanges(_ c: Candidate) -> Int { c.perName.values.reduce(0) { $0 + $1.changes } }
        candidates.sort {
            let a = risesCount($0), b = risesCount($1)
            if a != b { return a > b }
            if abs($0.overlap - $1.overlap) > 0.05 { return $0.overlap < $1.overlap }
            return totalChanges($0) > totalChanges($1)
        }

        say()
        say("== attributes that toggled inside a participant's tile (a speaking indicator is one of these)")
        say("   likely indicator: toggles for 2+ names, small share of time active per name, rarely two names active together.")
        if candidates.isEmpty { say("  none. nothing inside any tile changed between two values. the indicator may be drawn without an accessibility node: see the README.") }
        for (rank, c) in candidates.prefix(8).enumerated() {
            let vals = c.values.sorted { $0.value > $1.value }.map { "\"\(AX.clip($0.key, 40))\" \(String(format: "%.0f", $0.value)) s" }.joined(separator: " | ")
            let verdict = risesCount(c) >= 2 && c.overlap < 0.25 ? "LIKELY" : (risesCount(c) >= 2 ? "possible" : "weak")
            say()
            say("  #\(rank + 1) [\(verdict)] \(c.key.attr) on \(c.key.role)\(c.key.extra.isEmpty ? "" : " (\(c.key.extra))")   at tile\(c.key.rel)")
            say("      values (time spent): \(vals)")
            say("      active value taken as: \"\(AX.clip(c.active, 40))\"   names that toggled: \(risesCount(c))   two names active together: \(String(format: "%.0f", c.overlap * 100))% of active time")
            for (name, v) in c.perName.sorted(by: { $0.value.changes > $1.value.changes }) {
                let secs = v.spans.reduce(0) { $0 + $1.1 - $1.0 }
                let spans = v.spans.sorted { $0.0 < $1.0 }.prefix(spanLimit).map { "\(String(format: "%.1f-%.1fs", $0.0, $0.1)) (\(clockOnly($0.0)))" }.joined(separator: ", ")
                say("      \(name.isEmpty ? "(no name)" : name): \(v.changes) changes, active \(String(format: "%.1f", secs)) s in \(v.spans.count) span(s): \(spans)\(v.spans.count > spanLimit ? ", …" : "")")
            }
        }
        if !highCardinality.isEmpty {
            say()
            say("  changed but too many values to be a toggle (text, counters):")
            for (k, n, c) in highCardinality.sorted(by: { $0.2 > $1.2 }).prefix(5) {
                say("      \(k.attr) on \(k.role) at tile\(k.rel): \(n) values, \(c) changes")
            }
        }

        say()
        say("== toggles outside any tile (a speaker-view border, a status line, a live region)")
        let outsideRanked = outside.filter { $0.value.count >= 2 && Set($0.value.flatMap { [$0.old, $0.new] }).count <= 4 }
            .sorted { $0.value.count > $1.value.count }
        if outsideRanked.isEmpty { say("  none") }
        for (k, steps) in outsideRanked.prefix(6) {
            let vals = Set(steps.flatMap { [$0.old, $0.new] }).sorted().map { "\"\(AX.clip($0, 30))\"" }.joined(separator: ", ")
            say("  \(k.attr) on \(k.role) \(steps[0].classes.isEmpty ? "" : "[\(steps[0].classes)] ")\(steps.count) changes between \(vals)")
            say("      \(shortPath(k.rel))")
        }

        // MARK: stable targets
        say()
        say("== stable things to target")
        let patterns = Dictionary(grouping: sightings, by: { "\($0.role).\($0.attr) at tile\($0.rel.isEmpty ? "." : $0.rel)" })
            .map { (pattern: $0.key, names: Set($0.value.map { $0.name }).count, classes: Set($0.value.map { $0.classes }.filter { !$0.isEmpty }), ids: Set($0.value.map { $0.domId }.filter { !$0.isEmpty }).count) }
            .sorted { $0.names > $1.names }
        if patterns.isEmpty { say("  no name nodes") }
        for p in patterns.prefix(5) {
            say("  name node: \(p.pattern)  carries \(p.names) different name(s); DOM classes: \(p.classes.isEmpty ? "none" : p.classes.sorted().prefix(3).joined(separator: " | ")); distinct DOM ids: \(p.ids)")
        }
        if let best = candidates.first, risesCount(best) >= 2 {
            let ex = best.example
            say("  best indicator candidate: \(best.key.attr) on \(best.key.role) at tile\(best.key.rel)")
            say("      example node: \(shortPath(ex.path))")
            say("      classes: \(ex.classes.isEmpty ? "none" : ex.classes)   AXDOMIdentifier: \(ex.domId.isEmpty ? "none" : ex.domId)   AXIdentifier: \(ex.ident.isEmpty ? "none" : ex.ident)")
        }

        if let out = args.string("out") {
            try report.joined(separator: "\n").appending("\n").write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
            print("\nwrote \(out)")
        }
    }

    static func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// the total length covered by a set of intervals.
    static func union(_ spans: [(Double, Double)]) -> Double {
        var total = 0.0, end = -Double.infinity, begin = 0.0
        for s in spans.sorted(by: { $0.0 < $1.0 }) {
            if s.0 > end { if end > begin { total += end - begin }; begin = s.0; end = s.1 }
            else { end = max(end, s.1) }
        }
        if end > begin { total += end - begin }
        return total
    }

    /// the last few steps of a path; the front of it is the same everywhere.
    static func shortPath(_ p: String) -> String {
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count <= 5 ? p : ".../" + parts.suffix(5).joined(separator: "/")
    }
}
