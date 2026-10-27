import CryptoKit
import Foundation
import Security

/// proof key for code exchange (RFC 7636), S256 only. the verifier stays in
/// this process; only its hash goes to the browser, so a code read off the
/// loopback redirect by anything else on the mac is useless without it.
struct PKCE: Equatable, Sendable {
    let verifier: String
    let challenge: String

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// 32 random bytes as base64url: 43 characters, the RFC's minimum
    /// length and well inside its alphabet.
    static func make() -> PKCE {
        PKCE(verifier: randomToken())
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
    }

    /// a fresh unguessable value for a verifier, a `state` or a `nonce`.
    static func randomToken(bytes count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes does not fail on a working mac; if it
            // ever did, CryptoKit's generator is the same source.
            bytes = SymmetricKey(size: .init(bitCount: count * 8))
                .withUnsafeBytes { Array($0) }
        }
        return Data(bytes).base64URLEncodedString
    }
}
