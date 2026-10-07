import XCTest
@testable import Barveil

final class SpaceHopLockTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 5_000)

    func testDoesNotReleaseBeforeMinimumHold() {
        var lock = SpaceHopLock(minHold: 0.35, stableWindow: 0.20, maxHold: 1.5)
        lock.begin(at: t0)
        XCTAssertTrue(lock.isActive)
        XCTAssertFalse(lock.observe(signature: "a", at: t0.addingTimeInterval(0.10)))
        XCTAssertFalse(lock.observe(signature: "a", at: t0.addingTimeInterval(0.30)))
    }

    func testBeginIfIdleKeepsTheHopStartedByTheFastPath() {
        var lock = SpaceHopLock(minHold: 0.35, stableWindow: 0.20, maxHold: 1.5)
        lock.begin(at: t0)
        lock.markInitialCommitDone()
        // The regular sampler sees the same hop a few milliseconds later and
        // must not restart it (that would re-open the initial commit and
        // delay the correction).
        lock.beginIfIdle(at: t0.addingTimeInterval(0.05))
        XCTAssertFalse(lock.needsInitialCommit)
        XCTAssertFalse(lock.observe(signature: "a", at: t0.addingTimeInterval(0.10)))
        XCTAssertTrue(lock.observe(signature: "a", at: t0.addingTimeInterval(0.40)))
    }

    func testReleasesAfterStateIsStable() {
        var lock = SpaceHopLock(minHold: 0.35, stableWindow: 0.20, maxHold: 1.5)
        lock.begin(at: t0)
        XCTAssertFalse(lock.observe(signature: "a", at: t0.addingTimeInterval(0.10)))
        XCTAssertFalse(lock.observe(signature: "a", at: t0.addingTimeInterval(0.30)))
        XCTAssertTrue(lock.observe(signature: "a", at: t0.addingTimeInterval(0.40)))
        XCTAssertFalse(lock.isActive)
    }

    func testChangingSignatureRestartsStableWindow() {
        var lock = SpaceHopLock(minHold: 0.35, stableWindow: 0.20, maxHold: 1.5)
        lock.begin(at: t0)
        XCTAssertFalse(lock.observe(signature: "a", at: t0.addingTimeInterval(0.40)))
        XCTAssertFalse(lock.observe(signature: "b", at: t0.addingTimeInterval(0.50)))
        XCTAssertFalse(lock.observe(signature: "b", at: t0.addingTimeInterval(0.60)))
        XCTAssertTrue(lock.observe(signature: "b", at: t0.addingTimeInterval(0.75)))
    }

    func testMaxHoldReleasesEvenIfStateKeepsChanging() {
        var lock = SpaceHopLock(minHold: 0.35, stableWindow: 0.20, maxHold: 1.5)
        lock.begin(at: t0)
        XCTAssertFalse(lock.observe(signature: "a", at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(lock.observe(signature: "b", at: t0.addingTimeInterval(1.0)))
        XCTAssertTrue(lock.observe(signature: "c", at: t0.addingTimeInterval(1.5)))
        XCTAssertFalse(lock.isActive)
    }
}
