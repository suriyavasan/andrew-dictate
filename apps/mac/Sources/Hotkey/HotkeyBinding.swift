import AppKit
import CoreGraphics
import Foundation

struct HotkeyBinding: Codable, Hashable, Identifiable, Sendable {
    let keyCode: CGKeyCode
    let displayName: String

    var id: CGKeyCode {
        keyCode
    }

    static let fn = HotkeyBinding(keyCode: 63, displayName: "fn")
    static let rightOption = HotkeyBinding(
        keyCode: 61,
        displayName: "right ⌥"
    )
    static let leftOption = HotkeyBinding(
        keyCode: 58,
        displayName: "left ⌥"
    )
    static let rightCommand = HotkeyBinding(
        keyCode: 54,
        displayName: "right ⌘"
    )
    static let leftCommand = HotkeyBinding(
        keyCode: 55,
        displayName: "left ⌘"
    )
    static let rightControl = HotkeyBinding(
        keyCode: 62,
        displayName: "right ⌃"
    )
    static let leftControl = HotkeyBinding(
        keyCode: 59,
        displayName: "left ⌃"
    )

    static let dictation = fn

    static let supported: [HotkeyBinding] = [
        .fn,
        .rightOption,
        .leftOption,
        .rightCommand,
        .leftCommand,
        .rightControl,
        .leftControl,
    ]

    /// the key held with this one to have the take rewritten (fn+⌃): the
    /// one you chose, unless it is the dictation key's own kind — ⌃ held
    /// with right ⌃ is no second key — and then the first that is free.
    func rewriteModifier(preferring preferred: RewriteModifier) -> RewriteModifier {
        if preferred.isFree(alongside: self) {
            return preferred
        }
        return RewriteModifier.allCases.first { $0.isFree(alongside: self) }
            ?? .shift
    }

    /// the whole gesture in one line, so the settings row and anything that
    /// adopts it later cannot say it two ways. the words are the hud's own
    /// — the pill says "locked — tap to end", so this says locks and end.
    static let gestureExplanation =
        "hold it and talk. double-tap locks it on hands-free, tap once to end. esc cancels."
}

extension UserDefaults {
    func hotkeyBinding() -> HotkeyBinding {
        guard let data = data(
            forKey: "AndrewDictate.hotkey.dictation"
        ),
              let binding = try? JSONDecoder().decode(
                  HotkeyBinding.self,
                  from: data
              ) else {
            return .dictation
        }

        return binding
    }

    func setHotkeyBinding(_ binding: HotkeyBinding) {
        guard let data = try? JSONEncoder().encode(binding) else {
            return
        }

        set(data, forKey: "AndrewDictate.hotkey.dictation")
    }
}

/// the second key, held with the dictation key, that turns a take into a
/// rewrite. the rawValue is what settings keep.
enum RewriteModifier: String, CaseIterable, Codable, Identifiable, Sendable {
    case control
    case option
    case shift
    case command

    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    /// "⌃ control": the chip in settings, symbol and word both, since not
    /// everyone reads the symbols.
    var displayName: String {
        "\(symbol) \(rawValue)"
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }

    /// the left and right keys that set this flag.
    private var keyCodes: Set<CGKeyCode> {
        switch self {
        case .control: [59, 62]
        case .option: [58, 61]
        case .shift: [56, 60]
        case .command: [54, 55]
        }
    }

    /// whether it can be told apart from the dictation key: a right ⌥
    /// dictation key sets the ⌥ flag itself, so every take would rewrite.
    func isFree(alongside binding: HotkeyBinding) -> Bool {
        !keyCodes.contains(binding.keyCode)
    }
}
