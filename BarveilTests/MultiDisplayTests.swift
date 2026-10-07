// Two displays, one app, several windows: the decision has to be made per
// display and it has to agree on *which* window it is talking about. These
// tests pin the window/display picking and the cases that only show up with a
// second screen attached.

import XCTest
@testable import Barveil

final class MultiDisplayTests: XCTestCase {
    /// MacBook screen with a camera housing, and the external display that
    /// sits above-left of it (CoreGraphics coordinates: top-left origin).
    /// Both rows are the real numbers this machine reports.
    private let builtIn = DisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        menuBarHeight: 33,
        name: "Built-in",
    )
    private let external = DisplayGeometry(
        frame: CGRect(x: -373, y: -1080, width: 1920, height: 1080),
        menuBarHeight: 30,
        name: "External",
    )

    private let frontPID: pid_t = 5150
    private let otherPID: pid_t = 77

    private var displays: [DisplayGeometry] { [builtIn, external] }
    private var builtInFullScreen: CGRect { builtIn.frame }
    private var externalFullScreen: CGRect { external.frame }
    private let windowed = CGRect(x: 200, y: 200, width: 900, height: 600)

    private func window(
        _ rect: CGRect,
        pid: pid_t? = nil,
        layer: Int = 0,
        alpha: Double = 1,
    ) -> WindowSnapshot {
        WindowSnapshot(ownerPID: pid ?? frontPID, layer: layer, alpha: alpha, bounds: rect)
    }

    private func covering(_ windows: [WindowSnapshot]) -> [CoveringWindow] {
        FullscreenDetector.coveringWindows(
            windows: windows,
            displays: displays,
            appPID: frontPID,
        )
    }

    // MARK: - Which windows fill which display

    func testWindowOnTheSecondDisplayIsMatchedToThatDisplay() {
        let found = covering([window(externalFullScreen)])

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.display.name, "External")
    }

    func testBothDisplaysCoveredReportsBothDisplays() {
        let found = covering([window(builtInFullScreen), window(externalFullScreen)])

        XCTAssertEqual(Set(found.map(\.display.name)), ["Built-in", "External"])
    }

    func testWindowsOfOtherAppsAndWindowedWindowsAreIgnored() {
        let found = covering([
            window(builtInFullScreen, pid: otherPID),
            window(externalFullScreen, pid: otherPID),
            window(windowed),
        ])

        XCTAssertTrue(found.isEmpty)
    }

    func testFullscreenVideoOfAnotherAppOnAnotherDisplayDoesNotCount() {
        // The video is fullscreen on the external display, but the app in
        // front has only an ordinary window on the built-in display. Windows
        // owned by other apps must never make the visible page look fullscreen.
        let state = FullscreenDetector.classify(
            windows: [
                window(externalFullScreen, pid: otherPID),
                window(windowed),
            ],
            displays: displays,
            appPID: frontPID,
            pointer: CGPoint(x: 400, y: 400),
        )

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.displayName, "Built-in")
    }

    func testAccessibilityWindowOnAnotherDisplayIsRejected() {
        // AX reports the fullscreen window, but the pointer is on the display
        // where the same app also has an ordinary window. The ordinary window
        // is what the user is working with, so AX must not win this argument.
        let accepted = FullscreenDetector.isAccessibilityWindowOnActiveDisplay(
            frame: externalFullScreen,
            windows: [
                window(windowed),
                window(externalFullScreen),
            ],
            displays: displays,
            appPID: frontPID,
            pointer: CGPoint(x: 400, y: 400),
        )

        XCTAssertFalse(accepted)
    }

    func testAccessibilityWindowOnActiveDisplayIsAccepted() {
        // The pointer is parked on the built-in display, but this app has no
        // window there. Its only on-screen window is the fullscreen video on
        // the external display, so the AX answer is still trustworthy.
        let accepted = FullscreenDetector.isAccessibilityWindowOnActiveDisplay(
            frame: externalFullScreen,
            windows: [window(externalFullScreen)],
            displays: displays,
            appPID: frontPID,
            pointer: CGPoint(x: 400, y: 400),
        )

        XCTAssertTrue(accepted)
    }

    func testAccessibilityWindowFromAnotherSpaceIsRejected() {
        // AX can describe a window on another Space; the on-screen window
        // list deliberately cannot. The mismatch must fall back to geometry
        // instead of hiding the bar for an invisible window.
        let accepted = FullscreenDetector.isAccessibilityWindowOnActiveDisplay(
            frame: externalFullScreen,
            windows: [window(windowed)],
            displays: displays,
            appPID: frontPID,
            pointer: CGPoint(x: 400, y: 400),
        )

        XCTAssertFalse(accepted)
    }

    // MARK: - Picking the display the user is on

    func testPointerOnTheSecondDisplayPicksThatWindow() {
        let found = covering([window(builtInFullScreen), window(externalFullScreen)])

        // A point inside the external display, which sits above the built-in.
        let picked = FullscreenDetector.best(covering: found, near: CGPoint(x: 0, y: -500))

        XCTAssertEqual(picked?.display.name, "External")
    }

    func testPointerOnTheBuiltInDisplayPicksThatWindow() {
        let found = covering([window(builtInFullScreen), window(externalFullScreen)])

        let picked = FullscreenDetector.best(covering: found, near: CGPoint(x: 400, y: 400))

        XCTAssertEqual(picked?.display.name, "Built-in")
    }

    func testPointerOffEveryDisplayFallsBackToALargeWindow() {
        let found = covering([window(builtInFullScreen), window(externalFullScreen)])

        let picked = FullscreenDetector.best(covering: found, near: CGPoint(x: 9000, y: 9000))

        XCTAssertNotNil(picked)
    }

    func testWindowedWindowInFrontOnCurrentDisplayIgnoresFullscreenWindowElsewhere() {
        // This is the same-app version of the original false positive: a
        // video is fullscreen on the external display, while the app's key
        // window is a normal window on the built-in display. The window list
        // is ordered front-to-back, so the normal window is first.
        let state = FullscreenDetector.classify(
            windows: [
                window(windowed),
                window(externalFullScreen),
            ],
            displays: displays,
            appPID: frontPID,
        )

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.displayName, "Built-in")
    }

    func testFullscreenWindowInFrontOnItsDisplayStillCounts() {
        // The same two windows, but the fullscreen one is the key window.
        let state = FullscreenDetector.classify(
            windows: [
                window(externalFullScreen),
                window(windowed),
            ],
            displays: displays,
            appPID: frontPID,
        )

        XCTAssertTrue(state.isFullScreen)
        XCTAssertEqual(state.displayName, "External")
    }

    func testPointerChoosesOwnWindowOnCurrentDisplayWhenWindowListOrderDisagrees() {
        // Even if the window server lists the external fullscreen window
        // first, the pointer is over the app's ordinary window on the
        // built-in display. That is the display the user is working on.
        let state = FullscreenDetector.classify(
            windows: [
                window(externalFullScreen),
                window(windowed),
            ],
            displays: displays,
            appPID: frontPID,
            pointer: CGPoint(x: 400, y: 400),
        )

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.displayName, "Built-in")
    }

    func testCoveringWindowStillCountsWhenPointerDisplayHasNoAppWindow() {
        // The pointer happens to be parked on the built-in display, but this
        // app has no window there: the fullscreen video on the external
        // display is still the only thing the app is showing, so it counts.
        let state = FullscreenDetector.classify(
            windows: [window(externalFullScreen)],
            displays: displays,
            appPID: frontPID,
            pointer: CGPoint(x: 400, y: 400),
        )

        XCTAssertTrue(state.isFullScreen)
        XCTAssertEqual(state.displayName, "External")
    }

    // MARK: - The browser rule across displays

    func testBrowserFollowsTheDisplayTheUserIsOn() {
        // Display A holds the fullscreen browser window (chrome visible),
        // display B holds a fullscreen picture. The answer has to follow the
        // display the pointer is on, not the first window in the list.
        let onBuiltIn = CoveringWindow(bounds: builtInFullScreen, display: builtIn)
        let onExternal = CoveringWindow(bounds: externalFullScreen, display: external)
        let found = [onBuiltIn, onExternal]

        let pickedOnBuiltIn = FullscreenDetector.best(covering: found, near: CGPoint(x: 400, y: 400))
        let pickedOnExternal = FullscreenDetector.best(covering: found, near: CGPoint(x: 0, y: -500))

        let windowState = FullscreenDetector.browserState(
            covering: pickedOnBuiltIn,
            chromeVisible: true,
            accessibilityAvailable: true,
        )
        let pictureState = FullscreenDetector.browserState(
            covering: pickedOnExternal,
            chromeVisible: false,
            accessibilityAvailable: true,
        )

        XCTAssertFalse(windowState.isFullScreen)
        XCTAssertTrue(pictureState.isFullScreen)
        XCTAssertEqual(pictureState.detail.contains("External"), true)
    }

    func testBrowserFocusedWindowOnCurrentDisplayRejectsOtherDisplayCoveringWindow() {
        // The focused browser window is ordinary and lives on the built-in
        // display; the only covering window is a video fullscreen on the
        // external display. The focused window wins, so this is not fullscreen
        // on the display the user is working on.
        let target = FullscreenDetector.preferredCovering(
            covering: [CoveringWindow(bounds: externalFullScreen, display: external)],
            windows: [
                window(windowed),
                window(externalFullScreen),
            ],
            displays: displays,
            appPID: frontPID,
            focusedFrame: windowed,
        )

        XCTAssertNil(target)
    }

    func testBrowserFocusedCoveringWindowWinsOverAnotherCoveringWindow() {
        let target = FullscreenDetector.preferredCovering(
            covering: [
                CoveringWindow(bounds: builtInFullScreen, display: builtIn),
                CoveringWindow(bounds: externalFullScreen, display: external),
            ],
            windows: [
                window(builtInFullScreen),
                window(externalFullScreen),
            ],
            displays: displays,
            appPID: frontPID,
            focusedFrame: externalFullScreen,
        )

        XCTAssertEqual(target?.display.name, "External")
    }

    func testVideoFullscreenWithVisibleMenuBarOnSecondaryDisplayCounts() {
        // Safari's video-fullscreen dialog on the external display is
        // 1920x1050 on a 1080p display: the 30 pt strip at the top is the
        // menu bar that Barveil is about to hide. DisplayLayout may report
        // menuBarHeight == 0 for this secondary display, so the classifier
        // has to assume the standard strip instead of rejecting the window.
        let externalWithoutReportedMenuBar = DisplayGeometry(
            frame: external.frame,
            menuBarHeight: 0,
            name: "External",
        )
        let videoFullscreen = CGRect(
            x: external.frame.minX,
            y: external.frame.minY + 30,
            width: external.frame.width,
            height: external.frame.height - 30,
        )

        let state = FullscreenDetector.classify(
            windows: [window(videoFullscreen)],
            displays: [externalWithoutReportedMenuBar],
            appPID: frontPID,
            pointer: CGPoint(x: external.frame.midX, y: external.frame.midY),
        )

        XCTAssertTrue(state.isFullScreen)
        XCTAssertEqual(state.displayName, "External")
    }

    func testFullscreenWindowOnAnUnpluggedDisplayNoLongerCounts() {
        // The window is still in the list, but its display is gone: nothing
        // covers the displays that are actually attached.
        let state = FullscreenDetector.classify(
            windows: [window(externalFullScreen)],
            displays: [builtIn],
            appPID: frontPID,
        )

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.source, .geometry)
    }

    func testDisplayListIsReadFreshSoPluggingInIsPickedUp() {
        // Same window, two display lists: one without the display it fills,
        // one with it. No cached geometry may keep the first answer around.
        let without = FullscreenDetector.classify(
            windows: [window(externalFullScreen)],
            displays: [builtIn],
            appPID: frontPID,
        )
        let with = FullscreenDetector.classify(
            windows: [window(externalFullScreen)],
            displays: displays,
            appPID: frontPID,
        )

        XCTAssertFalse(without.isFullScreen)
        XCTAssertTrue(with.isFullScreen)
        XCTAssertEqual(with.detail, "1920x1080 on External")
    }

    func testWindowStraddlingTheSeamIsNotFullscreen() {
        // Sitting across the join between the two displays fills neither of
        // them, and macOS never makes a fullscreen window span displays.
        let straddling = CGRect(x: -100, y: -100, width: 300, height: 300)

        XCTAssertTrue(covering([window(straddling)]).isEmpty)
    }
}
