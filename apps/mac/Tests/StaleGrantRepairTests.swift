import XCTest

final class StaleGrantRepairTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "StaleGrantRepairTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The bug: a row from a copy signed by someone else, switched on in
    /// system settings, and this copy still untrusted.
    func testAnUntrustedCopyUnderANewSignerForgetsTheRowOnce() {
        var resets = 0
        for _ in 0..<3 {
            StaleGrantRepair.runAtLaunch(
                defaults: defaults,
                trusted: { false },
                signer: { "mine" },
                reset: { _ in resets += 1 }
            )
        }
        XCTAssertEqual(resets, 1)
    }

    func testATrustedCopyIsNeverReset() {
        XCTAssertFalse(
            StaleGrantRepair.shouldReset(
                trusted: true,
                signer: "mine",
                repairedSigner: nil
            )
        )
    }

    func testANewSignerGetsItsOwnRepair() {
        XCTAssertTrue(
            StaleGrantRepair.shouldReset(
                trusted: false,
                signer: "new",
                repairedSigner: "old"
            )
        )
    }

    func testAnUnreadableSignatureResetsNothing() {
        XCTAssertFalse(
            StaleGrantRepair.shouldReset(
                trusted: false,
                signer: nil,
                repairedSigner: nil
            )
        )
    }
}
