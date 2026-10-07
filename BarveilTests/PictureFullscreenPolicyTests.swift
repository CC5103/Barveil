import XCTest
@testable import Barveil

final class PictureFullscreenPolicyTests: XCTestCase {
    private let content = FullscreenState(
        isFullScreen: true,
        scope: .content,
        source: .accessibility,
        detail: "picture",
    )
    private let window = FullscreenState(
        isFullScreen: false,
        scope: .window,
        source: .accessibility,
        detail: "browser chrome visible",
    )
    private let covering = FullscreenState(
        isFullScreen: true,
        scope: .content,
        source: .geometry,
        detail: "covering window",
    )
    private let small = FullscreenState(
        isFullScreen: false,
        scope: .none,
        source: .geometry,
        detail: "windowed",
    )

    func testBrowserPictureFullscreenHides() {
        let result = PictureFullscreenPolicy.resolve(
            raw: content,
            dockIsFullScreen: true,
            frontOwnsDock: true,
            isBrowser: true,
            isPlaying: true,
        )
        XCTAssertTrue(result.isFullScreen)
        XCTAssertEqual(result.scope, .content)
    }

    func testBrowserWindowFullscreenDoesNotHide() {
        let result = PictureFullscreenPolicy.resolve(
            raw: window,
            dockIsFullScreen: true,
            frontOwnsDock: true,
            isBrowser: true,
            isPlaying: true,
        )
        XCTAssertFalse(result.isFullScreen)
        XCTAssertEqual(result.scope, .window)
    }

    func testIINACoveringFullscreenHides() {
        let result = PictureFullscreenPolicy.resolve(
            raw: covering,
            dockIsFullScreen: true,
            frontOwnsDock: true,
            isBrowser: false,
            isPlaying: true,
        )
        XCTAssertTrue(result.isFullScreen)
    }

    func testWindowedPlayerDoesNotHideEvenInFullscreenSpace() {
        let result = PictureFullscreenPolicy.resolve(
            raw: small,
            dockIsFullScreen: true,
            frontOwnsDock: true,
            isBrowser: false,
            isPlaying: true,
        )
        XCTAssertFalse(result.isFullScreen)
    }

    func testDifferentOwnerDoesNotHide() {
        let result = PictureFullscreenPolicy.resolve(
            raw: content,
            dockIsFullScreen: true,
            frontOwnsDock: false,
            isBrowser: true,
            isPlaying: true,
        )
        XCTAssertFalse(result.isFullScreen)
    }

    func testLegacyBorderlessFullscreenRequiresPlayback() {
        let playing = PictureFullscreenPolicy.resolve(
            raw: covering,
            dockIsFullScreen: false,
            frontOwnsDock: false,
            isBrowser: false,
            isPlaying: true,
        )
        XCTAssertTrue(playing.isFullScreen)

        let paused = PictureFullscreenPolicy.resolve(
            raw: covering,
            dockIsFullScreen: false,
            frontOwnsDock: false,
            isBrowser: false,
            isPlaying: false,
        )
        XCTAssertFalse(paused.isFullScreen)
    }
}
