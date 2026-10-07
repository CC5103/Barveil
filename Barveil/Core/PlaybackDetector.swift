// "Is the app in front playing something?"
//
// CoreAudio publishes a Process object per audio client. Reading
// `IsRunningOutput` on those objects tells us which processes are pushing
// audio right now, without a permission prompt, without AppleScript and
// without MediaRemote (which an unentitled, sandboxed app cannot use).
//
// A process is attributed to the front app when
//
//   * the bundle ID matches exactly, or
//   * the framework helper shares the app's bundle prefix
//     (`com.google.Chrome.helper` → `com.google.Chrome`), or
//   * it is one of the WebKit helpers Safari plays through, or
//   * its executable lives inside the app bundle.
//
// Muted playback is invisible to this detector, which is why the settings
// panel offers to treat unattributed audio as playback and why the panel
// always shows the raw signal it is looking at.
//
// CoreAudio is too slow for media players: after a video is paused the audio
// process often keeps `IsRunningOutput` set for around eight seconds, so the
// menu bar used to come back eight seconds after the user pressed pause.
//
// Many players publish a power assertion that flips with the playback state
// instead. WebKit holds `com.apple.WebCore: HTMLMediaElement playback`,
// Chromium holds `Playing audio`, and IINA/mpv holds
// `IINA playback is in progress`; all of them disappear when playback pauses.
// The assertion is therefore the fast path for every app that publishes one.
// A short absence is treated as a transition, not as a pause. Apps without a
// usable assertion (and any failed probe) fall through to MediaRemote and
// CoreAudio.
//
// WebKit is the exception: on macOS 26 Safari raises its runningboardd
// `WebKit Media Playback` assertion within ~20 ms of play, but keeps holding
// it for around five seconds after the media element pauses (measured
// 2026-09-29: pause released it 5.18 s late, while the system media session
// flipped in 13 ms). Answering a Safari pause from the assertion alone
// therefore restores the menu bar five seconds late. When a WebKit-hosted
// player's assertion still claims playback but a fresh media-session
// snapshot says paused, the session wins instead.

import AppKit
import CoreAudio
import IOKit.pwr_mgt

struct AudioProducer: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String?
    var executablePath: String?
}

struct PlaybackState: Equatable, Sendable {
    var isPlaying: Bool
    var producers: [AudioProducer]
    var detail: String
    /// True when the per-process API was unavailable and only the
    /// device-level "something is playing" signal could be read.
    var usedDeviceFallback: Bool
}

@MainActor
final class PlaybackDetector {
    /// Helpers that play media on behalf of a host app, keyed by helper
    /// bundle ID.
    private static let webkitHelpers: Set<String> = [
        "com.apple.WebKit.GPU",
        "com.apple.WebKit.WebContent",
        "com.apple.WebKit.Networking",
    ]

    /// Apps those helpers belong to.
    private static let webkitHosts: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    private let nowPlaying = NowPlayingProbe.shared

    func evaluate(app: FrontmostApp, includeUnattributed: Bool) -> PlaybackState {
        let reading = assertionReading(for: app)
        // Non-Chromium players answer through the power assertion, and the
        // MediaRemote round trip is comparatively expensive. Skip it when
        // the assertion already produced a verdict: the result is identical
        // (`preferredState` would just return the assertion) and the decision
        // lands several milliseconds earlier, which matters inside a
        // fullscreen Space hop.
        if !BrowserApps.isChromium(app.bundleID), let reading {
            if let paused = webKitPauseOverride(for: app, reading: reading) {
                return paused
            }
            return reading.state
        }
        let nowPlayingState = nowPlaying.playbackState(for: app)
        if let preferred = Self.preferredState(
            assertion: reading?.state,
            nowPlaying: nowPlayingState,
            mediaRemoteFirst: BrowserApps.isChromium(app.bundleID),
        ) {
            return preferred
        }
        return coreAudioState(app: app, includeUnattributed: includeUnattributed)
    }

