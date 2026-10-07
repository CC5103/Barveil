// The browser case: a fullscreen *browser window* must stay out of Barveil's
// way, and only a fullscreen *picture* may hide the menu bar. Geometry cannot
// tell those apart, so the Accessibility tree decides — and these tests pin
// both that rule and its conservative fallback.

import XCTest
@testable import Barveil

final class BrowserFullscreenTests: XCTestCase {
    /// 14" MacBook Pro window, in the screen coordinates AX reports.
    private let window = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let toolbar = CGRect(x: 0, y: 0, width: 1728, height: 87)
    private let content = CGRect(x: 0, y: 87, width: 1728, height: 1030)
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

    private func covering(_ display: DisplayGeometry) -> CoveringWindow {
        CoveringWindow(bounds: display.frame, display: display)
    }

    // MARK: - The rule

    func testFullscreenBrowserWindowIsNotAPictureFullscreen() {
        let state = FullscreenDetector.browserState(
            covering: covering(builtIn),
            chromeVisible: true,
            accessibilityAvailable: true,
        )

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.scope, .window)
        XCTAssertEqual(state.source, .accessibility)
    }

    func testFullscreenPictureIsDetected() {
        let state = FullscreenDetector.browserState(
            covering: covering(builtIn),
            chromeVisible: false,
            accessibilityAvailable: true,
        )

        XCTAssertTrue(state.isFullScreen)
        XCTAssertEqual(state.scope, .content)
    }

    func testBrowserWithoutAccessibilityIsLeftAlone() {
        // Guessing "picture" here is what hid the bar for ordinary fullscreen
        // browser windows, so without Accessibility the answer is no.
        let state = FullscreenDetector.browserState(
            covering: covering(builtIn),
            chromeVisible: false,
            accessibilityAvailable: false,
        )

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.scope, .window)
        XCTAssertEqual(state.source, .geometry)
    }

    func testFallbackTreatsSafariVideoDialogAsContent() {
        XCTAssertFalse(FullscreenDetector.fallbackChromeVisible(
            browserBundleID: "com.apple.Safari",
            subrole: "AXDialog",
            axFullScreen: true,
        ))
        XCTAssertTrue(FullscreenDetector.fallbackChromeVisible(
            browserBundleID: "com.apple.Safari",
            subrole: "AXStandardWindow",
            axFullScreen: true,
        ))
    }

    func testFallbackTreatsChromiumFullscreenWindowAsContent() {
        XCTAssertFalse(FullscreenDetector.fallbackChromeVisible(
            browserBundleID: "com.google.Chrome",
            subrole: "AXStandardWindow",
            axFullScreen: true,
        ))
        XCTAssertTrue(FullscreenDetector.fallbackChromeVisible(
            browserBundleID: "com.google.Chrome",
            subrole: "AXStandardWindow",
            axFullScreen: false,
        ))
        XCTAssertTrue(FullscreenDetector.fallbackChromeVisible(
            browserBundleID: "com.google.Chrome",
            subrole: "AXStandardWindow",
            axFullScreen: nil,
        ))
    }

    func testFallbackStaysConservativeForUnknownBrowsers() {
        XCTAssertTrue(FullscreenDetector.fallbackChromeVisible(
            browserBundleID: "org.mozilla.firefox",
            subrole: "AXStandardWindow",
            axFullScreen: true,
        ))
    }

    // MARK: - Chrome during a transition

    func testSafariStandardWindowKeepsChromeWhileTheToolbarIsMissing() {
        // Mid-animation the toolbar can drop out of the AX tree for a sample
        // or two. Safari's browser window is still an AXStandardWindow then,
        // and that must not read as "the picture fills the screen".
        XCTAssertTrue(FullscreenDetector.resolvedChromeVisible(
            heuristic: false,
            browserBundleID: "com.apple.Safari",
            subrole: "AXStandardWindow",
            axFullScreen: true,
        ))
    }

    func testSafariVideoDialogIsContentEvenWhenTheHeuristicFindsChrome() {
        XCTAssertFalse(FullscreenDetector.resolvedChromeVisible(
            heuristic: true,
            browserBundleID: "com.apple.Safari",
            subrole: "AXDialog",
            axFullScreen: false,
        ))
    }

    func testSafariPlaceholderWindowKeepsChrome() {
        // WindowServer's fullscreen-animation placeholder covers the whole
        // display with an empty AX tree, which the heuristic alone reads as
        // "the picture fills the screen".
        XCTAssertTrue(FullscreenDetector.resolvedChromeVisible(
            heuristic: false,
            browserBundleID: "com.apple.Safari",
            subrole: "AXUnknown",
            axFullScreen: false,
        ))
        XCTAssertTrue(FullscreenDetector.resolvedChromeVisible(
            heuristic: false,
            browserBundleID: "com.apple.Safari",
            subrole: "AXSheet",
            axFullScreen: nil,
        ))
    }

    func testSafariWithoutSubroleFallsBackToTheHeuristic() {
        XCTAssertFalse(FullscreenDetector.resolvedChromeVisible(
            heuristic: false,
            browserBundleID: "com.apple.Safari",
            subrole: nil,
            axFullScreen: nil,
        ))
        XCTAssertTrue(FullscreenDetector.resolvedChromeVisible(
            heuristic: nil,
            browserBundleID: "com.apple.Safari",
            subrole: nil,
            axFullScreen: nil,
        ))
    }

    func testChromiumKeepsTheHeuristic() {
        // Chromium's fullscreen video is an AXFullScreen standard window, so
        // the subrole cannot decide this one.
        XCTAssertFalse(FullscreenDetector.resolvedChromeVisible(
            heuristic: false,
            browserBundleID: "com.google.Chrome",
            subrole: "AXStandardWindow",
            axFullScreen: true,
        ))
        XCTAssertTrue(FullscreenDetector.resolvedChromeVisible(
            heuristic: true,
            browserBundleID: "com.google.Chrome",
            subrole: "AXStandardWindow",
            axFullScreen: true,
        ))
    }

    func testUnknownBrowserWithNoHeuristicStaysConservative() {
        XCTAssertTrue(FullscreenDetector.resolvedChromeVisible(
            heuristic: nil,
            browserBundleID: "org.mozilla.firefox",
            subrole: "AXStandardWindow",
            axFullScreen: true,
        ))
    }

    func testWindowBrowserThatDoesNotFillTheScreenIsNotFullScreen() {
        let state = FullscreenDetector.browserState(
            covering: nil,
            chromeVisible: false,
            accessibilityAvailable: true,
        )

        XCTAssertFalse(state.isFullScreen)
        XCTAssertEqual(state.scope, .none)
    }

    // MARK: - Chrome detection

    func testToolbarAlongTheTopCountsAsWindowChrome() {
        let nodes = [
            AXNode(role: "AXGroup", frame: toolbar, children: [
                AXNode(role: "AXTextField", frame: CGRect(x: 200, y: 20, width: 900, height: 30)),
            ]),
            AXNode(role: "AXGroup", frame: content),
        ]

        XCTAssertTrue(FullscreenDetector.showsWindowChrome(in: nodes, windowFrame: window))
    }

    func testDeeplyNestedToolbarCountsAsWindowChrome() {
        // Chromium nests its toolbar several generic groups deep. The
        // classifier must still find the real toolbar instead of treating the
        // browser window as a fullscreen picture.
        let address = AXNode(
            role: "AXTextField",
            frame: CGRect(x: 200, y: 20, width: 900, height: 30),
        )
        let toolbar = AXNode(
            role: "AXToolbar",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 87),
            children: [address],
        )
        let level4 = AXNode(role: "AXGroup", frame: window, children: [toolbar])
        let level3 = AXNode(role: "AXGroup", frame: window, children: [level4])
        let level2 = AXNode(role: "AXGroup", frame: window, children: [level3])
        let level1 = AXNode(role: "AXGroup", frame: window, children: [level2])

        XCTAssertTrue(FullscreenDetector.showsWindowChrome(in: [level1], windowFrame: window))
    }

    func testOffscreenToolbarDoesNotCountAsWindowChrome() {
        // Chrome keeps the toolbar in the AX tree during HTML5 video
        // fullscreen, but moves it above the window. A frame outside the
        // window must never make the picture look like a browser window.
        let toolbar = AXNode(
            role: "AXToolbar",
            frame: CGRect(x: 0, y: -79, width: 1728, height: 46),
        )

        XCTAssertFalse(FullscreenDetector.showsWindowChrome(in: [toolbar], windowFrame: window))
    }

    func testTopInfoBarGroupAloneIsNotWindowChrome() {
        // Chromium's restore/default-browser infobars are AXGroups in the
        // top band. They are not browser chrome and must not stop video
        // fullscreen detection.
        let infoBar = AXNode(
            role: "AXGroup",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 56),
        )

        XCTAssertFalse(FullscreenDetector.showsWindowChrome(in: [infoBar], windowFrame: window))
    }

    func testFullWindowGroupAloneIsNotWindowChrome() {
        let group = AXNode(role: "AXGroup", frame: window)

        XCTAssertFalse(FullscreenDetector.showsWindowChrome(in: [group], windowFrame: window))
    }

    func testPictureCoveringTheWholeWindowIsNotChrome() {
        let nodes = [AXNode(role: "AXGroup", frame: window)]

        XCTAssertFalse(FullscreenDetector.showsWindowChrome(in: nodes, windowFrame: window))
    }

    func testSmallTopElementIsNotChrome() {
        let nodes = [
            AXNode(role: "AXButton", frame: CGRect(x: 12, y: 12, width: 24, height: 24)),
            AXNode(role: "AXGroup", frame: window),
        ]

        XCTAssertFalse(FullscreenDetector.showsWindowChrome(in: nodes, windowFrame: window))
    }

    func testChromeRoleNestedBelowTheTopEdgeCountsAsChrome() {
        // The page area starts under the window's top edge and the subtree
        // exposes a real address/search field. That is browser chrome even
        // though the top-level container is only an AXGroup.
        let address = AXNode(
            role: "AXTextField",
            frame: CGRect(x: 200, y: 100, width: 900, height: 30),
        )
        let nodes = [AXNode(role: "AXGroup", frame: content, children: [address])]

        XCTAssertTrue(FullscreenDetector.showsWindowChrome(in: nodes, windowFrame: window))
    }

    func testGenericContentStartingBelowTheTopEdgeIsNotChrome() {
        // A generic AXGroup starting below the top edge is not enough on its
        // own: Chromium's info bars are exactly this shape. Counting them as
        // chrome would leave the menu bar visible for a fullscreen video.
        let nodes = [AXNode(role: "AXGroup", frame: content)]

        XCTAssertFalse(FullscreenDetector.showsWindowChrome(in: nodes, windowFrame: window))
    }

    func testHiddenChromeIsIgnored() {
        let nodes = [
            AXNode(role: "AXGroup", frame: toolbar, hidden: true, children: [
                AXNode(role: "AXTextField", frame: CGRect(x: 200, y: 20, width: 900, height: 30)),
            ]),
            AXNode(role: "AXGroup", frame: window),
        ]

        XCTAssertFalse(FullscreenDetector.showsWindowChrome(in: nodes, windowFrame: window))
    }

    // MARK: - Which apps count as browsers

    func testBrowserBundleIDs() {
        for bundleID in [
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "com.vivaldi.Vivaldi",
        ] {
            XCTAssertTrue(BrowserApps.isBrowser(bundleID), "\(bundleID) should count as a browser")
        }

        for bundleID in [
            "com.colliderli.iina",
            "org.videolan.vlc",
            "com.apple.QuickTimePlayerX",
            "com.apple.finder",
            "com.openai.codex",
            "",
        ] {
            XCTAssertFalse(BrowserApps.isBrowser(bundleID), "\(bundleID) should not count as a browser")
        }
        XCTAssertFalse(BrowserApps.isBrowser(nil))
    }
}
