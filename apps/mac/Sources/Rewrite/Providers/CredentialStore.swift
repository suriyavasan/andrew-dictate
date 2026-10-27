import Foundation
import Security

/// where keys and sign-ins live. one item per account name; the value is
/// opaque bytes — a pasted key, or a sign-in's json.
///
/// nothing here, and nothing that calls it, logs a value. a secret that
/// reaches a log reaches every diagnostics bundle a user ever sends.
protocol CredentialStoring: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func remove(_ account: String) throws
}

/// the names items are filed under. a provider's key is its rawValue, as
/// settings stores it; chatgpt keeps two more records beside its session.
enum CredentialAccount {
    static func key(_ provider: RewriteProvider) -> String {
        provider.rawValue
    }

    /// the chatgpt sign-in: tokens, expiry, email.
    static let chatGPTSession = RewriteProvider.chatGPT.rawValue

    /// which openai registration this mac signed in with. it outlives
    /// signing out, so signing back in reuses the same client instead of
    /// registering another app in the user's chatgpt settings.
    static let chatGPTRegistration = "chatGPT.registration"

    /// this mac's `ext_agent_host_id`. chosen once, before the first
    /// sign-in, and never changed.
    static let chatGPTHost = "chatGPT.host"
}

extension CredentialStoring {
    func string(for account: String) throws -> String? {
        try data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setString(_ value: String, for account: String) throws {
        try set(Data(value.utf8), for: account)
    }

    func decoded<Value: Decodable>(
        _ type: Value.Type,
        for account: String
    ) throws -> Value? {
        guard let data = try data(for: account) else {
            return nil
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func setEncoded(_ value: some Encodable, for account: String) throws {
        try set(JSONEncoder().encode(value), for: account)
    }
}

enum CredentialStoreError: Error, Equatable, Sendable {
    /// the keychain said no; the OSStatus says why. never the value.
    case keychain(OSStatus)
}

/// the login keychain, one generic-password item per account, under the
/// service `<bundle id>.rewrite`: the dev build has its own bundle id, so it
/// has its own keys and never reads the shipped app's.
///
/// release builds are ad-hoc signed, and the login keychain ties an item's
/// access to the signature of the app that made it. a new version is a new
/// signature, so after an update macOS may ask once to allow access to the
/// stored key; "always allow" settles it until the next update. the data
/// protection keychain would not ask, but it needs a team-signed
/// entitlement this app does not have.
///
/// AfterFirstUnlock, because a rewrite can run before anything else has
/// touched the keychain since login. never synchronizable: a key typed on
/// this mac stays on this mac, and does not go to icloud.
struct KeychainCredentialStore: CredentialStoring {
    let service: String

    /// `bundleID` is AppIdentity.bundleID in the app.
    init(bundleID: String) {
        self.service = "\(bundleID).rewrite"
    }

    private func query(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }

    func data(for account: String) throws -> Data? {
        var lookup = query(account)
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status)
        }
    }

    func set(_ data: Data, for account: String) throws {
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(
            query(account) as CFDictionary,
            update as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query(account)
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel] = "Andrew Dictate (\(account))"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw CredentialStoreError.keychain(added)
            }
        default:
            throw CredentialStoreError.keychain(status)
        }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }
}

/// the keychain's stand-in for tests and previews: a dictionary behind a
/// lock, forgotten when the process ends.
final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]

    init(_ items: [String: Data] = [:]) {
        self.items = items
    }

    func data(for account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    func set(_ data: Data, for account: String) throws {
        lock.withLock { items[account] = data }
    }

    func remove(_ account: String) throws {
        _ = lock.withLock { items.removeValue(forKey: account) }
    }

    var accounts: [String] {
        lock.withLock { items.keys.sorted() }
    }
}