    /// Chromium's media-session state (MediaRemote) flips ~1.3 s before the
    /// lingering `Playing audio` power assertion, so it wins whenever it is
    /// available. Other players (IINA/mpv, WebKit) keep the power assertion as
    /// the primary signal because MediaRemote can be unavailable or stale for
    /// them.
    nonisolated static func preferredState(
        assertion: PlaybackState?,
        nowPlaying: PlaybackState?,
        mediaRemoteFirst: Bool,
    ) -> PlaybackState? {
        if mediaRemoteFirst, let nowPlaying {
            return nowPlaying
        }
        return assertion ?? nowPlaying
    }

    private func coreAudioState(app: FrontmostApp, includeUnattributed: Bool) -> PlaybackState {
        guard let producers = outputProducers() else {
            let deviceIsRunning = defaultOutputDeviceIsRunning()
            return PlaybackState(
                isPlaying: deviceIsRunning && includeUnattributed,
                producers: [],
                detail: deviceIsRunning ? "device active (unattributed)" : "device silent",
                usedDeviceFallback: true,
            )
        }

        let owned = producers.filter { owns(producer: $0, app: app) }
        if !owned.isEmpty {
            let names = owned.compactMap(\.bundleID).joined(separator: ", ")
            return PlaybackState(
                isPlaying: true,
                producers: owned,
                detail: names.isEmpty ? "\(owned.count) output stream(s)" : names,
                usedDeviceFallback: false,
            )
        }

        if includeUnattributed, !producers.isEmpty {
            let names = producers.compactMap(\.bundleID).joined(separator: ", ")
            return PlaybackState(
                isPlaying: true,
                producers: producers,
                detail: names.isEmpty ? "unattributed audio" : "unattributed: \(names)",
                usedDeviceFallback: false,
            )
        }

        return PlaybackState(
            isPlaying: false,
            producers: producers,
            detail: producers.isEmpty ? "no output" : "other apps only",
            usedDeviceFallback: false,
        )
    }

    // MARK: - Power assertions

    /// Bundle IDs where the assertion probe has already produced a positive
    /// answer. Only those are allowed to answer "nothing is playing": a probe
    /// that cannot see an app's assertions (a sandbox that filters them, an
    /// app that does not publish any) must fall back to CoreAudio instead of
    /// claiming silence.
    private var assertionTrustedBundles: Set<String> = []

    /// A power-assertion reading plus the detail that decides whether the
    /// pause override applies: whether the verdict came from runningboardd's
    /// `WebKit Media Playback` assertion, which WebKit keeps for several
    /// seconds after a pause.
    private struct AssertionReading {
        var state: PlaybackState
        var usesWebKitAssertion: Bool
    }

    /// How long a paused media-session snapshot may outrank a lingering
    /// WebKit playback assertion. The measured release lag is ~5.2 s, but a
    /// second media element in the same browser (a background tab, a live
    /// stream) can keep the assertion alive indefinitely, so the window is
    /// deliberately generous; the adapter-liveness guard below is what
    /// bounds the damage if the session state goes stale.
    private static let webKitPauseTrustWindow: TimeInterval = 60

    /// Cheap provisional answer for the moment a fullscreen Space hop
    /// starts: only the power-assertion probe and an in-memory snapshot read
    /// run (no MediaRemote XPC call, no CoreAudio round trip), so it can
    /// answer inside the same frame and let the caller commit the preference
    /// before the Space animation ends.
    func fastPlayingVerdict(for app: FrontmostApp) -> Bool? {
        guard let reading = assertionReading(for: app) else { return nil }
        if let paused = webKitPauseOverride(for: app, reading: reading) {
            return paused.isPlaying
        }
        return reading.state.isPlaying
    }

