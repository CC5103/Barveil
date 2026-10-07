// Screen math shared by the fullscreen detector.
//
// `CGWindowList` reports windows in CoreGraphics (top-left origin, global)
// coordinates while AppKit talks bottom-left, so every window rect is
// translated before it is compared with a screen.

import AppKit

struct DisplayLayout {
    let screen: NSScreen

    var geometry: DisplayGeometry {
        DisplayGeometry(
            frame: cgFrame,
            menuBarHeight: menuBarHeight,
            name: screen.localizedName,
        )
    }

    /// `screen.frame` translated into CoreGraphics coordinates.
    private var cgFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height,
        )
    }

    /// Height of the menu bar strip on this display, 0 on displays that
    /// never show one.
    var menuBarHeight: CGFloat {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// True when the display has a camera housing cut into the menu bar
    /// strip. Fullscreen windows on these displays always extend underneath
    /// the bar, which makes geometric detection exact.
    var hasNotch: Bool {
        guard screen.safeAreaInsets.top > 0 else { return false }
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        return !(left?.isEmpty ?? true) || !(right?.isEmpty ?? true)
    }

    var displayName: String {
        screen.localizedName
    }

    /// Every attached display, in CoreGraphics coordinates.
    static var allGeometries: [DisplayGeometry] {
        NSScreen.screens.map { DisplayLayout(screen: $0).geometry }
    }
}

/// The geometry of one display, in CoreGraphics (top-left origin) coordinates.
/// Plain data so the fullscreen classifier can be tested without a screen.
struct DisplayGeometry: Equatable, Sendable {
    var frame: CGRect
    /// Height of the menu bar strip; 0 on displays that never show one.
    var menuBarHeight: CGFloat
    var name: String

    /// Used when a secondary display reports no menu-bar height. A fullscreen
    /// window still reserves this strip until the system preference is
    /// flipped, so a window one menu bar short must not be rejected — that is
    /// exactly the video-fullscreen case on an external display.
    static let assumedMenuBarHeight: CGFloat = 33
}

/// One on-screen window, as `CGWindowListCopyWindowInfo` reports it.
/// `CGWindowList` with `.optionOnScreenOnly` only returns windows of the
/// *active* Space, which is what keeps fullscreen windows on other Spaces or
/// on other displays from leaking into the decision.
struct WindowSnapshot: Equatable, Sendable {
    var ownerPID: pid_t
    var layer: Int
    var alpha: Double
    var bounds: CGRect
    /// WindowServer window number, used by `SpaceLookup`.
    var windowNumber: CGWindowID = 0
    /// `kCGWindowName`. Safari's video-fullscreen window has an empty name,
    /// while its normal fullscreen window carries the page title.
    var name: String? = nil
    /// Whether `.optionOnScreenOnly` returned this window. Windows that are
    /// not listed may still be the fullscreen surface on the active Space;
    /// `SpaceLookup` verifies that before they are allowed to count.
    var isOnScreen: Bool = true
}
