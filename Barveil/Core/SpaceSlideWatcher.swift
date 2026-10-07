// Watches the per-Space menu bar windows while a native fullscreen Space is
// active.
//
// Switching Spaces slides every menu bar window horizontally for roughly a
// second before the active Space changes: the incoming Space's bar enters
// from one side, the outgoing bar leaves through the other. WindowServer
// exposes those positions through the (cheap) window list, which makes the
// *direction* of the switch readable long before AppKit or the Accessibility
// focus flips — and with the ordered Space list that is enough to name the
// destination Space.
//
// That lead time is what lets Barveil write the arriving Space's menu-bar
// preference *before* the system re-renders it, which is the difference
// between a clean hand-off and the visible "three beats".

import CoreGraphics
import Foundation

@MainActor
final class SpaceSlideWatcher {
    enum Sample: Equatable {
        /// One bar is parked at the centre: no slide in progress.
        case settled(windowID: Int)
        /// `windowID` is sliding toward the centre; `direction` is +1 when
        /// the incoming Space comes from the right, -1 from the left.
        case incoming(windowID: Int, direction: Int)
        /// Windows are moving but the destination is not clear yet.
        case busy
    }

    /// Fired once per slide, as soon as the incoming bar can be identified.
    var onIncoming: ((Int, Int) -> Void)?
    /// Fired when the incoming bar has parked at the centre.
    var onSettled: ((Int) -> Void)?

    /// True between `onIncoming` and the incoming bar parking again.
    private(set) var isSliding = false
    /// The bar that was parked before the slide started: the outgoing one.
    private(set) var parkedWindowID: Int?
    /// The menu bar window of the Space that is active right now, resolved by
    /// the caller from that Space's window list. Several Spaces' bars can sit
    /// at the centre at once, so this is what disambiguates them.
    var expectedParkedWindowID: Int?

    /// 20 Hz while a fullscreen Space is active: the incoming bar is far from
    /// the centre for most of the animation, so one frame is enough to spot
    /// it, and the poll itself is a sub-millisecond window query.
    private let interval: TimeInterval = 0.05
    /// A slide lasts about a second; this only guards against a broken window
    /// list leaving the decision held forever.
    private let slideTimeout: TimeInterval = 2.5

    private var timer: Timer?
    private var incomingWindowID: Int?
    private var slideStartedAt: Date?
    private var lastReportedParked: Int?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        incomingWindowID = nil
        slideStartedAt = nil
        isSliding = false
        parkedWindowID = nil
        lastReportedParked = nil
    }

    private func poll() {
        let windows = Self.menuBarWindows()
        let displayWidth = Self.mainDisplayWidth()

        // 1. A slide is in flight: wait for the incoming bar to park.
        if let incoming = incomingWindowID {
            guard let window = windows.first(where: { $0.id == incoming }) else {
                finishSlide()
                return
            }
            if abs(window.x) < 4 {
                parkedWindowID = window.id
                finishSlide()
                onSettled?(window.id)
                return
            }
            if let started = slideStartedAt, Date().timeIntervalSince(started) > slideTimeout {
                finishSlide()
            }
            return
        }

        // 2. The Space's own menu bar window is parked: nothing is moving.
        //    Several Spaces' bars can sit at the centre at once, so the
        //    caller-provided window is authoritative.
        if let expected = expectedParkedWindowID,
           let window = windows.first(where: { $0.id == expected }),
           abs(window.x) < 4
        {
            parkedWindowID = expected
            if lastReportedParked != expected {
                lastReportedParked = expected
                onSettled?(expected)
            }
            return
        }

        // 3. The parked window is moving (or expected to exist): the incoming
        //    bar is the one moving toward the centre within one screen width.
        //    Everything further out belongs to Spaces that are not part of
        //    this switch.
        guard let outgoing = expectedParkedWindowID ?? parkedWindowID else { return }
        let reach = displayWidth * 1.25
        let candidate = windows
            .filter { $0.id != outgoing && abs($0.x) >= 8 && abs($0.x) <= reach }
            .min { abs($0.x) < abs($1.x) }
        guard let incoming = candidate else { return }

        incomingWindowID = incoming.id
        slideStartedAt = Date()
        isSliding = true
        onIncoming?(incoming.id, incoming.x > 0 ? 1 : -1)
    }

    private func finishSlide() {
        incomingWindowID = nil
        slideStartedAt = nil
        isSliding = false
    }

    nonisolated static func mainDisplayWidth() -> CGFloat {
        CGDisplayBounds(CGMainDisplayID()).width
    }

    /// The layer-24 menu bar windows of every Space, with their current
    /// horizontal offset (`0` = parked at the centre).
    ///
    /// `.optionOnScreenOnly` only reports the bar that is parked right now —
    /// the incoming bar that is still sliding in from the outside is missing
    /// from that list. `.optionAll` does include it, and WindowServer keeps
    /// `kCGWindowIsOnscreen` accurate for the sliding bars, so the two are
    /// combined here.
    nonisolated static func menuBarWindows() -> [(id: Int, x: CGFloat)] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var result: [(id: Int, x: CGFloat)] = []
        for window in list {
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? "?"
            guard owner == "Window Server" || owner == "MenuBarAgent" else { continue }
            guard (window[kCGWindowLayer as String] as? Int ?? 0) == 24 else { continue }
            guard (window[kCGWindowIsOnscreen as String] as? Bool) == true else { continue }
            let number = window[kCGWindowNumber as String] as? Int ?? -1
            guard number > 0 else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            result.append((number, bounds["X"] ?? 0))
        }
        return result
    }
}