    /// The pause override, applied only when the reading is a WebKit
    /// assertion that still claims playback.
    private func webKitPauseOverride(
        for app: FrontmostApp,
        reading: AssertionReading,
    ) -> PlaybackState? {
        guard reading.usesWebKitAssertion, reading.state.isPlaying else { return nil }
        guard nowPlaying.adapterIsRunning else { return nil }
        return Self.webKitPauseOverride(
            assertion: reading.state,
            usesWebKitAssertion: reading.usesWebKitAssertion,
            session: nowPlaying.recentAdapterState(
                for: app,
                maxAge: Self.webKitPauseTrustWindow,
            ),
        )
    }

    /// WebKit's playback assertion outlives the pause it belongs to, while
    /// the system media session flips within ~100 ms. When the assertion
    /// still claims playback but the session says the app is paused, the
    /// session wins — otherwise Safari's menu bar comes back about five
    /// seconds after the user pressed pause.
    nonisolated static func webKitPauseOverride(
        assertion: PlaybackState?,
        usesWebKitAssertion: Bool,
        session: PlaybackState?,
    ) -> PlaybackState? {
        guard usesWebKitAssertion,
              let assertion,
              assertion.isPlaying,
              let session,
              !session.isPlaying
        else { return nil }
        return session
    }

    private func assertionReading(for app: FrontmostApp) -> AssertionReading? {
        guard let byProcess = Self.assertionsByProcess() else { return nil }

        var playing = false
        var webKitPlaying = false
        for (pid, entries) in byProcess {
            let running = NSRunningApplication(processIdentifier: pid)
            let producer = AudioProducer(
                pid: pid,
                bundleID: running?.bundleIdentifier,
                executablePath: running?.executableURL?.path,
            )
            let ownsProcess = running != nil && owns(producer: producer, app: app)
            for entry in entries {
                guard let name = entry["AssertName"] as? String else { continue }
                guard Self.isMediaPlaybackAssertion(name) else { continue }
                if ownsProcess || Self.assertionClientMatches(name, app: app) {
                    playing = true
                    if Self.isWebKitMediaAssertion(name) {
                        webKitPlaying = true
                    }
                }
            }
        }

        if playing {
            if let bundle = app.bundleID {
                assertionTrustedBundles.insert(bundle)
            }
            return AssertionReading(
                state: PlaybackState(
                    isPlaying: true,
                    producers: [],
                    detail: "playback power assertion",
                    usedDeviceFallback: false,
                ),
                usesWebKitAssertion: webKitPlaying,
            )
        }

        guard let bundle = app.bundleID,
              assertionTrustedBundles.contains(bundle)
        else { return nil }

        // The stabilizer downstream ignores a one-sample gap; do not add a
        // second, slower debounce here. A real pause must restore the bar
        // promptly.
        return AssertionReading(
            state: PlaybackState(
                isPlaying: false,
                producers: [],
                detail: "no playback assertion",
                usedDeviceFallback: false,
            ),
            usesWebKitAssertion: Self.webkitHosts.contains(bundle),
        )
    }

    /// runningboardd raises WebKit's media assertions on behalf of the
    /// playing application and embeds that application in the assertion
    /// string, e.g.
    ///
    ///   `xpcservice<com.apple.WebKit.GPU([app<application.com.apple.Safari
    ///   .80311.80977(501)>:38029])(501)>…:WebKit Media Playback`
    ///
    /// `owns(producer:)` cannot attribute those entries (the owning process is
    /// runningboardd, not the helper), so the client named inside the string
    /// decides instead.
    nonisolated static func assertionClientMatches(_ name: String, app: FrontmostApp) -> Bool {
        guard let bundle = app.bundleID, !bundle.isEmpty else { return false }
        if name.contains("application.\(bundle).") { return true }
        guard let client = assertionClientBundleID(from: name) else { return false }
        if webkitHelpers.contains(client), webkitHosts.contains(bundle) { return true }
        return false
    }

