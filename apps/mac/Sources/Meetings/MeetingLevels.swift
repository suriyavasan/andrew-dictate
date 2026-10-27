import Foundation

/// How loud each side of the meeting is right now, for a meter: 0…1 on a
/// perceptual scale, not the raw rms, which would sit in the bottom tenth of
/// the bar for ordinary speech. Numbers only — no audio and no words leave
/// the chunk they were measured from.
struct MeetingLevels: Equatable, Sendable {
    var you: Float
    var them: Float

    static let zero = MeetingLevels(you: 0, them: 0)

    /// the quietest sound the bar shows and the loudest, in dBFS: below the
    /// floor is a room's hiss, and a full-scale signal is the top.
    static let floorDB: Float = -60
    static let ceilingDB: Float = 0

    /// a chunk's rms on the perceptual scale: -60 dB is 0, 0 dB is 1, and
    /// the decibels between are spread evenly, because loudness is heard in
    /// them. silence and anything unmeasurable is 0.
    static func level(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let level = (decibels - floorDB) / (ceilingDB - floorDB)
        return min(1, max(0, level))
    }

    /// how far a bar moves toward a louder chunk, and toward a quieter one,
    /// in one step: it jumps up so a word is seen when it is said, and falls
    /// back slowly so the bar does not flicker between syllables.
    static let attack: Float = 0.8
    static let release: Float = 0.25

    /// one step of a bar from where it is toward what the chunk measured.
    static func smoothed(_ current: Float, toward target: Float) -> Float {
        let rate = target > current ? attack : release
        return current + (target - current) * rate
    }
}

/// The meter behind `MeetingLevels`: smooths every chunk, and lets the
/// screen know no more than `rate` times a second. Chunks arrive about ten
/// times a second, so the throttle rarely bites; it is there so a source
/// that delivers smaller pieces cannot make the whole window redraw as often.
struct MeetingLevelMeter: Sendable {
    /// at most this many updates a second.
    static let rate = 15

    private var smoothed = MeetingLevels.zero
    private var lastPublished: ContinuousClock.Instant?

    /// takes one chunk in. Returns the levels to show when they are due and
    /// have moved, nil when they are not — the smoothing still counts the
    /// chunk either way, so a skipped one is not lost.
    mutating func hear(
        youRMS: Float, themRMS: Float, at now: ContinuousClock.Instant
    ) -> MeetingLevels? {
        smoothed.you = MeetingLevels.smoothed(smoothed.you, toward: MeetingLevels.level(rms: youRMS))
        smoothed.them = MeetingLevels.smoothed(smoothed.them, toward: MeetingLevels.level(rms: themRMS))
        let every = Duration.seconds(1) / Self.rate
        if let lastPublished, now - lastPublished < every {
            return nil
        }
        lastPublished = now
        return smoothed
    }

    /// back to silence, for a meeting that has stopped: the next one starts
    /// from nothing, and its first chunk is published.
    mutating func reset() {
        self = MeetingLevelMeter()
    }
}
