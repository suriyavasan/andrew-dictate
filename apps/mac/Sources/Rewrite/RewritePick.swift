import Foundation

/// one answer to the picker.
enum RewriteChoice: Equatable, Sendable {
    case style(RewriteStyle)
    /// the words as the cleaner left them, no model at all: the way out
    /// for a ⌃ held by accident that keeps what you said. esc throws the
    /// take away, as it always has.
    case asSaid
}

/// the picker while it is up: the styles in key order, and the one it
/// starts on, which is also the one it takes when the time runs out. pure,
/// so the keys and the clicks are argued with in tests.
struct RewritePick: Equatable, Sendable {
    /// how long the picker waits before it takes the style it started on.
    /// a hand on the pill holds it (`PillCountdown`).
    static let lasts: Duration = .seconds(5)
    /// `as said` is on the 0 key, after the styles on 1 to 9.
    static let asSaidKey = 0

    let styles: [RewriteStyle]
    let startsOn: Int

    init(styles: [RewriteStyle], defaultStyleID: String) {
        let styles = Array(styles.prefix(9))
        self.styles = styles.isEmpty ? [.auto] : styles
        startsOn = self.styles.firstIndex { $0.id == defaultStyleID } ?? 0
    }

    var startingStyle: RewriteStyle {
        styles[startsOn]
    }

    /// the digit on the key: 1 to 9 for the styles, 0 for `as said`.
    func choice(forDigit digit: Int) -> RewriteChoice? {
        if digit == Self.asSaidKey {
            return .asSaid
        }
        let index = digit - 1
        guard styles.indices.contains(index) else {
            return nil
        }
        return .style(styles[index])
    }

    /// the buttons on the pill, left to right: what the HUD draws.
    var buttons: [HUDChoiceButton] {
        styles.enumerated().map { index, style in
            HUDChoiceButton(
                key: "\(index + 1)",
                title: style.name,
                isDefault: index == startsOn
            )
        } + [
            HUDChoiceButton(
                key: "\(Self.asSaidKey)",
                title: "as said",
                isDefault: false
            ),
        ]
    }

    /// the button at a place on the pill, as the HUD numbers them.
    func choice(forButton index: Int) -> RewriteChoice? {
        if index == styles.count {
            return .asSaid
        }
        guard styles.indices.contains(index) else {
            return nil
        }
        return .style(styles[index])
    }

    /// the press record's name for a style: never the name of one of
    /// yours, which is your words.
    static func recordName(for style: RewriteStyle) -> String {
        style.isBuiltIn ? style.id : "custom"
    }
}
