import Foundation
import Security

/// an openid id token (a JWT), checked the way openai's sign-in guide asks:
/// an RS256 signature against openai's published keys, then issuer,
/// audience, expiry and nonce. all pure — the keys come in as the jwks
/// json, fetched by whoever calls this.
struct IDToken: Equatable, Sendable {
    let header: [String: String]
    let subject: String
    let email: String?
    let issuer: String
    let audiences: [String]
    let authorizedParty: String?
    let nonce: String?
    let expiresAt: Date
    let issuedAt: Date?
    /// header.payload, the bytes the signature covers.
    let signingInput: Data
    let signature: Data

    enum Problem: Error, Equatable, Sendable {
        case malformed
        case unsupportedAlgorithm
        case unknownKey
        case badSignature
        case wrongIssuer
        case wrongAudience
        case expired
        case wrongNonce
    }

    /// the three dot-separated parts, decoded. no checking yet.
    static func decode(_ jwt: String) throws -> IDToken {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Data(base64URLEncoded: String(parts[0])),
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let signature = Data(base64URLEncoded: String(parts[2])),
              let headerObject = RewriteHTTP.object(headerData),
              let claims = RewriteHTTP.object(payloadData),
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let issuer = claims["iss"] as? String,
              let exp = (claims["exp"] as? NSNumber)?.doubleValue
        else {
            throw Problem.malformed
        }
        let audiences: [String]
        if let single = claims["aud"] as? String {
            audiences = [single]
        } else if let many = claims["aud"] as? [String] {
            audiences = many
        } else {
            throw Problem.malformed
        }
        return IDToken(
            header: headerObject.compactMapValues { $0 as? String },
            subject: subject,
            email: claims["email"] as? String,
            issuer: issuer,
            audiences: audiences,
            authorizedParty: claims["azp"] as? String,
            nonce: claims["nonce"] as? String,
            expiresAt: Date(timeIntervalSince1970: exp),
            issuedAt: (claims["iat"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            },
            signingInput: Data("\(parts[0]).\(parts[1])".utf8),
            signature: signature
        )
    }

    /// the claims, against this attempt. `nonce` nil skips the nonce: a
    /// refreshed id token answers no authorize request, so it has none of
    /// ours to carry. five seconds of clock skew, as openai's own kit allows.
    func checkClaims(
        issuer expectedIssuer: String,
        clientID: String,
        nonce expectedNonce: String?,
        now: Date
    ) throws {
        guard issuer == expectedIssuer else {
            throw Problem.wrongIssuer
        }
        guard audiences.contains(clientID),
              audiences.count == 1 || authorizedParty == clientID,
              authorizedParty == nil || authorizedParty == clientID
        else {
            throw Problem.wrongAudience
        }
        guard expiresAt.timeIntervalSince(now) > -5 else {
            throw Problem.expired
        }
        if let expectedNonce, nonce != expectedNonce {
            throw Problem.wrongNonce
        }
    }

    /// RS256 against the key the header names, out of a jwks document.
    func checkSignature(jwks: Data) throws {
        guard header["alg"] == "RS256" else {
            throw Problem.unsupportedAlgorithm
        }
        guard let keys = RewriteHTTP.object(jwks)?["keys"] as? [[String: Any]],
              let jwk = keys.first(where: {
                  ($0["kid"] as? String) == header["kid"] && ($0["kty"] as? String) == "RSA"
              }),
              let n = (jwk["n"] as? String).flatMap(Data.init(base64URLEncoded:)),
              let e = (jwk["e"] as? String).flatMap(Data.init(base64URLEncoded:)),
              let key = Self.rsaPublicKey(modulus: n, exponent: e)
        else {
            throw Problem.unknownKey
        }
        let valid = SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData,
            signature as CFData,
            nil
        )
        guard valid else {
            throw Problem.badSignature
        }
    }

    /// a jwk's modulus and exponent as a SecKey. Security takes an RSA
    /// public key as PKCS#1 DER — SEQUENCE { INTEGER n, INTEGER e } — so
    /// that is what is built.
    static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        let der = DER.sequence(DER.integer(modulus) + DER.integer(exponent))
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

/// just enough ASN.1 DER to wrap two integers.
enum DER {
    static func length(_ count: Int) -> Data {
        if count < 0x80 {
            return Data([UInt8(count)])
        }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    /// an unsigned big-endian integer: leading zeros dropped, then one put
    /// back if the top bit is set, so it does not read as negative.
    static func integer(_ magnitude: Data) -> Data {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if bytes.isEmpty || bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return Data([0x02]) + length(bytes.count) + Data(bytes)
    }

    static func sequence(_ contents: Data) -> Data {
        Data([0x30]) + length(contents.count) + contents
    }
}
