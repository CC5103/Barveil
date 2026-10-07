import XCTest
@testable import Barveil

@MainActor
final class VeilControllerPolicyTests: XCTestCase {
    func testVisibleBaselineDoesNotDependOnInitialSystemValue() {
        XCTAssertTrue(VeilController.managedValue(hidden: false))
    }

    func testPlaybackAlwaysUsesHiddenSystemValue() {
        XCTAssertFalse(VeilController.managedValue(hidden: true))
    }
}
