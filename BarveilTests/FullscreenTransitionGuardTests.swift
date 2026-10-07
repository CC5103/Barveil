import XCTest
@testable import Barveil

final class FullscreenTransitionGuardTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000)

    func testLeavingFullscreenSuppressesRehide() {
        var guardState = FullscreenTransitionGuard(transitionWindow: 1.0)
        guardState.update(isFullScreen: true, frontAppChanged: false, at: t0)
        guardState.update(isFullScreen: false, frontAppChanged: false, at: t0.addingTimeInterval(0.5))

        XCTAssertTrue(guardState.shouldSuppressHide(at: t0.addingTimeInterval(0.6)))
        XCTAssertTrue(guardState.shouldSuppressHide(at: t0.addingTimeInterval(1.4)))
        XCTAssertFalse(guardState.shouldSuppressHide(at: t0.addingTimeInterval(1.6)))
    }

    func testFrontAppChangeSuppressesImmediateRehide() {
        var guardState = FullscreenTransitionGuard(
            transitionWindow: 1.0,
            frontAppSettleWindow: 0.4,
        )
        guardState.update(isFullScreen: true, frontAppChanged: false, at: t0)
        guardState.update(isFullScreen: true, frontAppChanged: true, at: t0.addingTimeInterval(0.1))

        XCTAssertTrue(guardState.shouldSuppressHide(at: t0.addingTimeInterval(0.2)))
        XCTAssertTrue(guardState.shouldSuppressHide(at: t0.addingTimeInterval(0.49)))
        XCTAssertFalse(guardState.shouldSuppressHide(at: t0.addingTimeInterval(0.51)))
    }

    func testFrontAppChangeDoesNotShortenExistingTransitionGuard() {
        var guardState = FullscreenTransitionGuard(
            transitionWindow: 1.0,
            frontAppSettleWindow: 0.4,
        )
        guardState.update(isFullScreen: true, frontAppChanged: false, at: t0)
        guardState.update(isFullScreen: false, frontAppChanged: false, at: t0.addingTimeInterval(0.1))
        guardState.update(isFullScreen: true, frontAppChanged: true, at: t0.addingTimeInterval(0.3))

        XCTAssertTrue(guardState.shouldSuppressHide(at: t0.addingTimeInterval(1.0)))
        XCTAssertFalse(guardState.shouldSuppressHide(at: t0.addingTimeInterval(1.2)))
    }

    func testEnteringFullscreenDoesNotSuppressHide() {
        var guardState = FullscreenTransitionGuard(transitionWindow: 1.0)
        guardState.update(isFullScreen: false, frontAppChanged: false, at: t0)
        guardState.update(isFullScreen: true, frontAppChanged: false, at: t0.addingTimeInterval(0.2))

        XCTAssertFalse(guardState.shouldSuppressHide(at: t0.addingTimeInterval(0.3)))
    }
}
