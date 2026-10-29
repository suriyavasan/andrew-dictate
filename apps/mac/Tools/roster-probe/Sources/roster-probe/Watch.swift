import ApplicationServices
import AppKit

var stopRequested = false

enum WatchCommand {
    static let maxEventsPerSample = 400
    static let maxChangesPerAttribute = 400

    static func run(_ args: Args) throws {
        let (target, enabler, flags) = try Session.open(args)
        defer { enabler.restore() }

        let interval = try args.double("interval", default: 0.25)
        let seconds = try args.double("seconds", default: 120)
        let depth = try args.int("depth", default: 80)
        let maxNodes = try args.int("max-nodes", default: 40000)
        let tilesOnly = args.switches.contains("tiles-only")
        let out = try Files.outputPath(args.string("out"), stem: "watch-\(args.string("app") ?? "app")", ext: "jsonl")

        signal(SIGINT) { _ in
            if stopRequested { _exit(130) }
            stopRequested = true
        }
        signal(SIGTERM) { _ in stopRequested = true }

        func limits() -> AX.Limits {
            var l = AX.Limits(deadline: Date().addingTimeInterval(max(10, interval * 40)))
            l.maxDepth = depth
            l.maxNodes = maxNodes
            l.allAttributes = !args.switches.contains("fixed-attrs")
            return l
        }

        Files.createPrivate(out)
        guard let handle = FileHandle(forWritingAtPath: out) else { throw ProbeError("cannot write \(out)") }
        defer { try? handle.close() }
        func emit(_ object: [String: Any]) { handle.write(Json.line(object)) }

        if !flags.isEmpty { print("accessibility flags on \(target.name): \(flags.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }.joined(separator: "; "))") }
        print("reading \(target.name) every \(interval) s for up to \(Int(seconds)) s. Ctrl-C stops early and still writes the end of the log.")

        let clock = ContinuousClock()
        let started = clock.now
        let wall = Date()
        func elapsed() -> Double {
            let d = clock.now - started
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func stamp(_ t: Double) -> [String: Any] {
            ["t": NSDecimalNumber(string: String(format: "%.3f", t)), "iso": iso.string(from: wall.addingTimeInterval(t))]
        }

        let registry = Capture.Registry()
        var previous: [String: Snap] = [:]
        var previousNames: [String: String] = [:]
        var orderPrev: [String] = []
        var changeCounts: [String: Int] = [:]
        var muted: Set<String> = []
        var sample = 0
        var totalEvents = 0
        var lastTick = 0.0
        var walkMillis: [Int] = []
        var lastNodes = 0

        emit(stamp(0).merging([
            "kind": "start", "app": target.name, "bundleId": target.bundleId, "pid": Int(target.pid),
            "interval": interval, "seconds": seconds, "window": args.string("window") ?? "",
            "tilesOnly": tilesOnly, "flags": flags,
        ]) { a, _ in a })

        while !stopRequested {
            let t = elapsed()
            if t >= seconds { break }
            let cap: Capture
            if sample == 0 {
                cap = Capture.takeWaitingForWeb(target, windowFilter: args.string("window"), limits: limits(), wait: true, registry: registry)
                if cap.items.isEmpty {
                    let titles = cap.allWindows.map { "\"\($0.title)\"" }.joined(separator: ", ")
                    throw ProbeError("no window selected. \(target.name) windows: \(titles.isEmpty ? "none visible to accessibility" : titles). use --window <part of a title>.")
                }
                let baseline = out.replacingOccurrences(of: ".jsonl", with: "") + ".baseline.json"
                Files.createPrivate(baseline)
                let doc: [String: Any] = [
                    "tool": "roster-probe", "kind": "baseline", "app": target.name,
                    "windows": cap.items.map { ["title": $0.window.title, "tree": DumpCommand.node($0.root)] as [String: Any] },
                ]
                try? Json.data(doc, pretty: true).write(to: URL(fileURLWithPath: baseline))
                DumpCommand.report(cap, target: target, out: baseline)
            } else {
                cap = Capture.take(target, windowFilter: args.string("window"), limits: limits(), registry: registry)
            }
            let now = elapsed()
            walkMillis.append(cap.millis)

            // flatten
            var current: [String: Snap] = [:]
            var order: [String] = []
            for item in cap.items {
                for n in AX.flatten(item.root) where current[n.path] == nil {
                    current[n.path] = n
                    order.append(n.path)
                }
            }
            lastNodes = current.count

            // names: who is on screen, and where
            var names: [String: String] = [:]
            for p in order { if let g = current[p]!.name { names[p] = g.name } }
            var events = 0
            for p in order {
                guard let node = current[p], let g = node.name, previousNames[p] != g.name else { continue }
                emit(merge(stamp(now), ["kind": "name", "present": true], describe(node)))
                events += 1
            }
            for (p, oldName) in previousNames.sorted(by: { $0.key < $1.key }) where names[p] != oldName {
                if let old = previous[p] {
                    emit(merge(stamp(now), ["kind": "name", "present": false], describe(old)))
                    events += 1
                }
            }

            if sample > 0 {
                var dropped = 0
                func note(_ e: [String: Any], _ node: Snap) {
                    if tilesOnly && node.tileName == nil { return }
                    if events >= maxEventsPerSample { dropped += 1; return }
                    emit(e)
                    events += 1
                }
                for p in order {
                    guard let node = current[p] else { continue }
                    guard let old = previous[p] else {
                        note(merge(stamp(now), ["kind": "appeared"], describe(node)), node)
                        continue
                    }
                    for (attr, a, b) in diff(old, node) {
                        let key = p + "|" + attr
                        changeCounts[key, default: 0] += 1
                        if changeCounts[key]! > maxChangesPerAttribute {
                            if muted.insert(key).inserted {
                                emit(merge(stamp(now), ["kind": "muted", "attr": attr], describe(node)))
                            }
                            continue
                        }
                        note(merge(stamp(now), ["kind": "changed", "attr": attr, "old": a as Any, "new": b as Any], describe(node)), node)
                    }
                }
                for p in orderPrev where current[p] == nil {
                    if let old = previous[p] { note(merge(stamp(now), ["kind": "disappeared"], describe(old)), old) }
                }
                if dropped > 0 { emit(merge(stamp(now), ["kind": "bulk", "dropped": dropped])) }
            }
            totalEvents += events

            if now - lastTick >= 5 {
                lastTick = now
                emit(merge(stamp(now), [
                    "kind": "tick", "samples": sample + 1, "nodes": current.count, "walkMs": cap.millis,
                    "names": Set(names.values).count, "events": totalEvents,
                    "cut": cap.stats.truncatedNodes || cap.stats.timedOut,
                ]))
                print(String(format: "%6.1fs  sample %d  %d nodes  %d ms/walk  %d names  %d events", now, sample + 1, current.count, cap.millis, Set(names.values).count, totalEvents))
            }

            previous = current
            previousNames = names
            orderPrev = order
            sample += 1

            // wait out the rest of the interval in small slices so Ctrl-C is quick
            let next = now + max(0, interval - (elapsed() - now))
            while !stopRequested, elapsed() < next, elapsed() < seconds { Thread.sleep(forTimeInterval: 0.02) }
        }

        let end = elapsed()
        let sorted = walkMillis.sorted()
        emit(merge(stamp(end), [
            "kind": "end", "samples": sample, "events": totalEvents, "nodes": lastNodes,
            "walkMsMedian": sorted.isEmpty ? 0 : sorted[sorted.count / 2], "walkMsMax": sorted.last ?? 0,
            "stoppedEarly": stopRequested,
        ]))
        print("done: \(sample) samples in \(String(format: "%.1f", end)) s, \(totalEvents) events -> \(out)")
        if let med = sorted.isEmpty ? nil : sorted[sorted.count / 2], Double(med) > interval * 1000 * 2 {
            print("note: one read of the tree takes about \(med) ms, slower than --interval; the real rate is one sample per \(med) ms. narrow it with --window or --depth for a faster rate.")
        }
        print("next: roster-probe analyze \(out)")
    }

    // MARK: pieces

    static func merge(_ parts: [String: Any]...) -> [String: Any] {
        var out: [String: Any] = [:]
        for p in parts { out.merge(p) { _, new in new } }
        return out
    }

    /// who a node is, in every event about it.
    static func describe(_ n: Snap) -> [String: Any] {
        var d: [String: Any] = ["path": n.path, "role": n.role]
        if let v = n.attrs["AXSubrole"] { d["subrole"] = v }
        if let v = n.domId { d["domId"] = v }
        if let v = n.identifier { d["ident"] = v }
        if let v = n.classes { d["classes"] = v }
        for a in ["AXTitle", "AXDescription", "AXValue"] {
            if let v = n.attrs[a] { d["label"] = AX.clip(v, 80); break }
        }
        if let g = n.name { d["name"] = g.name; d["nameAttr"] = g.attr; d["nameHow"] = g.how; d["nameLikely"] = g.likely }
        if let t = n.tileName { d["tile"] = t; d["tilePath"] = n.tilePath ?? ""; d["rel"] = n.rel ?? "" }
        return d
    }

    static func frameText(_ n: Snap) -> String? {
        guard let f = n.frame else { return nil }
        return "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"
    }

    /// (attribute, old, new) for everything that differs. a position that only
    /// moved (same size) is reported as "position", a size change as "size".
    static func diff(_ a: Snap, _ b: Snap) -> [(String, String?, String?)] {
        var out: [(String, String?, String?)] = []
        for key in Set(a.attrs.keys).union(b.attrs.keys).sorted() where a.attrs[key] != b.attrs[key] {
            out.append((key, a.attrs[key], b.attrs[key]))
        }
        if let fa = a.frame, let fb = b.frame {
            if fa.size != fb.size { out.append(("size", "\(Int(fa.width))x\(Int(fa.height))", "\(Int(fb.width))x\(Int(fb.height))")) }
            if fa.origin != fb.origin { out.append(("position", "\(Int(fa.minX)),\(Int(fa.minY))", "\(Int(fb.minX)),\(Int(fb.minY))")) }
        } else if frameText(a) != frameText(b) {
            out.append(("frame", frameText(a), frameText(b)))
        }
        return out
    }
}
