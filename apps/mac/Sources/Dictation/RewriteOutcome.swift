import Foundation

/// what a rewrite (fn+⌃) came to. the coordinator puts up the picker and
/// asks the model; the machine only pastes what comes back, and never
/// pastes nothing: every way this ends has words in it.
enum RewriteOutcome: Equatable, Sendable {
    /// the model's words, in the style you picked. `style` is the press
    /// record's name for it: a built-in's id, or `custom`.
    case rewritten(String, style: String)
    /// you picked `as said`: the words go as the cleaner left them.
    case asSaid
    /// the model failed or took too long. your words go as said, and the
    /// pill says why once they have landed: a rewrite that did not happen
    /// must not look like one that did.
    case failed(reason: String, style: String?)

    var resultName: String {
        switch self {
        case .rewritten: "rewritten"
        case .asSaid: "as-said"
        case .failed: "failed"
        }
    }
}
