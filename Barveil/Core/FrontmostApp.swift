// Tracks the app the user is actually looking at.
//
// While the Barveil panel or settings window is open Barveil itself becomes
// the frontmost app, which would otherwise make every gate flip. Those
// activations are ignored, and the last real app is kept.
//
// Space switches need a faster answer than AppKit gives. NSWorkspace only
// updates `frontmostApplication` (and posts its activation notification) once
// the fullscreen Space animation has fully handed the app over — measured at
// 200 ms to 1.2 s after the incoming Space is already on screen. The
// system-wide Accessibility "focused application" flips at the arrival
// instead, so when Accessibility is granted a light poll watches it and
// forwards the change immediately. Everything else keeps using AppKit.

import AppKit
import ApplicationServices

struct FrontmostApp: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String?
    var name: String
    var bundleURL: URL?

    var displayName: String { name }
}

@MainActor
final class FrontmostAppMonitor {
    private(set) var current: FrontmostApp?

    /// Called on the main queue whenever the front app changes to a
    /// different (non-Barveil) app.
    var onChange: (() -> Void)?

    /// Called the moment the Accessibility fast path notices the change,
    /// before the (comparatively slow) detection sample runs. Space-hop
    /// handling uses this to write the destination's menu-bar preference
    /// while the Space animation is still running.
    var onFastChange: ((FrontmostApp) -> Void)?

    private let ownBundleID: String?
    private var observer: NSObjectProtocol?
    private var fastTimer: Timer?

    /// 16 ms puts the corrected decision a frame or two ahead of the
    /// incoming Space's arrival. The Accessibility query itself costs about
    /// a microsecond, so this is cheap enough to run continuously.
    private let fastInterval: TimeInterval

    init(
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        fastInterval: TimeInterval = 0.016,
    ) {
        self.ownBundleID = ownBundleID
        self.fastInterval = fastInterval
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            _ = MainActor.assumeIsolated {
                self?.refresh(notify: true)
            }
        }
        startFastPath()
        refresh(notify: false)
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        fastTimer?.invalidate()
        fastTimer = nil
    }

    private func startFastPath() {
        guard fastTimer == nil else { return }
        let timer = Timer(timeInterval: fastInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.pollFocusedApplication()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fastTimer = timer
    }

    private func pollFocusedApplication() {
        guard AccessibilityPermission.isTrusted else { return }
        guard let pid = Self.focusedApplicationPID(), pid > 0 else { return }
        guard pid != current?.pid else { return }
        guard let running = NSRunningApplication(processIdentifier: pid) else { return }
        adopt(running, notify: true)
    }

    /// The system-wide focused application, which flips at the arrival of a
    /// fullscreen Space switch instead of once AppKit finishes the hand-off.
    nonisolated static func focusedApplicationPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &value,
        ) == .success, let value else { return nil }
        var pid: pid_t = -1
        AXUIElementGetPid(unsafeBitCast(value, to: AXUIElement.self), &pid)
        return pid > 0 ? pid : nil
    }

    @discardableResult
    func refresh(notify: Bool) -> FrontmostApp? {
        guard let running = NSWorkspace.shared.frontmostApplication else { return current }
        return adopt(running, notify: notify)
    }

    @discardableResult
    private func adopt(_ running: NSRunningApplication, notify: Bool) -> FrontmostApp? {
        let isSelf = running.bundleIdentifier != nil && running.bundleIdentifier == ownBundleID
        guard !isSelf, running.processIdentifier > 0 else { return current }

        let app = FrontmostApp(
            pid: running.processIdentifier,
            bundleID: running.bundleIdentifier,
            name: running.localizedName ?? running.bundleIdentifier ?? "Unknown",
            bundleURL: running.bundleURL,
        )
        guard app != current || current == nil else { return current }
        current = app
        if notify {
            // Order matters: the cheap provisional commit must run before the
            // full detection sample (which costs tens of milliseconds), so
            // the destination's menu-bar preference is already correct when
            // the Space animation ends.
            onFastChange?(app)
            onChange?()
        }
        return app
    }
}
