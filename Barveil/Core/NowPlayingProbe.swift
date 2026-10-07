// macOS publishes the active media session through MediaRemote. Unlike
// CoreAudio, this state flips when a player pauses, so it gives IINA, VLC and
// similar apps the same fast pause response that browsers already get from
// their power assertions.
//
// MediaRemote is private and therefore only appropriate for the direct-
// distribution build. The probe loads it dynamically and degrades to
// CoreAudio whenever the framework or its XPC service is unavailable.

import AppKit
import Darwin
import Foundation

struct NowPlayingSnapshot: Equatable, Sendable {
    var pid: pid_t
    var isPlaying: Bool
    var updatedAt: Date
    /// Bundle ID of the process that owns the media session. Matching this as
    /// well as the PID keeps multi-instance players (two IINA windows, a
    /// helper process, …) attributable to the app the user is looking at.
    var bundleID: String?

    init(pid: pid_t, isPlaying: Bool, updatedAt: Date, bundleID: String? = nil) {
        self.pid = pid
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
        self.bundleID = bundleID
    }
}

final class NowPlayingProbe: @unchecked Sendable {
    static let shared = NowPlayingProbe()

    private typealias IsPlayingFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private typealias PIDFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Int32) -> Void
    ) -> Void

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.barveil.now-playing", qos: .utility)
    private let adapter = MediaRemoteAdapterClient()
    private let handle: UnsafeMutableRawPointer?
    private let isPlayingFunction: IsPlayingFunction?
    private let pidFunction: PIDFunction?

    private var snapshot: NowPlayingSnapshot?
    private var adapterSnapshot: MediaRemoteAdapterSnapshot?
    private var inFlight = false
    private var lastRequestAt = Date.distantPast

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW | RTLD_LOCAL,
        )
        self.handle = handle
        isPlayingFunction = Self.loadFunction(
            handle: handle,
            name: "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
        )
        pidFunction = Self.loadFunction(
            handle: handle,
            name: "MRMediaRemoteGetNowPlayingApplicationPID",
        )

        adapter.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.lock.lock()
            self.adapterSnapshot = snapshot
            self.lock.unlock()
        }
        adapter.start()
    }

    deinit {
        adapter.stop()
        if let handle {
            dlclose(handle)
        }
    }

    func playbackState(for app: FrontmostApp, now: Date = Date()) -> PlaybackState? {
        lock.lock()
        let adapterSnapshot = adapterSnapshot
        lock.unlock()

        if let state = Self.playbackState(
            adapterSnapshot: adapterSnapshot,
            appPID: app.pid,
            appBundleID: app.bundleID,
            now: now,
        ) {
            return state
        }

        requestRefreshIfNeeded(at: now)

        lock.lock()
        let snapshot = snapshot
        lock.unlock()

        guard let snapshot else { return nil }
        return Self.playbackState(
            snapshot: snapshot,
            appPID: app.pid,
            appBundleID: app.bundleID,
            now: now,
        )
    }

    /// Whether the bundled MediaRemote adapter stream is alive. The WebKit
    /// pause override only trusts a paused session while a running adapter
    /// can report the next resume, so a dead adapter falls back to the power
    /// assertion instead of pinning the menu bar visible.
    var adapterIsRunning: Bool { adapter.isRunning }

    /// The adapter's most recent snapshot for the app, read with a wider age
    /// limit than the default freshness window. WebKit's playback assertion
    /// outlives a pause by several seconds while the session's paused verdict
    /// stays valid, so the pause override has to look slightly further back
    /// than a normal sample would.
    func recentAdapterState(
        for app: FrontmostApp,
        maxAge: TimeInterval,
        now: Date = Date(),
    ) -> PlaybackState? {
        lock.lock()
        let adapterSnapshot = adapterSnapshot
        lock.unlock()

        return Self.playbackState(
            adapterSnapshot: adapterSnapshot,
            appPID: app.pid,
            appBundleID: app.bundleID,
            now: now,
            freshness: maxAge,
        )
    }

    nonisolated static func playbackState(
        adapterSnapshot: MediaRemoteAdapterSnapshot?,
        appPID: pid_t,
        appBundleID: String?,
        now: Date,
        freshness: TimeInterval = 3,
    ) -> PlaybackState? {
        guard let adapterSnapshot,
              now.timeIntervalSince(adapterSnapshot.updatedAt) <= freshness
        else { return nil }

        let pidMatches = adapterSnapshot.pid == appPID
        let bundleMatches: Bool = {
            guard let appBundleID else { return false }
            let candidates = [adapterSnapshot.bundleID, adapterSnapshot.parentBundleID]
            return candidates.compactMap { $0 }.contains { bundle in
                bundle == appBundleID
                    || bundle.hasPrefix(appBundleID + ".")
                    || appBundleID.hasPrefix(bundle + ".")
            }
        }()
        guard pidMatches || bundleMatches else { return nil }

        return PlaybackState(
            isPlaying: adapterSnapshot.playing,
            producers: [],
            detail: adapterSnapshot.playing ? "system media playing" : "system media paused",
            usedDeviceFallback: false,
        )
    }

    nonisolated static func playbackState(
        snapshot: NowPlayingSnapshot,
        appPID: pid_t,
        appBundleID: String? = nil,
        now: Date,
        freshness: TimeInterval = 2,
    ) -> PlaybackState? {
        let pidMatches = snapshot.pid == appPID
        let bundleMatches: Bool = {
            guard let appBundleID, let snapshotBundleID = snapshot.bundleID,
                  !appBundleID.isEmpty, !snapshotBundleID.isEmpty
            else { return false }
            return snapshotBundleID == appBundleID
                || snapshotBundleID.hasPrefix(appBundleID + ".")
                || appBundleID.hasPrefix(snapshotBundleID + ".")
        }()
        guard (pidMatches || bundleMatches),
              now.timeIntervalSince(snapshot.updatedAt) <= freshness
        else { return nil }

        return PlaybackState(
            isPlaying: snapshot.isPlaying,
            producers: [],
            detail: snapshot.isPlaying ? "system media playing" : "system media paused",
            usedDeviceFallback: false,
        )
    }

    private func requestRefreshIfNeeded(at now: Date) {
        guard isPlayingFunction != nil, pidFunction != nil else { return }

        lock.lock()
        guard !inFlight, now.timeIntervalSince(lastRequestAt) >= 0.10 else {
            lock.unlock()
            return
        }
        inFlight = true
        lastRequestAt = now
        lock.unlock()

        queue.async { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let isPlayingFunction, let pidFunction else {
            lock.lock()
            inFlight = false
            lock.unlock()
            return
        }

        let resultLock = NSLock()
        var playing: Bool?
        var pid: Int32?
        let group = DispatchGroup()

        group.enter()
        isPlayingFunction(.global(qos: .utility)) { value in
            resultLock.lock()
            playing = value
            resultLock.unlock()
            group.leave()
        }

        group.enter()
        pidFunction(.global(qos: .utility)) { value in
            resultLock.lock()
            pid = value
            resultLock.unlock()
            group.leave()
        }

        let completed = group.wait(timeout: .now() + 0.75) == .success
        resultLock.lock()
        let result = completed ? (playing, pid) : nil
        resultLock.unlock()

        lock.lock()
        if let result, let isPlaying = result.0, let rawPID = result.1, rawPID > 0 {
            let resolvedPID = pid_t(rawPID)
            snapshot = NowPlayingSnapshot(
                pid: resolvedPID,
                isPlaying: isPlaying,
                updatedAt: Date(),
                bundleID: NSRunningApplication(processIdentifier: resolvedPID)?.bundleIdentifier,
            )
        }
        inFlight = false
        lock.unlock()
    }

    private static func loadFunction<T>(handle: UnsafeMutableRawPointer?, name: String) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
