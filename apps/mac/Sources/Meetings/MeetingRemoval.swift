import Foundation

/// throwing a meeting away, the one way it is done: the transcript goes to
/// the trash (recoverable, because the app is not entitled to shred an hour
/// of someone else's words on one click), and the audio kept for it goes for
/// good, since nothing is left to check it against and there is no reason to
/// keep someone's voice past the words they said. the history list and the
/// meetings window both end here.
enum MeetingRemoval {
    static func trashItem(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// the audio is let go of only once the transcript is: a trash that
    /// failed leaves both, so a delete that did not happen does not look
    /// like one that did (SPEC §4).
    static func remove(
        _ transcript: URL,
        keptAudio: KeptAudio?,
        trash: (URL) throws -> Void = MeetingRemoval.trashItem
    ) throws {
        try trash(transcript)
        keptAudio?.deleteAudio(of: transcript)
    }
}
