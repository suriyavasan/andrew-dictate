import Foundation

struct NameGuess: Equatable {
    var name: String
    /// "exact": the whole text is the name. "prefix": the name leads a longer label
    /// ("Priya Sharma, audio muted"). "self": the label for the local user.
    var how: String
    var attr: String
    /// 2+ words is likely; one word is possible (a first name or a UI label).
    var likely: Bool
}

enum Names {
    static let badges: Set<String> = [
        "me", "you", "host", "co-host", "cohost", "guest", "presenter", "organizer", "organiser",
        "external", "unverified", "she/her", "he/him", "they/them", "pronouns", "pinned", "spotlight",
    ]

    /// words a button, tab or heading is made of. a label with one of these is not a name.
    static let uiWords: Set<String> = [
        "mute", "unmute", "muted", "unmuted", "chat", "participants", "participant", "share", "sharing", "screen",
        "leave", "end", "meeting", "settings", "more", "record", "recording", "reactions", "reaction", "raise",
        "lower", "hand", "apps", "app", "whiteboard", "whiteboards", "security", "invite", "manage", "start",
        "stop", "video", "audio", "join", "captions", "caption", "closed", "view", "gallery", "speaker",
        "full", "minimize", "maximize", "close", "zoom", "google", "meet", "microsoft", "teams", "people",
        "activities", "present", "now", "turn", "on", "off", "send", "copy", "search", "rename", "new", "ok",
        "cancel", "done", "button", "tab", "menu", "window", "toolbar", "back", "forward", "reload", "address",
        "bookmark", "bookmarks", "history", "downloads", "extensions", "profile", "help", "details", "info",
        "backgrounds", "effects", "filters", "notes", "polls", "q&a", "breakout", "rooms", "mic", "microphone",
        "camera", "speakers", "host", "co-host", "everyone", "all", "options", "show", "hide", "open", "save",
        "learn", "get", "add", "remove", "delete", "edit", "pin", "unpin", "spotlight", "tools", "apps", "call",
        "home", "chats", "calendar", "files", "contacts", "phone", "mail", "inbox", "sidebar", "tile", "tiles",
        "panel", "bar", "list", "name", "title", "untitled", "loading", "connecting", "waiting", "room",
        "unknown", "participant's", "sign", "up", "login", "log", "forgot", "password", "email", "next", "continue", "accept", "agree", "terms", "privacy", "policy", "version", "update", "check", "download", "install", "upgrade", "account", "sso", "free", "with", "apple", "facebook", "enter", "code", "password", "a", "an", "the", "and", "or", "to", "of", "for", "in", "is", "are",
    ]

    static let particles: Set<String> = [
        "de", "da", "di", "del", "della", "van", "von", "der", "den", "bin", "binti", "al", "el", "la", "le",
        "ben", "bint", "dos", "das", "du", "st.", "mac", "mc", "ibn", "ap", "ter", "ten",
    ]

    static let statusWords: [String] = [
        "muted", "unmuted", "audio", "video", "camera", "microphone", "speaking", "host", "presenting",
        "sharing", "raised", "hand", "pinned", "connected", "joined", "waiting", "active", "talking",
    ]

    /// the names a piece of text might carry. empty when it is not one.
    static func guess(_ raw: String, attr: String) -> NameGuess? {
        let text = raw.replacingOccurrences(of: "\n", with: " ").split(whereSeparator: { $0 == " " || $0 == "\u{00a0}" || $0 == "\t" }).joined(separator: " ")
        guard !text.isEmpty, text.count <= 90 else { return nil }

        if let n = plainName(text) {
            return NameGuess(name: n.name, how: n.isSelf ? "self" : "exact", attr: attr, likely: n.likely)
        }
        // "Priya Sharma, Computer audio muted"  /  "Priya Sharma - Host"  /  "Priya Sharma: speaking"
        for sep in [", ", " - ", " – ", ": ", " | ", " · "] {
            if let r = text.range(of: sep) {
                let head = String(text[..<r.lowerBound])
                let tail = String(text[r.upperBound...]).lowercased()
                guard statusWords.contains(where: { tail.contains($0) }) else { continue }
                if let n = plainName(head), !n.isSelf {
                    return NameGuess(name: n.name, how: "prefix", attr: attr, likely: n.likely)
                }
            }
        }
        return nil
    }

    private struct Plain { var name: String; var likely: Bool; var isSelf: Bool }

    private static func plainName(_ input: String) -> Plain? {
        var text = input
        // trailing "(Host)", "(Me)", "(she/her)" and a leading "Pinned "
        while text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let inside = text[text.index(after: open)..<text.index(before: text.endIndex)].lowercased()
            guard badges.contains(inside) || inside.count <= 12 else { break }
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower == "you" || lower == "me" { return Plain(name: text, likely: false, isSelf: true) }

        let tokens = text.split(separator: " ").map(String.init)
        guard (1...5).contains(tokens.count) else { return nil }
        var capitalised = 0
        for (i, t) in tokens.enumerated() {
            if uiWords.contains(t.lowercased()) && !(i > 0 && particles.contains(t.lowercased())) { return nil }
            guard let first = t.unicodeScalars.first, CharacterSet.letters.contains(first) else { return nil }
            for u in t.unicodeScalars {
                let ok = CharacterSet.letters.contains(u) || CharacterSet.nonBaseCharacters.contains(u)
                    || "'’-.".unicodeScalars.contains(u)
                if !ok { return nil }
            }
            let isUpper = CharacterSet.uppercaseLetters.contains(first)
            let caseless = !CharacterSet.lowercaseLetters.contains(first) && !isUpper
            if isUpper || caseless { capitalised += 1 }
            else if !(i > 0 && particles.contains(t.lowercased())) { return nil }
        }
        guard capitalised >= 1 else { return nil }
        if tokens.count == 1, text.count < 2 { return nil }
        return Plain(name: text, likely: tokens.count >= 2, isSelf: false)
    }
}