    /// Extracts `com.apple.Safari` from a runningboardd assertion string.
    /// The bundle id is followed by two numeric build components and the uid.
    nonisolated static func assertionClientBundleID(from name: String) -> String? {
        guard let start = name.range(of: "application.") else { return nil }
        var parts: [Substring] = []
        for part in name[start.upperBound...].split(separator: ".", omittingEmptySubsequences: false) {
            let token = part.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard !token.isEmpty else { break }
            if token.allSatisfy({ $0.isNumber }) { break }
            parts.append(token)
        }
        let bundle = parts.joined(separator: ".")
        return bundle.isEmpty ? nil : bundle
    }

    /// True for runningboardd's WebKit media assertion, the one whose
    /// release lags a pause. Other WebKit/Chromium assertion names flip with
    /// the element and must not be answered from the media session instead.
    nonisolated static func isWebKitMediaAssertion(_ name: String) -> Bool {
        name.lowercased().contains("webkit media playback")
    }

    /// Assertion names that mean media is actively playing. Keep this list
    /// precise: `PreventUserIdleDisplaySleep` by itself is held by many apps
    /// that are not playing media.
    nonisolated static func isMediaPlaybackAssertion(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("htmlmediaelement playback")
            || lowered.contains("playing audio")
            || lowered.contains("playing video")
            // WebKit (Safari, and every WebKit host) publishes its playback
            // assertion through runningboardd on macOS 26+, with the playing
            // app named inside the assertion string.
            || lowered.contains("webkit media playback")
            || lowered.contains("playback is in progress")
    }

    private static func assertionsByProcess() -> [pid_t: [[String: Any]]]? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let raw = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return nil }

        var result: [pid_t: [[String: Any]]] = [:]
        for (key, value) in raw {
            result[pid_t(key.int32Value)] = value
        }
        return result
    }

    // MARK: - Attribution

    private func owns(producer: AudioProducer, app: FrontmostApp) -> Bool {
        if let bundle = producer.bundleID, !bundle.isEmpty {
            if let host = app.bundleID {
                if bundle == host { return true }
                if bundle.hasPrefix(host + ".") { return true }
                if Self.webkitHelpers.contains(bundle), Self.webkitHosts.contains(host) { return true }
            }
        }
        if let path = producer.executablePath,
           let bundlePath = app.bundleURL?.path,
           path.hasPrefix(bundlePath)
        {
            return true
        }
        return false
    }

    // MARK: - CoreAudio

    private func outputProducers() -> [AudioProducer]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size)
        else { return nil }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        var mutableSize = size
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &mutableSize, &objects) == noErr else {
            return nil
        }

        var producers: [AudioProducer] = []
        for object in objects {
            guard int32Property(object, kAudioProcessPropertyIsRunningOutput) == 1,
                  let pid = int32Property(object, kAudioProcessPropertyPID)
            else { continue }
            let running = NSRunningApplication(processIdentifier: pid_t(pid))
            producers.append(
                AudioProducer(
                    pid: pid_t(pid),
                    bundleID: stringProperty(object, kAudioProcessPropertyBundleID),
                    executablePath: running?.executableURL?.path,
                ),
            )
        }
        return producers
    }

    private func int32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var value = Int32(0)
        var size = UInt32(MemoryLayout<Int32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        let error = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return error == noErr ? value : nil
    }

    /// `kAudioProcessPropertyBundleID` is a CFString property — read it as
    /// one, not as a C string buffer.
    private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        let error = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard error == noErr, let value else { return nil }
        let text = value as String
        return text.isEmpty ? nil : text
    }

    private func defaultOutputDeviceIsRunning() -> Bool {
        var device = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &deviceAddress, 0, nil, &deviceSize, &device) == noErr else {
            return false
        }

        var running = UInt32(0)
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        guard AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &runningSize, &running) == noErr else {
            return false
        }
        return running == 1
    }
}
