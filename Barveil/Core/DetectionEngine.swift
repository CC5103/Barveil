// Polls the two signals Barveil needs and hands them to `AppModel` as one
// snapshot. Polling (4×/second, both probes are cheap syscalls) keeps this
// simple and immune to missed notifications; front-app switches additionally
// trigger an immediate sample so the decision never lags a click.

import AppKit
import Foundation

@MainActor
final class DetectionEngine {
    struct Sample: Equatable, Sendable {
        var frontApp: FrontmostApp?
        var fullscreen: FullscreenState
        var playback: PlaybackState
    }

    var onSample: ((Sample) -> Void)?

    /// Fired the instant the Accessibility fast path sees a new front app,
    /// before the full sample runs. The Space-hop handler uses it to write
    /// the destination's menu-bar preference before the animation ends.
    var onFastFrontAppChange: ((FrontmostApp) -> Void)?

    private let frontmost = FrontmostAppMonitor()
    private let fullscreen = FullscreenDetector()
    private let playback = PlaybackDetector()
    private unowned let preferences: Preferences
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start(interval: TimeInterval = 0.10) {
        guard timer == nil else { return }

        frontmost.onFastChange = { [weak self] app in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.onFastFrontAppChange?(app)
            }
        }

        frontmost.onChange = { [weak self] in
            guard let self else { return }
            // The monitor already runs on the main actor; forwarding the
            // change synchronously keeps the correction inside the same
            // frame instead of one task hop later.
            MainActor.assumeIsolated {
                self.sample()
            }
        }
        frontmost.start()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Plugging a display in or out changes which windows fill a screen, so
        // take a sample right away instead of waiting for the next tick.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sample()
            }
        }

        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        frontmost.onChange = nil
        frontmost.stop()
    }

    /// Full evaluation for an app that is not frontmost yet: the Space slide
    /// identifies the destination a second before it arrives, and this is how
    /// its decision is computed without waiting for the switch to finish.
    func destinationState(
        for app: FrontmostApp,
        destinationSpaceID: UInt64?,
    ) -> (fullscreen: FullscreenState, playback: PlaybackState) {
        let fullscreenState = fullscreen.evaluate(
            app: app,
            useAccessibility: preferences.useAccessibility,
            additionalSpaceID: destinationSpaceID,
        )
        let playbackState = playback.evaluate(app: app, includeUnattributed: preferences.includeUnattributedPlayback)
        return (fullscreenState, playbackState)
    }

    /// Power-assertion-only playback verdict: cheap enough to run inside the
    /// same frame as the front-app change. `nil` means "cannot tell".
    func fastPlayingVerdict(for app: FrontmostApp) -> Bool? {
        playback.fastPlayingVerdict(for: app)
    }

    func sample() {
        let app = frontmost.current ?? frontmost.refresh(notify: false)

        let fullscreenState = app.map {
            fullscreen.evaluate(
                app: $0,
                useAccessibility: preferences.useAccessibility,
            )
        } ?? FullscreenState(isFullScreen: false, source: .unavailable, detail: "no front app")

        let playbackState = app.map {
            playback.evaluate(app: $0, includeUnattributed: preferences.includeUnattributedPlayback)
        } ?? PlaybackState(isPlaying: false, producers: [], detail: "no front app", usedDeviceFallback: false)

        onSample?(
            Sample(frontApp: app, fullscreen: fullscreenState, playback: playbackState),
        )
    }
}
