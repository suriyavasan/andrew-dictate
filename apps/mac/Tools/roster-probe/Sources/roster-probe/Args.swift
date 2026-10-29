import Foundation

struct ProbeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// `--flag value` pairs, bare `--switch`es, and positional words.
struct Args {
    var options: [String: String] = [:]
    var switches: Set<String> = []
    var positional: [String] = []

    static let switchNames: Set<String> = ["no-enable", "all", "fixed-attrs", "tiles-only", "help"]

    init(_ raw: [String]) throws {
        var i = 0
        while i < raw.count {
            let word = raw[i]
            if word.hasPrefix("--") {
                let key = String(word.dropFirst(2))
                if Args.switchNames.contains(key) {
                    switches.insert(key)
                } else {
                    guard i + 1 < raw.count else { throw ProbeError("--\(key) needs a value") }
                    options[key] = raw[i + 1]
                    i += 1
                }
            } else {
                positional.append(word)
            }
            i += 1
        }
    }

    func string(_ key: String) -> String? { options[key] }

    func int(_ key: String, default value: Int) throws -> Int {
        guard let text = options[key] else { return value }
        guard let n = Int(text), n > 0 else { throw ProbeError("--\(key) must be a positive whole number, not '\(text)'") }
        return n
    }

    func double(_ key: String, default value: Double) throws -> Double {
        guard let text = options[key] else { return value }
        guard let n = Double(text), n > 0 else { throw ProbeError("--\(key) must be a positive number, not '\(text)'") }
        return n
    }
}

enum Files {
    static let defaultDirectory = "/tmp/roster-probe"

    /// the output path: the one given, or a stamped file under /tmp/roster-probe.
    /// parents are created; the file itself is created private (0600), since it
    /// holds names and on-screen text.
    static func outputPath(_ given: String?, stem: String, ext: String) throws -> String {
        let path: String
        if let given {
            path = (given as NSString).expandingTildeInPath
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            path = "\(defaultDirectory)/\(stem)-\(f.string(from: Date())).\(ext)"
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir.isEmpty ? "." : dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return path
    }

    static func createPrivate(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
}
