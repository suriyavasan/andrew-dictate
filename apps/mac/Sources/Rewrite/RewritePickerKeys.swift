import Carbon
import Foundation
import os

/// the picker's digit keys, registered with the system as hot keys for as
/// long as the picker is up and not a moment longer.
///
/// the panel is never key — it must not take the keyboard from the field
/// the words are going to — so it hears no key of its own. the dictation
/// key's monitor hears every key but cannot take one, and a 2 it saw would
/// still be typed into your field. a registered hot key is taken: the
/// system hands it here and the field never sees it. it needs no
/// permission, which is why the meeting shortcut is one too.
@MainActor
final class RewritePickerKeys {
    /// a digit was pressed: 0 to 9.
    var onDigit: ((Int) -> Void)?

    private var registered: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    private static let logger = Logger(
        subsystem: AppIdentity.loggingSubsystem,
        category: "rewrite"
    )
    /// 'ADRW': ours among the hot keys of this process. the meeting
    /// shortcut has its own, and each handler passes on the other's.
    private static let signature: OSType = 0x41_44_52_57

    /// the top row, by key code, digit order: 0 to 9.
    private static let rowKeys: [UInt32] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
    /// the keypad, the same order.
    private static let padKeys: [UInt32] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// takes `digits` (and only those: a picker with three styles leaves
    /// 4 to 9 for your typing) until `release()`.
    func take(_ digits: [Int]) {
        release()
        installHandlerOnce()
        for digit in digits where (0...9).contains(digit) {
            for code in [Self.rowKeys[digit], Self.padKeys[digit]] {
                var hotKey: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    code,
                    0,
                    EventHotKeyID(signature: Self.signature, id: UInt32(digit)),
                    GetApplicationEventTarget(),
                    0,
                    &hotKey
                )
                if status == noErr, let hotKey {
                    registered.append(hotKey)
                } else {
                    Self.logger.error("the picker could not take the \(digit) key: \(status)")
                }
            }
        }
    }

    func release() {
        for hotKey in registered {
            UnregisterEventHotKey(hotKey)
        }
        registered.removeAll()
    }

    private func installHandlerOnce() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else {
                    return OSStatus(eventNotHandledErr)
                }
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard read == noErr,
                      id.signature == RewritePickerKeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let keys = Unmanaged<RewritePickerKeys>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                let digit = Int(id.id)
                Task { @MainActor in keys.onDigit?(digit) }
                return noErr
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        if status != noErr {
            Self.logger.error("the picker's key handler could not be installed: \(status)")
        }
    }
}
