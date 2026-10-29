import Foundation
import os
import Synchronization

/// one person this mac can recognise by voice: their name, and the average
/// of the voice embeddings that were taught under it. an embedding is 256
/// numbers; it cannot be played back, but it does identify a voice, so the
/// book is private (mode 0600), local, and can be emptied.
struct VoicePerson: Codable, Equatable, Sendable, Identifiable {
    var name: String
    /// the mean of the unit-length embeddings folded in, not scaled back to
    /// unit length: taking one out again is then exact.
    var centroid: [Float]
    /// how many embeddings are in the mean.
    var samples: Int
    var updated: Date

    var id: String { name.lowercased() }
}

/// the remembered voices: `voices.json` in the app's support folder. every
/// call reads the file and writes it back, because the book is a few
/// kilobytes and is touched twice a meeting, and because the settings pane,
/// the meetings window and the end of a meeting all reach it.
///
/// a file that is unreadable is an empty book, not an error: not recognising
/// anyone is the only safe thing to do with a book that cannot be read, and
/// the next thing learned replaces it.
final class VoiceBook: Sendable {
    static let fileName = "voices.json"

    private struct Stored: Codable {
        var version = 1
        var people: [VoicePerson]
    }

    private let url: URL
    private let now: @Sendable () -> Date
    private let lock = Mutex<Void>(())
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "voices")

    init(
        url: URL = AppIdentity.supportDirectory.appendingPathComponent(VoiceBook.fileName),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.now = now
    }

    /// everyone remembered, by name.
    func people() -> [VoicePerson] {
        lock.withLock { _ in read().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    }

    /// folds a voice into a person's, who is added if the book has not got
    /// them. `name` is as the file writes it; the person is found without
    /// regard to case, and keeps the spelling they were first given.
    func learn(_ embedding: [Float], as name: String) {
        guard let unit = Self.unit(embedding) else { return }
        lock.withLock { _ in
            var people = read()
            if let at = people.firstIndex(where: { $0.id == name.lowercased() }),
               people[at].centroid.count == unit.count {
                let n = Float(people[at].samples)
                people[at].centroid = zip(people[at].centroid, unit).map { ($0 * n + $1) / (n + 1) }
                people[at].samples += 1
                people[at].updated = now()
            } else {
                // a book written by another embedder cannot be averaged
                // with this one: the person starts again from this voice.
                people.removeAll { $0.id == name.lowercased() }
                people.append(VoicePerson(name: name, centroid: unit, samples: 1, updated: now()))
            }
            write(people)
        }
    }

    /// takes a voice back out of a person's: it was taught under the wrong
    /// name. a person left with nothing is forgotten.
    func unlearn(_ embedding: [Float], from name: String) {
        guard let unit = Self.unit(embedding) else { return }
        lock.withLock { _ in
            var people = read()
            guard let at = people.firstIndex(where: { $0.id == name.lowercased() }),
                  people[at].centroid.count == unit.count
            else { return }
            let n = Float(people[at].samples)
            if people[at].samples <= 1 {
                people.remove(at: at)
            } else {
                people[at].centroid = zip(people[at].centroid, unit).map { ($0 * n - $1) / (n - 1) }
                people[at].samples -= 1
                people[at].updated = now()
            }
            write(people)
        }
    }

    func forget(_ name: String) {
        lock.withLock { _ in
            var people = read()
            let before = people.count
            people.removeAll { $0.id == name.lowercased() }
            if people.count != before { write(people) }
        }
    }

    func forgetAll() {
        lock.withLock { _ in
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - the file

    private func read() -> [VoicePerson] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data) else {
            logger.error("the voice book could not be read, so it is empty")
            return []
        }
        return stored.people
    }

    private func write(_ people: [VoicePerson]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try encoder.encode(Stored(people: people)).write(to: url, options: .atomic)
            // `try?` for the reason the transcript's mode is: a volume
            // without modes must not lose a voice that is already saved.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.error("a voice could not be remembered: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// scaled to length 1, so every voice weighs the same in an average;
    /// nil for one that cannot be (empty, silent, not a number).
    static func unit(_ embedding: [Float]) -> [Float]? {
        let norm = embedding.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm.isFinite, norm > 0 else { return nil }
        return embedding.map { $0 / norm }
    }
}
