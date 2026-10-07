import XCTest
@testable import Barveil

final class AccessibilityPermissionTests: XCTestCase {
    func testFirstRequestShowsRegistrationWithoutOpeningSettings() {
        XCTAssertEqual(
            AccessibilityPermission.setupAction(isTrusted: false, hasRequested: false),
            .register,
        )
    }

    func testRepeatRequestOpensSettingsWithoutShowingPromptAgain() {
        XCTAssertEqual(
            AccessibilityPermission.setupAction(isTrusted: false, hasRequested: true),
            .openSettings,
        )
    }

    func testTrustedStateOpensSettingsDirectly() {
        XCTAssertEqual(
            AccessibilityPermission.setupAction(isTrusted: true, hasRequested: false),
            .openSettings,
        )
    }
}
