// WebKit and Chromium browsers are read through their power assertion rather
// than CoreAudio, because the audio process object keeps reporting "running"
// for around eight seconds after a web video is paused. These tests pin the
// names that count.

import XCTest
@testable import Barveil

final class PlaybackSignalTests: XCTestCase {
    func testWebKitMediaAssertionIsRecognised() {
        XCTAssertTrue(FullscreenDetector.isWebKitBrowser("com.apple.Safari"))
        XCTAssertTrue(FullscreenDetector.isWebKitBrowser("com.apple.SafariTechnologyPreview"))
        XCTAssertFalse(FullscreenDetector.isWebKitBrowser("com.google.Chrome"))
    }

    func testMediaPlaybackAssertionNames() {
        XCTAssertTrue(PlaybackDetector.isMediaPlaybackAssertion("com.apple.WebCore: HTMLMediaElement playback"))
        XCTAssertTrue(PlaybackDetector.isMediaPlaybackAssertion("Playing audio"))
        XCTAssertTrue(PlaybackDetector.isMediaPlaybackAssertion("playing video"))
        XCTAssertTrue(PlaybackDetector.isMediaPlaybackAssertion("IINA playback is in progress"))
        // macOS 26 raises WebKit's assertion through runningboardd; the name
        // is what matters, the owner process is handled separately.
        XCTAssertTrue(PlaybackDetector.isMediaPlaybackAssertion(
            "xpcservice<com.apple.WebKit.GPU([app<application.com.apple.Safari.80311.80977(501)>:38029])(501)>{}:38045402-38029-48406:WebKit Media Playback",
        ))
    }

    func testRunningBoardAssertionClientAttribution() {
        let safari = FrontmostApp(pid: 38029, bundleID: "com.apple.Safari", name: "Safari", bundleURL: nil)
        let chrome = FrontmostApp(pid: 37967, bundleID: "com.google.Chrome", name: "Google Chrome", bundleURL: nil)
        let gpu = "xpcservice<com.apple.WebKit.GPU([app<application.com.apple.Safari.80311.80977(501)>:38029])(501)>{}:38045402-38029-48406:WebKit Media Playback"
        let appLevel = "app<application.com.apple.Safari.80311.80977(501)>402-38029-48405:WebKit Media Playback"

        XCTAssertEqual(PlaybackDetector.assertionClientBundleID(from: gpu), "com.apple.Safari")
        XCTAssertEqual(PlaybackDetector.assertionClientBundleID(from: appLevel), "com.apple.Safari")
        XCTAssertTrue(PlaybackDetector.assertionClientMatches(gpu, app: safari))
        XCTAssertTrue(PlaybackDetector.assertionClientMatches(appLevel, app: safari))
        XCTAssertFalse(PlaybackDetector.assertionClientMatches(gpu, app: chrome))
        XCTAssertNil(PlaybackDetector.assertionClientBundleID(from: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"))
    }

    func testChromeFamilyUsesFastMediaPlaybackAssertion() {
        for bundleID in [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "org.chromium.Chromium",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "com.vivaldi.Vivaldi",
        ] {
            XCTAssertTrue(
                BrowserApps.usesMediaPlaybackAssertion(bundleID),
                "\(bundleID) should use its media playback assertion",
            )
        }
    }

    func testBrowsersWithoutKnownPlaybackAssertionStayOnCoreAudio() {
        XCTAssertFalse(BrowserApps.usesMediaPlaybackAssertion("org.mozilla.firefox"))
        XCTAssertFalse(BrowserApps.usesMediaPlaybackAssertion(nil))
    }

    func testWebKitMediaAssertionIsDistinguished() {
        XCTAssertTrue(PlaybackDetector.isWebKitMediaAssertion(
            "xpcservice<com.apple.WebKit.GPU([app<application.com.apple.Safari.80311.80977(501)>:38029])(501)>{}:38045402-38029-48406:WebKit Media Playback",
        ))
        XCTAssertFalse(PlaybackDetector.isWebKitMediaAssertion("IINA playback is in progress"))
        XCTAssertFalse(PlaybackDetector.isWebKitMediaAssertion("Playing audio"))
    }

    func testUnrelatedAssertionsAreIgnored() {
        XCTAssertFalse(PlaybackDetector.isMediaPlaybackAssertion("com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"))
        XCTAssertFalse(PlaybackDetector.isMediaPlaybackAssertion("App Nap"))
    }
}

final class PlaybackPriorityTests: XCTestCase {
    private func state(_ playing: Bool, _ detail: String) -> PlaybackState {
        PlaybackState(isPlaying: playing, producers: [], detail: detail, usedDeviceFallback: false)
    }

    func testChromiumPrefersFreshMediaRemotePauseOverLingeringAssertion() {
        let preferred = PlaybackDetector.preferredState(
            assertion: state(true, "playback power assertion"),
            nowPlaying: state(false, "system media paused"),
            mediaRemoteFirst: true,
        )
        XCTAssertEqual(preferred?.isPlaying, false)
        XCTAssertEqual(preferred?.detail, "system media paused")
    }

    func testNonChromiumKeepsPowerAssertionPrimary() {
        let preferred = PlaybackDetector.preferredState(
            assertion: state(true, "playback power assertion"),
            nowPlaying: state(false, "system media paused"),
            mediaRemoteFirst: false,
        )
        XCTAssertEqual(preferred?.isPlaying, true)
        XCTAssertEqual(preferred?.detail, "playback power assertion")
    }

    func testWebKitPauseOverrideBeatsLingeringAssertion() {
        // Safari keeps its WebKit assertion for ~5 s after a pause while the
        // media session flips within ~100 ms; pausing must not wait for the
        // assertion to expire.
        let override = PlaybackDetector.webKitPauseOverride(
            assertion: state(true, "playback power assertion"),
            usesWebKitAssertion: true,
            session: state(false, "system media paused"),
        )
        XCTAssertEqual(override?.isPlaying, false)
        XCTAssertEqual(override?.detail, "system media paused")
    }

    func testPauseOverrideLeavesOtherAssertionPlayersAlone() {
        XCTAssertNil(PlaybackDetector.webKitPauseOverride(
            assertion: state(true, "playback power assertion"),
            usesWebKitAssertion: false,
            session: state(false, "system media paused"),
        ))
    }

    func testPauseOverrideNeedsPausedSessionAndLingeringAssertion() {
        XCTAssertNil(PlaybackDetector.webKitPauseOverride(
            assertion: state(true, "playback power assertion"),
            usesWebKitAssertion: true,
            session: state(true, "system media playing"),
        ))
        XCTAssertNil(PlaybackDetector.webKitPauseOverride(
            assertion: state(true, "playback power assertion"),
            usesWebKitAssertion: true,
            session: nil,
        ))
        XCTAssertNil(PlaybackDetector.webKitPauseOverride(
            assertion: state(false, "no playback assertion"),
            usesWebKitAssertion: true,
            session: state(false, "system media paused"),
        ))
        XCTAssertNil(PlaybackDetector.webKitPauseOverride(
            assertion: nil,
            usesWebKitAssertion: true,
            session: state(false, "system media paused"),
        ))
    }

    func testFallsBackWhenNeitherSignalExists() {
        XCTAssertNil(PlaybackDetector.preferredState(
            assertion: nil,
            nowPlaying: nil,
            mediaRemoteFirst: true,
        ))
    }
}
