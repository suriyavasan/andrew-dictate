import Foundation

/// naming a speaker by hand: the file is rewritten, and the book is taught
/// the voice that was named, if the meeting kept it. one place, so the
/// window, a test and anything later (the live panel) do it the same way.
struct SpeakerNaming: Sendable {
    let voiceBook: VoiceBook
    let voicePrints: MeetingVoicePrints
    /// "remember voices", read when a name is given: with it off, a name
    /// goes into the file and nowhere else.
    let remembering: @Sendable () -> Bool

    /// the app's own: the support folder's book and prints, and the setting
    /// as it stands in the preferences.
    static let live = SpeakerNaming(
        voiceBook: VoiceBook(),
        voicePrints: MeetingVoicePrints(),
        remembering: {
            UserDefaults.standard.object(forKey: AppSettings.rememberVoicesKey) as? Bool ?? true
        })

    /// the names the book knows, for the field's suggestions.
    func knownNames() -> [String] {
        voiceBook.people().map(\.name)
    }

    /// `shown` is the speaker as the file shows it (`them 2`, or the name it
    /// was given); `name` is the new one, blank to put the label back. throws
    /// when the file could not be rewritten, and then nothing was taught.
    func rename(_ shown: String, to name: String?, at url: URL) throws {
        let voices = try MeetingTranscriptFile.header(of: url).voices
        let origins = MeetingTranscriptFile.origins(of: shown, in: voices)
        try MeetingTranscriptFile.renameSpeaker(shown, to: name, at: url)
        guard remembering() else { return }

        // the file is what it was told; the book follows it. a voice that was
        // taught under another name is taken out of that person first, so a
        // wrong name that is put right does not go on lending its voice.
        let now = try? MeetingTranscriptFile.header(of: url).voices
        let prints = voicePrints.prints(for: url)
        for label in origins {
            guard let print = prints[label] else { continue }
            let new = now?.first { $0.label == label }?.name
            if let old = print.taught, old != new {
                voiceBook.unlearn(print.embedding, from: old)
            }
            if let new, new != print.taught {
                voiceBook.learn(print.embedding, as: new)
            }
            voicePrints.setTaught(new, label: label, for: url)
        }
    }
}
