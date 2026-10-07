// After a fullscreen window starts leaving fullscreen, the window/space
// transition can still look "fullscreen" for a few samples. Without a guard
// the menu bar can briefly hide again right after showing. This small state
// machine turns that period into a one-way show window: once fullscreen has
// been observed and then stops, hide candidates are ignored for a short time.

import Foundation

struct FullscreenTransitionGuard {
    /// How long after leaving fullscreen a re-hide is ignored.
    let transitionWindow: TimeInterval
    /// How long a newly frontmost app must remain frontmost before it may
    /// hide the bar. This rejects the transient app changes produced while
    /// macOS animates a window or Space switch.
    let frontAppSettleWindow: TimeInterval

    private(set) var wasFullScreen = false
    private(set) var suppressHideUntil: Date?

    init(transitionWindow: TimeInterval = 1.0, frontAppSettleWindow: TimeInterval = 0.4) {
        self.transitionWindow = transitionWindow
        self.frontAppSettleWindow = frontAppSettleWindow
    }

    mutating func update(isFullScreen: Bool, frontAppChanged: Bool, at now: Date) {
        if frontAppChanged {
            wasFullScreen = isFullScreen
            suppressHideUntil = max(
                suppressHideUntil ?? .distantPast,
                now.addingTimeInterval(frontAppSettleWindow),
            )
            return
        }

        if wasFullScreen && !isFullScreen {
            suppressHideUntil = max(
                suppressHideUntil ?? .distantPast,
                now.addingTimeInterval(transitionWindow),
            )
        }
        wasFullScreen = isFullScreen
    }

    func shouldSuppressHide(at now: Date) -> Bool {
        guard let suppressHideUntil else { return false }
        return now < suppressHideUntil
    }

    mutating func reset() {
        wasFullScreen = false
        suppressHideUntil = nil
    }
}
