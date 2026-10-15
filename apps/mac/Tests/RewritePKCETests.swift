import XCTest

final class RewritePKCETests: XCTestCase {
    /// RFC 7636, appendix B: the one vector everyone checks against.
    func testTheRFCVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    /// 43 to 128 characters of [A-Za-z0-9-._~], and never padded.
    func testAMadeVerifierIsInsideTheRFCAlphabet() {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        for _ in 0..<50 {
            let pkce = PKCE.make()
            XCTAssertTrue((43...128).contains(pkce.verifier.count))
            XCTAssertTrue(
                pkce.verifier.unicodeScalars.allSatisfy(allowed.contains),
                pkce.verifier
            )
            XCTAssertFalse(pkce.challenge.contains("="))
            XCTAssertEqual(pkce.challenge, PKCE.challenge(for: pkce.verifier))
        }
    }

    func testEveryTokenIsFresh() {
        let tokens = (0..<100).map { _ in PKCE.randomToken() }

        XCTAssertEqual(Set(tokens).count, 100)
    }

    func testBase64URLRoundTrips() {
        let bytes = Data((0...255).map(UInt8.init))
        let encoded = bytes.base64URLEncodedString

        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Data(base64URLEncoded: encoded), bytes)
        XCTAssertEqual(Data(base64URLEncoded: "AQAB"), Data([1, 0, 1]))
        XCTAssertNil(Data(base64URLEncoded: "A"))
    }
}
