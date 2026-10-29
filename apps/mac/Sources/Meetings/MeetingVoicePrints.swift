import Foundation
import os
import Synchronization

/// the voices of one meeting, kept after it so a speaker can be named later,
/// by hand, and the book taught who they were: each far-side label's
/// embedding, and the name it has been taught under, if any (so a rename can
/// take the voice back out of the person it was wrongly put into).
///
/// kept apart from the transcript, which says nothing a reader could not
/// already read, in a folder of the app's own and one small file per meeting,
/// named for the transcript. only written when "remember voices" is on, and
/// let go of with the meeting.
final class MeetingVoicePrints: Sendable {
    static let folderName = "meeting-voices"

    struct Print: Codable, Equatable, Sendable {
        var embedding: [Float]
        /// the person this voice was folded into the book as.
        var taught: String?
    }

    /// how long a print outlives its meeting's last change before the next
    /// meeting sweeps it away: a file nobody has named in a quarter of a
    /// year is not going to be, and the folder should not grow for ever.
    static let keptFor: TimeInterval = 90 * 24 * 3_600

    private let folder: URL
    private let lock = Mutex<Void>(())
    private let logger = Logger(subsystem: AppIdentity.loggingSubsystem, category: "voices")

    init(folder: URL = AppIdentity.supportDirectory
        .appendingPathComponent(MeetingVoicePrints.folderName, isDirectory: true)) {
        self.folder = folder
    }

    func prints(for transcript: URL) -> [String: Print] {
        lock.withLock { _ in read(transcript) }
    }

    /// a meeting's voices. a session recorded into a file that has prints
    /// already adds the labels the file has not got (`replacing` false): one
    /// label is one person to the file, and the first embedding stands. a
    /// transcript made again replaces them, as its labels are new.
    /// Returns the labels it took.
    @discardableResult
    func keep(
        _ voices: [String: [Float]], taught: [String: String],
        for transcript: URL, replacing: Bool
    ) -> Set<String> {
        guard !voices.isEmpty else { return [] }
        return lock.withLock { _ in
            var found = replacing ? [:] : read(transcript)
            var took: Set<String> = []
            for (label, embedding) in voices where found[label] == nil {
                found[label] = Print(embedding: embedding, taught: taught[label])
                took.insert(label)
            }
            write(found, for: transcript)
            sweep(keeping: transcript)
            return took
        }
    }

    /// what the book was told this label was, or nothing: set after the
    /// book has been taught, or after it has been told to let it go.
    func setTaught(_ name: String?, label: String, for transcript: URL) {
        lock.withLock { _ in
            var found = read(transcript)
            guard found[label] != nil else { return }
            found[label]?.taught = name
            write(found, for: transcript)
        }
    }

    /// with the meeting.
    func discard(for transcript: URL) {
        lock.withLock { _ in
            try? FileManager.default.removeItem(at: file(for: transcript))
        }
    }

    /// every print, for "forget all".
    func discardAll() {
        lock.withLock { _ in
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - the files

    private func file(for transcript: URL) -> URL {
        folder.appendingPathComponent(transcript.lastPathComponent + ".json", isDirectory: false)
    }

    private func read(_ transcript: URL) -> [String: Print] {
        guard let data = try? Data(contentsOf: file(for: transcript)),
              let found = try? JSONDecoder().decode([String: Print].self, from: data)
        else { return [:] }
        return found
    }

    private func write(_ found: [String: Print], for transcript: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let target = file(for: transcript)
            try JSONEncoder().encode(found).write(to: target, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            logger.error("a meeting's voices could not be kept: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sweep(keeping transcript: URL) {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.keptFor)
        let kept = file(for: transcript).lastPathComponent
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        where name != kept && name.hasSuffix(".json") {
            let path = folder.appendingPathComponent(name).path
            if let changed = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               changed < cutoff {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }
}
