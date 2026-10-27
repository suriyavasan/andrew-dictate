import AppKit
import Foundation

/// what a browser sign-in shares, chatgpt's and openrouter's alike: how
/// the browser is opened, how the loopback is started, and the ways it
/// can end short of signed in.
enum BrowserSignIn {
    /// opens a url in the user's browser; false if nothing could.
    typealias OpenURL = @Sendable (URL) async -> Bool

    static let openInBrowser: OpenURL = { url in
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    static let listenOnLoopback: CallbackListen = { path, state in
        try await LoopbackReceiver.start(path: path, expectedState: state)
    }

    /// the redirect, or the reason there is none. the receiver is always
    /// shut, however this ends.
    static func redirect(
        from receiver: any CallbackReceiving,
        opening url: URL,
        with openURL: OpenURL
    ) async throws -> [URLQueryItem] {
        defer {
            receiver.cancel()
        }
        guard await openURL(url) else {
            throw SignInFailure.browserUnavailable
        }
        do {
            return try await receiver.callback()
        } catch LoopbackFailure.timedOut {
            throw SignInFailure.timedOut
        } catch LoopbackFailure.couldNotListen {
            throw SignInFailure.couldNotListen
        } catch is CancellationError {
            throw SignInFailure.cancelled
        }
    }
}

/// why a sign-in did not finish, in the words settings shows under the
/// button.
enum SignInFailure: Error, Equatable, Sendable {
    case cancelled
    /// the user said no on the provider's page.
    case declined
    /// signed in, but the plan permission was left unticked.
    case planNotShared
    case browserUnavailable
    case couldNotListen
    case timedOut
    /// the redirect came back without what the provider promised.
    case incomplete
    /// a returning sign-in came back as someone else.
    case differentAccount
    /// the id token did not check out: bad signature, wrong audience,
    /// stale, or not for this attempt.
    case unverifiedIdentity
    /// the provider refused the exchange; the code says why.
    case refused(String)
    case network

    var reason: String {
        switch self {
        case .cancelled:
            "sign-in was cancelled"
        case .declined:
            "sign-in was declined in the browser"
        case .planNotShared:
            "chatgpt plan use wasn't allowed — sign in again and allow it"
        case .browserUnavailable:
            "couldn't open the browser"
        case .couldNotListen:
            "couldn't start the sign-in — try again"
        case .timedOut:
            "sign-in took too long — try again"
        case .incomplete:
            "sign-in didn't finish — try again"
        case .differentAccount:
            "that's a different account — sign out first to switch"
        case .unverifiedIdentity:
            "couldn't verify the account — try again"
        case let .refused(code):
            "sign-in was refused (\(code))"
        case .network:
            "no internet"
        }
    }
}
