import XCTest
@testable import Barveil

final class PanelPresentationTests: XCTestCase {
    func testDisabledStatePrioritisesTurningAutomationBackOn() {
        let state = MenuBarPanelPresentation.make(
            isEnabled: false,
            decision: .show(.disabled),
            isFrontAppExcluded: false,
        )

        XCTAssertEqual(state.tone, .inactive)
        XCTAssertEqual(state.primaryAction, .enableAutomation)
        XCTAssertFalse(state.isPinned)
    }

    func testReadyStateOffersAQuietManualHide() {
        let state = MenuBarPanelPresentation.make(
            isEnabled: true,
            decision: .show(.notFullScreen),
            isFrontAppExcluded: false,
        )

        XCTAssertEqual(state.tone, .ready)
        XCTAssertEqual(state.primaryAction, .hideMenuBar)
        XCTAssertEqual(state.systemName, "play.rectangle.fill")
    }

    func testSmartHideStateOffersShowingTheBarAgain() {
        let state = MenuBarPanelPresentation.make(
            isEnabled: true,
            decision: .hide(.smart),
            isFrontAppExcluded: false,
        )

        XCTAssertEqual(state.tone, .active)
        XCTAssertEqual(state.primaryAction, .showMenuBar)
    }

    func testPinnedStateCanBeRestoredToAutomaticControl() {
        let state = MenuBarPanelPresentation.make(
            isEnabled: true,
            decision: .hide(.pinned),
            isFrontAppExcluded: false,
        )

        XCTAssertTrue(state.isPinned)
        XCTAssertEqual(state.primaryAction, .showMenuBar)
    }

    func testManualModeRemainsActionable() {
        let state = MenuBarPanelPresentation.make(
            isEnabled: true,
            decision: .show(.manualMode),
            isFrontAppExcluded: false,
        )

        XCTAssertEqual(state.tone, .waiting)
        XCTAssertEqual(state.primaryAction, .hideMenuBar)
    }

    func testExclusionOverridesTheAutomaticDecision() {
        let state = MenuBarPanelPresentation.make(
            isEnabled: true,
            decision: .hide(.smart),
            isFrontAppExcluded: true,
        )

        XCTAssertEqual(state.tone, .waiting)
        XCTAssertEqual(state.primaryAction, .includeCurrentApp)
    }

    func testTransitionDoesNotOfferAConflictingAction() {
        let state = MenuBarPanelPresentation.make(
            isEnabled: true,
            decision: .show(.transition),
            isFrontAppExcluded: false,
        )

        XCTAssertEqual(state.primaryAction, .none)
    }
}
