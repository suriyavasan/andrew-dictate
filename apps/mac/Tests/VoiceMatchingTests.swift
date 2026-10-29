import XCTest

/// the policy that decides when a remembered voice may name a speaker. every
/// rule leans toward leaving `them 2`.
final class VoiceMatchingTests: XCTestCase {
    /// a unit vector `angle` radians from the first axis, in the plane of the
    /// first two: two of them `a` apart have a cosine of cos(a).
    private func voice(_ angle: Float, spin: Float = 0) -> [Float] {
        [cos(angle), sin(angle) * cos(spin), sin(angle) * sin(spin)]
    }

    private func person(_ name: String, _ embedding: [Float]) -> VoicePerson {
        VoicePerson(name: name, centroid: embedding, samples: 3, updated: Date(timeIntervalSince1970: 0))
    }

    func testCosine() {
        XCTAssertEqual(VoiceMatching.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(VoiceMatching.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(VoiceMatching.cosine([1, 0], [-1, 0]), -1, accuracy: 1e-6)
        XCTAssertEqual(VoiceMatching.cosine([2, 0], [5, 0]), 1, accuracy: 1e-6)
    }

    func testVectorsThatCannotBeComparedAreNotAlike() {
        XCTAssertEqual(VoiceMatching.cosine([1, 0], [1, 0, 0]), 0)
        XCTAssertEqual(VoiceMatching.cosine([], []), 0)
        XCTAssertEqual(VoiceMatching.cosine([0, 0], [1, 0]), 0)
    }

    func testTheClosestVoiceAboveTheThresholdIsTheName() {
        let people = [person("Priya", voice(0)), person("Rahul", voice(1.5))]
        let named = VoiceMatching.names(for: ["them 1": voice(0.1)], among: people)
        XCTAssertEqual(named, ["them 1": "Priya"])
    }

    func testAVoiceBelowTheThresholdIsLeftAlone() {
        // a cosine just under the threshold.
        let angle = acos(VoiceMatching.threshold - 0.01)
        XCTAssertTrue(VoiceMatching.names(for: ["them 1": voice(angle)], among: [person("Priya", voice(0))]).isEmpty)
        // and just over it is named.
        let near = acos(VoiceMatching.threshold + 0.01)
        XCTAssertEqual(VoiceMatching.names(for: ["them 1": voice(near)], among: [person("Priya", voice(0))]),
                       ["them 1": "Priya"])
    }

    func testTwoPeopleWhoSoundAlikeAreATieAndNeitherNames() {
        // both well above the threshold, a hair apart.
        let people = [person("Priya", voice(0.30)), person("Pooja", voice(0.32))]
        XCTAssertTrue(VoiceMatching.names(for: ["them 1": voice(0.31)], among: people).isEmpty)
    }

    func testTheRunnerUpOnlyHasToBeClearlyBehind() {
        let ahead = acos(VoiceMatching.threshold + VoiceMatching.margin + 0.1)
        let people = [person("Priya", voice(0)), person("Pooja", voice(ahead))]
        // the voice sits on Priya; Pooja is far enough away to leave no doubt.
        XCTAssertEqual(VoiceMatching.names(for: ["them 1": voice(0)], among: people), ["them 1": "Priya"])
    }

    func testANameGoesToOneClusterAtMostAndTheCloserOneGetsIt() {
        let people = [person("Priya", voice(0))]
        let named = VoiceMatching.names(
            for: ["them 1": voice(0.05), "them 2": voice(0.4)], among: people)
        XCTAssertEqual(named, ["them 1": "Priya"])
    }

    func testTwoClustersEquallyLikeOnePersonNeitherIsNamed() {
        let people = [person("Priya", voice(0))]
        let named = VoiceMatching.names(
            for: ["them 1": voice(0.2, spin: 0), "them 2": voice(0.2, spin: 3)], among: people)
        XCTAssertTrue(named.isEmpty)
    }

    func testEachClusterCanHaveItsOwnPerson() {
        let people = [person("Priya", voice(0)), person("Rahul", voice(2))]
        let named = VoiceMatching.names(
            for: ["them 1": voice(2.05), "them 2": voice(0.05)], among: people)
        XCTAssertEqual(named, ["them 1": "Rahul", "them 2": "Priya"])
    }

    func testYourOwnNameIsNeverGivenToSomeoneElse() {
        let people = [person("Suriya", voice(0))]
        let named = VoiceMatching.names(
            for: ["them 1": voice(0)], among: people, reserved: ["suriya"])
        XCTAssertTrue(named.isEmpty)
    }

    func testNoBookNoNamesAndNoVoicesNoNames() {
        XCTAssertTrue(VoiceMatching.names(for: ["them 1": voice(0)], among: []).isEmpty)
        XCTAssertTrue(VoiceMatching.names(for: [:], among: [person("Priya", voice(0))]).isEmpty)
    }

    func testABookFromAnotherEmbedderNamesNobody() {
        let people = [person("Priya", [1, 0])]
        XCTAssertTrue(VoiceMatching.names(for: ["them 1": [1, 0, 0]], among: people).isEmpty)
    }
}
