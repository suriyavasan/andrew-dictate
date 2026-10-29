import Foundation

/// whether a voice heard in a meeting is one this mac was taught: pure, so
/// the policy that decides when a name may be written over somebody's words
/// can be argued with in a test.
///
/// a wrong name is worse than none. a `them 2` is honest; a `Priya` that is
/// not Priya is a lie that an agent will quote, and the person who reads it
/// will not know to doubt it. so every rule here leans toward leaving a
/// cluster unnamed.
enum VoiceMatching {
    /// the least cosine similarity between a meeting's cluster and a
    /// remembered voice for the name to be given. 0.65, which is a cosine
    /// distance of 0.35.
    ///
    /// the diarizer itself calls two stretches one speaker at a distance
    /// under 0.55 (`FluidDiarizer`: 0.7 folded two different voices into one
    /// on the spike, 0.5 split them cleanly). that decision is made inside
    /// one call, on one microphone, a minute apart; recognising a voice weeks
    /// later, through another room and another codec, is harder, so it asks
    /// for much more than the diarizer does to merge. and it compares a
    /// cluster's centroid with a person's centroid, each an average over
    /// many stretches, which are far steadier than any one embedding, so the
    /// same person lands well above this. provisional: a sound threshold
    /// needs real recordings of the same people on different days, which
    /// this track did not have; if it errs, it errs by leaving `them 2`.
    static let threshold: Float = 0.65

    /// how far the best match must be above the next best, among the
    /// remembered voices, for it to count, and how far a cluster must beat
    /// another cluster that wants the same name. two people who sound alike
    /// score alike, and a tie is a coin flip nobody should write down.
    static let margin: Float = 0.05

    /// cosine similarity, -1...1. 0 for vectors that cannot be compared:
    /// different lengths (the embedder was changed), empty, or silent.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let norm = (normA * normB).squareRoot()
        return norm > 0 ? dot / norm : 0
    }

    /// the names for a meeting's clusters, by the label each has in the file
    /// (`them 2`). a cluster gets the remembered voice it is most like when
    /// that is above `threshold` and clear of the runner-up by `margin`; a
    /// name goes to one cluster at most, the one that is clearly closest to
    /// it (two that are not clearly apart get nothing); a name in `reserved`
    /// is never given (yours).
    static func names(
        for clusters: [String: [Float]],
        among people: [VoicePerson],
        reserved: Set<String> = []
    ) -> [String: String] {
        let barred = Set(reserved.map { $0.lowercased() })
        let candidates = people.filter { !barred.contains($0.name.lowercased()) }

        // each cluster's pick, if it has one that is clear.
        var picks: [(label: String, name: String, score: Float)] = []
        for (label, embedding) in clusters {
            let scored = candidates
                .map { (name: $0.name, score: cosine(embedding, $0.centroid)) }
                .sorted { $0.score > $1.score }
            guard let best = scored.first, best.score >= threshold else { continue }
            if scored.count > 1, best.score - scored[1].score < margin { continue }
            picks.append((label, best.name, best.score))
        }

        // one name, one cluster: the closer one, if clearly closer.
        var named: [String: String] = [:]
        for (name, wanting) in Dictionary(grouping: picks, by: \.name) {
            let ranked = wanting.sorted { $0.score > $1.score }
            if ranked.count > 1, ranked[0].score - ranked[1].score < margin { continue }
            named[ranked[0].label] = name
        }
        return named
    }
}
