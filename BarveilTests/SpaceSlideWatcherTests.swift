import XCTest
@testable import Barveil

final class SpaceSlideWatcherTests: XCTestCase {
    private let spaces: [(id: UInt64, type: Int)] = [
        (1, 0),      // desktop
        (1271, 4),   // fullscreen Space holding the playing video
        (415, 4),    // fullscreen Space of another app
        (1065, 4),
    ]

    func testNeighbourFollowsTheSlideDirection() {
        XCTAssertEqual(SpaceLookup.neighbour(of: 1271, direction: 1, in: spaces)?.id, 415)
        XCTAssertEqual(SpaceLookup.neighbour(of: 415, direction: -1, in: spaces)?.id, 1271)
    }

    func testNeighbourStopsAtTheEndsOfTheList() {
        XCTAssertNil(SpaceLookup.neighbour(of: 1, direction: -1, in: spaces))
        XCTAssertNil(SpaceLookup.neighbour(of: 1065, direction: 1, in: spaces))
        XCTAssertNil(SpaceLookup.neighbour(of: 999, direction: 1, in: spaces))
    }

    func testDesktopIsVisibleAsANonFullscreenNeighbour() {
        // Moving left from the first fullscreen Space lands on the desktop;
        // the caller skips anything whose type is not 4 because that arrival
        // is handled by Dock's desktop event.
        let desktop = SpaceLookup.neighbour(of: 1271, direction: -1, in: spaces)
        XCTAssertEqual(desktop?.id, 1)
        XCTAssertEqual(desktop?.type, 0)
    }
}
