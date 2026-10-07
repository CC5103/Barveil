import XCTest
@testable import Barveil

final class DockSpaceMonitorTests: XCTestCase {
    func testParsesFullscreenEntryWithOwnerAndTitle() {
        let line = """
        Dock[653:16e7] [com.apple.dock:dock-visibility] Space Forces Hidden: 1 <DockCore.FullscreenSpace: 0x7497493dc0> {uuid=ABC fullscreen=true space=CGSSpace(spid: 252)} {tiles=[<TileSpace: 0x0000007497c0c0c0> {orig-uuid= pid=26203 appName=Google Chrome name=YouTube space=CGSSpace(spid: 254)}
        """

        let event = DockSpaceMonitor.parse(line)
        XCTAssertEqual(event, .fullScreen(DockFullScreenState(
            isFullScreen: true,
            ownerPID: 26203,
            title: "YouTube",
            spaceID: 252,
        )))
    }

    func testParsesFullscreenExitWithoutOwner() {
        let line = """
        Dock[653:16e7] [com.apple.dock:dock-visibility] Space Forces Hidden: 0 <ManagedSpace: 0x749949be10> {uuid= fullscreen=false space=CGSSpace(spid: 1)}
        """

        let event = DockSpaceMonitor.parse(line)
        XCTAssertEqual(event, .fullScreen(DockFullScreenState(
            isFullScreen: false,
            ownerPID: nil,
            title: nil,
            spaceID: 1,
        )))
    }

    func testParsesStaySpaceChange() {
        let line = "Dock[653:16e7] [com.apple.dock:dock-visibility] Skipping no-op state update"
        XCTAssertEqual(DockSpaceMonitor.parse(line), .staySpaceChange)
    }

    func testParsesDesktopArrival() {
        let line = "Dock[653:16e7] [com.apple.dock:dock-visibility] Will Force Update Rect"
        XCTAssertEqual(DockSpaceMonitor.parse(line), .desktopArrival)
    }

    func testIgnoresUnrelatedDockLines() {
        XCTAssertNil(DockSpaceMonitor.parse("Dock[653:16e7] [com.apple.dock:other] something else"))
    }
}
