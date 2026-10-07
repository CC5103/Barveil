import XCTest
@testable import Barveil

final class MediaRemoteAdapterClientTests: XCTestCase {
    func testParsesPlayingPayload() {
        let line = """
        {"type":"data","diff":false,"payload":{"playing":true,"processIdentifier":27992,"bundleIdentifier":"com.google.Chrome"}}
        """
        let snapshot = MediaRemoteAdapterClient.parse(line)
        XCTAssertEqual(snapshot?.playing, true)
        XCTAssertEqual(snapshot?.pid, 27992)
        XCTAssertEqual(snapshot?.bundleID, "com.google.Chrome")
    }

    func testParsesPausedPayload() {
        let line = """
        {"type":"data","diff":false,"payload":{"playing":false,"processIdentifier":42,"bundleIdentifier":"com.apple.Safari","parentApplicationBundleIdentifier":"com.apple.Safari"}}
        """
        let snapshot = MediaRemoteAdapterClient.parse(line)
        XCTAssertEqual(snapshot?.playing, false)
        XCTAssertEqual(snapshot?.pid, 42)
        XCTAssertEqual(snapshot?.parentBundleID, "com.apple.Safari")
    }

    func testIgnoresEmptyInitialPayload() {
        let line = #"{"type":"data","diff":false,"payload":{}}"#
        XCTAssertNil(MediaRemoteAdapterClient.parse(line))
    }

    func testIgnoresNonDataLines() {
        XCTAssertNil(MediaRemoteAdapterClient.parse("not json"))
        XCTAssertNil(MediaRemoteAdapterClient.parse(#"{"type":"hello"}"#))
    }
}
