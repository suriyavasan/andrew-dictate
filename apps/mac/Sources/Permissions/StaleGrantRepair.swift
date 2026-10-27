import ApplicationServices
import Foundation
import Security

/// TCC keeps an accessibility grant with the code requirement of the app that
/// asked for it, not just its bundle id. a mac that once ran a copy signed by
/// someone else — another tap's build, an old release — keeps that row: it
/// shows `andrew dictate` switched on in system settings, and this copy is
/// still not trusted, so setup asks again and every take is left on the
/// clipboard. switching the row off and on changes nothing; only removing it
/// does.
///
/// so, at launch: not trusted, under a signer this mac has not seen us repair
/// for — the row, if any, is someone else's. forget it once, and the prompt
/// setup already shows adds a fresh row this copy matches. once per signer,
/// so a person who simply has not granted yet is never reset twice.
enum StaleGrantRepair {
    static let repairedSignerKey = "accessibilityRepairedForSigner"

    /// the whole policy. untrusted is the only state where forgetting the row
    /// costs nothing: it is not working for this copy anyway.
    static func shouldReset(
        trusted: Bool,
        signer: String?,
        repairedSigner: String?
    ) -> Bool {
        guard !trusted, let signer else {
            return false
        }
        return signer != repairedSigner
    }

    static func runAtLaunch(
        defaults: UserDefaults = .standard,
        trusted: () -> Bool = { AXIsProcessTrusted() },
        signer: () -> String? = currentSigner,
        reset: (String) -> Void = resetAccessibility
    ) {
        let signer = signer()
        guard shouldReset(
            trusted: trusted(),
            signer: signer,
            repairedSigner: defaults.string(forKey: repairedSignerKey)
        ) else {
            return
        }
        reset(AppIdentity.bundleID)
        defaults.set(signer, forKey: repairedSignerKey)
    }

    /// this copy's designated requirement: the thing TCC compares a row
    /// against. it changes exactly when the signer does.
    static func currentSigner() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            staticCode, [], &requirement
        ) == errSecSuccess, let requirement else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess
        else {
            return nil
        }
        return text as String?
    }

    /// accessibility and post-event both: the paste is a posted ⌘V, and
    /// system settings lists both under accessibility. a service with no row
    /// for us exits non-zero, which is fine.
    static func resetAccessibility(_ bundleID: String) {
        for service in ["Accessibility", "PostEvent"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }
        }
    }
}
