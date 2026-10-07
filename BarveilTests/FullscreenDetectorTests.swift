// The fullscreen classifier decides whether the app *in front* is fullscreen.
// These tests are the ones that matter for the "video fullscreen elsewhere,
// windowed app here" case: only the front app's own on-screen windows may
// ever count, and only if they really span a display.

import XCTest
@testable import Barveil

final class FullscreenDetectorTests: XCTestCase {
    /// 14" MacBook Pro: 1728×1117 with a 33 pt menu bar strip.
    private let builtIn = DisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        menuBarHeight: 33,
        name: "Built-in",
    )

    private let external = DisplayGeometry(
        frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
        menuBarHeight: 0,
        name: "External",
    )

    private let frontPID: pid_t = 4242
    private let otherPID: pid_t = 99

    private var displays: [DisplayGeometry] { [builtIn, external] }

    private func window(
        _ pid: pid_t,
        _ rect: CGRect,
        layer: Int = 0,
        alpha: Double = 1,
    ) -> WindowSnapshot {
        WindowSnapshot(ownerPID: pid, layer: layer, alpha: alpha, bounds: rect)
    }

    private func classify(_ windows: [WindowSnapshot], pid: pid_t? = nil) -> FullscreenState {
        FullscreenDetector.classify(windows: windows, displays: displays, appPID: pid ?? frontPID)
    }

    // MARK: - The case that triggered this file

    func testFullscreenWindowOfAnotherAppDoesNotCount() {
        // A video is fullscreen and playing somewhere else; the app in front
        // is an ordinary window on the visible page.
        let state = classify([
            window(otherPID, CGRect(x: 0, y: 0, width: 1728, height: 1117)),
            window(frontPID, CGRect(x: 370, y: 156, width: 720, height: 437)),
        ])

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.source, .geometry)
    }

    func testOffSpaceWindowsAreInvisibleToTheClassifier() {
        // `CGWindowList(.optionOnScreenOnly)` only returns the active Space's
        // windows, so a fullscreen window elsewhere simply is not in the list.
        let state = classify([
            window(frontPID, CGRect(x: 220, y: 220, width: 720, height: 437)),
        ])

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.source, .geometry)
    }

    func testNoWindowsAtAllReportsUnavailable() {
        let state = classify([window(otherPID, CGRect(x: 0, y: 0, width: 1728, height: 1117))])

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.source, .unavailable)
    }

    // MARK: - AX fullscreen windows missing from the window list

    func testUnlistedAXFullscreenWindowIsTrustedOnItsDisplay() {
        // IINA/mpv keeps its small windowed surface in the window list while
        // the focused AX window reports the fullscreen picture.
        let fullscreen = CGRect(x: 0, y: 33, width: 1728, height: 1084)
        let smallSurface = window(frontPID, CGRect(x: 124, y: 655, width: 300, height: 372))

        XCTAssertTrue(FullscreenDetector.shouldTrustUnlistedAccessibilityFullscreen(
            frame: fullscreen,
            windows: [smallSurface],
            displays: displays,
            appPID: frontPID,
            pointer: CGPoint(x: 800, y: 500),
        ))
    }

    func testUnlistedAXFullscreenWindowOnAnotherDisplayIsRejected() {
        let fullscreen = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
        let smallSurface = window(frontPID, CGRect(x: 124, y: 655, width: 300, height: 372))

        XCTAssertFalse(FullscreenDetector.shouldTrustUnlistedAccessibilityFullscreen(
            frame: fullscreen,
            windows: [smallSurface],
            displays: displays,
            appPID: frontPID,
            pointer: CGPoint(x: 800, y: 500),
        ))
    }

    // MARK: - Real fullscreen

    func testFullscreenWindowCoveringTheDisplayCounts() {
        // Notched display: the window runs all the way to the top.
        let state = classify([window(frontPID, CGRect(x: 0, y: 0, width: 1728, height: 1117))])

        XCTAssertTrue(state.isFullScreen)
        XCTAssertEqual(state.detail, "1728x1117 on Built-in")
    }

    func testNativeFullscreenWithMenuBarVisibleCounts() {
        // Non-notched display: the window starts below the bar but reaches the
        // bottom edge, which a maximised window never does.
        let state = classify([window(frontPID, CGRect(x: 0, y: 33, width: 1728, height: 1084))])

        XCTAssertTrue(state.isFullScreen)
    }

    func testFullscreenWindowOnASecondDisplayIsMatchedToThatDisplay() {
        let state = classify([window(frontPID, CGRect(x: 1728, y: 0, width: 2560, height: 1440))])

        XCTAssertTrue(state.isFullScreen)
        XCTAssertEqual(state.detail, "2560x1440 on External")
    }

    // MARK: - Things that must not look like fullscreen

    func testMaximizedWindowIsNotFullscreen() {
        // Menu bar at the top, Dock at the bottom: fills the visible frame only.
        let state = classify([window(frontPID, CGRect(x: 0, y: 33, width: 1728, height: 1004))])

        XCTAssertFalse(state.isFullScreen)
    }

    func testHalfScreenWindowIsNotFullscreen() {
        let state = classify([window(frontPID, CGRect(x: 0, y: 0, width: 864, height: 1117))])

        XCTAssertFalse(state.isFullScreen)
    }

    func testTransparentWindowIsNotFullscreen() {
        let state = classify([window(frontPID, CGRect(x: 0, y: 0, width: 1728, height: 1117), alpha: 0)])

        XCTAssertFalse(state.isFullScreen)
    }

    func testNonNormalLayerWindowIsNotFullscreen() {
        // Wallpaper, panels and overlays live on other layers.
        let state = classify([window(frontPID, CGRect(x: 0, y: 0, width: 1728, height: 1117), layer: -2_147_483_623)])

        XCTAssertFalse(state.isFullScreen)
    }

    // MARK: - Mixed sets

    func testWindowedFrontmostWindowIgnoresCoveringWindowBehindIt() {
        // This is the IINA/mpv false positive: a stale fullscreen surface is
        // behind the windowed window the user is actually looking at.
        let state = classify([
            window(frontPID, CGRect(x: 100, y: 100, width: 400, height: 300)),
            window(frontPID, CGRect(x: 0, y: 0, width: 1728, height: 1117)),
        ])

        XCTAssertFalse(state.isFullScreen)
    }

    func testToleranceAbsorbsRounding() {
        let state = classify([window(frontPID, CGRect(x: 0.5, y: -0.5, width: 1727, height: 1117.5))])

        XCTAssertTrue(state.isFullScreen)
    }

    func testWebKitFullscreenWithoutAccessibilityUsesWindowName() {
        XCTAssertEqual(
            FullscreenDetector.webKitContentFullscreen(
                windowName: "",
                toolbarHeight: nil,
                menuBarHeight: 33,
            ),
            true,
        )
        XCTAssertEqual(
            FullscreenDetector.webKitContentFullscreen(
                windowName: "Page title",
                toolbarHeight: nil,
                menuBarHeight: 33,
            ),
            false,
        )
        XCTAssertNil(
            FullscreenDetector.webKitContentFullscreen(
                windowName: nil,
                toolbarHeight: nil,
                menuBarHeight: 33,
            ),
        )
    }

    func testWebKitDestinationSpaceWithoutToolbarIsContent() {
        // During an FS↔FS hop Safari has already moved the picture into the
        // incoming Space but has not created the toolbar/strip window yet:
        // a covering window with no toolbar at all is the video surface.
        XCTAssertEqual(
            FullscreenDetector.webKitDestinationContentFullscreen(
                hasCoveringWindow: true,
                toolbarHeight: nil,
                menuBarHeight: 33,
            ),
            true,
        )
        // Safari's own window fullscreen always carries its toolbar by the
        // time the slide is visible, so it must stay "show".
        XCTAssertEqual(
            FullscreenDetector.webKitDestinationContentFullscreen(
                hasCoveringWindow: true,
                toolbarHeight: 52,
                menuBarHeight: 33,
            ),
            false,
        )
        XCTAssertEqual(
            FullscreenDetector.webKitDestinationContentFullscreen(
                hasCoveringWindow: true,
                toolbarHeight: 33,
                menuBarHeight: 33,
            ),
            true,
        )
        XCTAssertNil(
            FullscreenDetector.webKitDestinationContentFullscreen(
                hasCoveringWindow: false,
                toolbarHeight: nil,
                menuBarHeight: 33,
            ),
        )
    }

    func testWebKitFullscreenWithoutNameUsesToolbarHeight() {
        XCTAssertEqual(
            FullscreenDetector.webKitContentFullscreen(
                windowName: nil,
                toolbarHeight: 33,
                menuBarHeight: 33,
            ),
            true,
        )
        XCTAssertEqual(
            FullscreenDetector.webKitContentFullscreen(
                windowName: nil,
                toolbarHeight: 90,
                menuBarHeight: 33,
            ),
            false,
        )
    }
}
