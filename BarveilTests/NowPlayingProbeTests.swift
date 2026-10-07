import XCTest
@testable import Barveil

final class NowPlayingProbeTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 3_000)

    func testMatchingPIDUsesFastPauseState() {
        let state = NowPlayingProbe.playbackState(
            snapshot: NowPlayingSnapshot(pid: 42, isPlaying: false, updatedAt: t0),
            appPID: 42,
            now: t0.addingTimeInterval(0.1),
        )

        XCTAssertEqual(state?.isPlaying, false)
        XCTAssertEqual(state?.detail, "system media paused")
    }

    func testMatchingPIDReportsPlaying() {
        let state = NowPlayingProbe.playbackState(
            snapshot: NowPlayingSnapshot(pid: 42, isPlaying: true, updatedAt: t0),
            appPID: 42,
            now: t0.addingTimeInterval(0.1),
        )

        XCTAssertEqual(state?.isPlaying, true)
        XCTAssertEqual(state?.detail, "system media playing")
    }

    func testDifferentAppFallsBackToCoreAudio() {
        let state = NowPlayingProbe.playbackState(
            snapshot: NowPlayingSnapshot(pid: 42, isPlaying: false, updatedAt: t0),
            appPID: 99,
            now: t0.addingTimeInterval(0.1),
        )

        XCTAssertNil(state)
    }

    func testAdapterSnapshotMatchesByPID() {
        let state = NowPlayingProbe.playbackState(
            adapterSnapshot: MediaRemoteAdapterSnapshot(
                playing: false,
                pid: 42,
                bundleID: "com.google.Chrome",
                parentBundleID: nil,
                updatedAt: t0,
            ),
            appPID: 42,
            appBundleID: "com.google.Chrome",
            now: t0.addingTimeInterval(0.2),
        )

        XCTAssertEqual(state?.isPlaying, false)
        XCTAssertEqual(state?.detail, "system media paused")
    }

    func testAdapterSnapshotMatchesByBundle() {
        let state = NowPlayingProbe.playbackState(
            adapterSnapshot: MediaRemoteAdapterSnapshot(
                playing: true,
                pid: 99,
                bundleID: "com.google.Chrome.helper",
                parentBundleID: "com.google.Chrome",
                updatedAt: t0,
            ),
            appPID: 42,
            appBundleID: "com.google.Chrome",
            now: t0.addingTimeInterval(0.2),
        )

        XCTAssertEqual(state?.isPlaying, true)
    }

    func testAdapterSnapshotMatchesWebKitHostWithinWidenedFreshness() {
        let snapshot = MediaRemoteAdapterSnapshot(
            playing: false,
            pid: 38045,
            bundleID: "com.apple.WebKit.GPU",
            parentBundleID: "com.apple.Safari",
            updatedAt: t0,
        )

        let state = NowPlayingProbe.playbackState(
            adapterSnapshot: snapshot,
            appPID: 38029,
            appBundleID: "com.apple.Safari",
            now: t0.addingTimeInterval(10),
            freshness: 12,
        )
        XCTAssertEqual(state?.isPlaying, false)
        XCTAssertEqual(state?.detail, "system media paused")

        // The default window still rejects the same snapshot.
        XCTAssertNil(NowPlayingProbe.playbackState(
            adapterSnapshot: snapshot,
            appPID: 38029,
            appBundleID: "com.apple.Safari",
            now: t0.addingTimeInterval(10),
        ))
    }

    func testStaleAdapterSnapshotFallsBack() {
        let state = NowPlayingProbe.playbackState(
            adapterSnapshot: MediaRemoteAdapterSnapshot(
                playing: true,
                pid: 42,
                bundleID: "com.google.Chrome",
                parentBundleID: nil,
                updatedAt: t0,
            ),
            appPID: 42,
            appBundleID: "com.google.Chrome",
            now: t0.addingTimeInterval(5),
        )

        XCTAssertNil(state)
    }

    func testStaleSnapshotFallsBackToCoreAudio() {
        let state = NowPlayingProbe.playbackState(
            snapshot: NowPlayingSnapshot(pid: 42, isPlaying: false, updatedAt: t0),
            appPID: 42,
            now: t0.addingTimeInterval(3),
        )

        XCTAssertNil(state)
    }

    func testDifferentInstanceOfTheSameAppIsAttributedByBundleID() {
        let state = NowPlayingProbe.playbackState(
            snapshot: NowPlayingSnapshot(
                pid: 42,
                isPlaying: true,
                updatedAt: t0,
                bundleID: "com.colliderli.iina",
            ),
            appPID: 99,
            appBundleID: "com.colliderli.iina",
            now: t0.addingTimeInterval(0.1),
        )

        XCTAssertEqual(state?.isPlaying, true)
        XCTAssertEqual(state?.detail, "system media playing")
    }

    func testUnrelatedBundleStillFallsBackToCoreAudio() {
        let state = NowPlayingProbe.playbackState(
            snapshot: NowPlayingSnapshot(
                pid: 42,
                isPlaying: true,
                updatedAt: t0,
                bundleID: "com.apple.Music",
            ),
            appPID: 99,
            appBundleID: "com.colliderli.iina",
            now: t0.addingTimeInterval(0.1),
        )

        XCTAssertNil(state)
    }
}
