import XCTest
@testable import Barveil

final class DecisionStabilizerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testSingleSampleHideIsIgnored() {
        var stabilizer = DecisionStabilizer(initial: .show(.notFullScreen))
        let pending = stabilizer.update(proposed: .hide(.smart), at: t0)
        XCTAssertEqual(pending, .pending(.hide(.smart)))
        let cancelled = stabilizer.update(proposed: .show(.notFullScreen), at: t0.addingTimeInterval(0.10))
        XCTAssertEqual(cancelled, .cancelled(.hide(.smart)))
        XCTAssertEqual(stabilizer.current, .show(.notFullScreen))
    }

    func testHideAppliesAfterStabilityWindow() {
        var stabilizer = DecisionStabilizer(initial: .show(.notFullScreen), minimumDwell: 0)
        XCTAssertEqual(stabilizer.update(proposed: .hide(.smart), at: t0), .pending(.hide(.smart)))
        XCTAssertEqual(stabilizer.update(proposed: .hide(.smart), at: t0.addingTimeInterval(0.25)), .applied(.hide(.smart)))
        XCTAssertEqual(stabilizer.current, .hide(.smart))
    }

    func testShowAppliesAfterStabilityWindow() {
        var stabilizer = DecisionStabilizer(initial: .hide(.smart), minimumDwell: 0)
        XCTAssertEqual(stabilizer.update(proposed: .show(.notFullScreen), at: t0), .pending(.show(.notFullScreen)))
        XCTAssertEqual(stabilizer.update(proposed: .show(.notFullScreen), at: t0.addingTimeInterval(0.31)), .applied(.show(.notFullScreen)))
        XCTAssertEqual(stabilizer.current, .show(.notFullScreen))
    }

    func testMinimumDwellPreventsRapidFlip() {
        var stabilizer = DecisionStabilizer(initial: .show(.notFullScreen), hideStability: 0.1, showStability: 0.1, minimumDwell: 0.4)
        XCTAssertEqual(stabilizer.update(proposed: .hide(.smart), at: t0), .pending(.hide(.smart)))
        XCTAssertEqual(stabilizer.update(proposed: .hide(.smart), at: t0.addingTimeInterval(0.1)), .applied(.hide(.smart)))

        XCTAssertEqual(stabilizer.update(proposed: .show(.notFullScreen), at: t0.addingTimeInterval(0.2)), .pending(.show(.notFullScreen)))
        XCTAssertEqual(stabilizer.update(proposed: .show(.notFullScreen), at: t0.addingTimeInterval(0.31)), .none)
        XCTAssertEqual(stabilizer.update(proposed: .show(.notFullScreen), at: t0.addingTimeInterval(0.51)), .applied(.show(.notFullScreen)))
    }

    func testForceBypassesStability() {
        var stabilizer = DecisionStabilizer(initial: .show(.notFullScreen))
        XCTAssertEqual(stabilizer.force(.hide(.pinned), at: t0), .hide(.pinned))
        XCTAssertEqual(stabilizer.current, .hide(.pinned))
    }
}
