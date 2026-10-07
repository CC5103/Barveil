// The decision table is the only part of Barveil that can be tested without
// a screen, an audio device or a running app, so it carries the tests.

import XCTest
@testable import Barveil

final class DecisionTests: XCTestCase {
    private func input(
        enabled: Bool = true,
        mode: HideMode = .smart,
        pin: ManualPin = .none,
        bundleID: String? = "com.example.player",
        fullScreen: Bool = true,
        playing: Bool = true,
        excluded: Bool = false,
        showBarWhenPaused: Bool = true,
    ) -> DecisionInput {
        DecisionInput(
            enabled: enabled,
            mode: mode,
            pin: pin,
            frontAppBundleID: bundleID,
            isFullScreen: fullScreen,
            isPlaying: playing,
            isExcluded: excluded,
            showBarWhenPaused: showBarWhenPaused,
        )
    }

    func testHidesOnlyWhenFullScreenAndPlaying() {
        XCTAssertEqual(decide(input()), .hide(.smart))
        XCTAssertEqual(decide(input(fullScreen: false)), .show(.notFullScreen))
        XCTAssertEqual(decide(input(playing: false)), .show(.notPlaying))
    }

    func testPausedFullScreenCanKeepTheBarHidden() {
        // The user's choice: pausing a full screen video either brings the bar
        // back (default) or leaves it hidden until the picture is gone.
        XCTAssertEqual(decide(input(playing: false)), .show(.notPlaying))
        XCTAssertEqual(decide(input(playing: false, showBarWhenPaused: false)), .hide(.smart))
        // Leaving full screen always gives the bar back.
        XCTAssertEqual(
            decide(input(fullScreen: false, playing: false, showBarWhenPaused: false)),
            .show(.notFullScreen),
        )
        // Windowed playback keeps the same answer either way.
        XCTAssertEqual(
            decide(input(fullScreen: false, playing: true, showBarWhenPaused: false)),
            .show(.notFullScreen),
        )
    }

    func testDisabledBeatsEverythingElse() {
        XCTAssertEqual(decide(input(enabled: false)), .show(.disabled))
        XCTAssertEqual(decide(input(enabled: false, pin: .hide)), .show(.disabled))
    }

    func testPinOutranksAutomaticGates() {
        XCTAssertEqual(decide(input(pin: .hide, fullScreen: false, playing: false)), .hide(.pinned))
        XCTAssertEqual(decide(input(pin: .show)), .show(.pinned))
    }

    func testManualModeNeverHidesOnItsOwn() {
        XCTAssertEqual(decide(input(mode: .manual)), .show(.manualMode))
        XCTAssertEqual(decide(input(mode: .manual, pin: .hide)), .hide(.pinned))
    }

    func testExcludedAppWinsOverHide() {
        XCTAssertEqual(decide(input(excluded: true)), .show(.excludedApp))
    }

    func testExclusionDoesNotOverrideAPin() {
        // A pin is an explicit user action and outranks the exclusion list;
        // the exclusion list only stops *automatic* hiding.
        XCTAssertEqual(decide(input(pin: .hide, excluded: true)), .hide(.pinned))
    }

    func testMissingFrontAppReportsItsOwnReason() {
        XCTAssertEqual(decide(input(bundleID: nil)), .show(.noFrontApp))
    }

    func testGateOrderingIsStable() {
        // Full screen fails before playback does.
        XCTAssertEqual(decide(input(fullScreen: false, playing: false)), .show(.notFullScreen))
        // The exclusion list is consulted before the mode gates, so an
        // excluded app reports that as the reason whatever else is true.
        XCTAssertEqual(decide(input(playing: false, excluded: true)), .show(.excludedApp))
    }

    func testDiagnosticTags() {
        XCTAssertEqual(decide(input()).diagnosticTag, "hide(smart)")
        XCTAssertEqual(decide(input(playing: false)).diagnosticTag, "show(notPlaying)")
        XCTAssertTrue(decide(input()).shouldHide)
        XCTAssertFalse(decide(input(playing: false)).shouldHide)
    }

    func testModesCoverEveryCase() {
        XCTAssertEqual(HideMode.allCases, [.smart, .manual])
    }
}
