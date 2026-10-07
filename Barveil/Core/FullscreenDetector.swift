// "Is the app in front showing a fullscreen *picture*?"
//
// The question matters because the menu bar must go away for a video that
// fills the screen, but not for a browser window that happens to be
// fullscreen with its tabs and address field still on screen.
//
// Three sources, in order of precision:
//
//   1. Browsers — a fullscreen browser window and a fullscreen picture inside
//      it are the same thing to the window list, so this path asks the
//      Accessibility tree whether the window still draws its own chrome along
//      the top edge. Chrome off ⇒ the picture is what fills the screen.
//   2. Accessibility — `AXFullScreen` on the focused window for everything
//      else. Exact, but the user has to grant Accessibility, so it is
//      optional.
//   3. Window geometry — a normal-layer, on-screen window of the front app
//      that spans a whole display and either starts above the menu bar strip
//      or reaches the bottom edge of the display. Needs no permission at all.
//
// Geometry alone cannot separate "native fullscreen on a display without a
// notch and with the menu bar showing" from "maximised window" — both stop
// just below the menu bar and above the Dock. That is exactly the case where
// the Accessibility path pays for itself, and the settings panel says so.
//
// Without Accessibility a browser window that covers the display is reported
// as *not* fullscreen, because guessing "picture" there is exactly what hid
// the bar for ordinary fullscreen browser windows.

import AppKit
import ApplicationServices

/// One node of an Accessibility subtree. Flattened into a value type so the
/// "is the window still showing its own chrome?" question is a pure function
/// that unit tests can drive with synthetic trees.
struct AXNode: Equatable, Sendable {
    var role: String
    var frame: CGRect
    var hidden: Bool = false
    var children: [AXNode] = []
}

/// A window of the front app that fills a display — and the display it fills.
/// With more than one screen in play, everything downstream has to agree on
/// *which* of these it is talking about.
struct CoveringWindow: Equatable, Sendable {
    var bounds: CGRect
    var display: DisplayGeometry
}

struct FullscreenState: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case accessibility
        case geometry
        case dock
        case unavailable
    }

    /// What is actually filling the display.
    enum Scope: String, Equatable, Sendable {
        /// The picture itself: video fullscreen in a browser, a borderless
        /// player, a player app's native fullscreen.
        case content
        /// The window fills the display but the app still draws its own
        /// chrome — a browser window in fullscreen, tabs and all.
        case window
        /// Nothing fills the display.
        case none
    }

    var isFullScreen: Bool
    var scope: Scope = .none
    var source: Source
    /// Human-readable breadcrumb for the diagnostics list.
    var detail: String
    /// Display whose frontmost window supplied the decision.
    var displayName: String? = nil
}

@MainActor
final class FullscreenDetector {
    func evaluate(
        app: FrontmostApp,
        useAccessibility: Bool,
        additionalSpaceID: UInt64? = nil,
    ) -> FullscreenState {
        guard let rawWindows = windowSnapshots() else {
            return FullscreenState(isFullScreen: false, source: .unavailable, detail: "window list unavailable")
        }

        // `.optionAll` also returns windows on other Spaces. Keep the normal
        // on-screen windows and the off-screen windows that WindowServer says
        // are on the active Space. That second group is what carries IINA/mpv
        // style fullscreen surfaces, which never appear in the on-screen list.
        let windows = rawWindows.filter { window in
            if window.isOnScreen { return true }
            guard window.ownerPID == app.pid else { return false }
            if SpaceLookup.shared.isWindowOnActiveSpace(window.windowNumber) == true {
                return true
            }
            if let additionalSpaceID,
               let spaces = SpaceLookup.shared.spaceIDs(forWindow: window.windowNumber)
            {
                return spaces.contains(additionalSpaceID)
            }
            return false
        }
        let displays = DisplayLayout.allGeometries

        if BrowserApps.isBrowser(app.bundleID) {
            let relevantSpaceID = additionalSpaceID ?? SpaceLookup.shared.activeSpaceID()
            let browserWindows: [WindowSnapshot]
            if let relevantSpaceID {
                let scoped = windows.filter { window in
                    SpaceLookup.shared.spaceIDs(forWindow: window.windowNumber)?
                        .contains(relevantSpaceID) == true
                }
                if scoped.isEmpty, additionalSpaceID != nil {
                    // Destination-Space evaluation while a Space hop is in
                    // flight: the incoming Space has no browser window yet.
                    // The outgoing Space's windows must not answer for it —
                    // its toolbar otherwise makes the arriving picture look
                    // like a window with chrome. Keep only windows whose
                    // Space membership is unknown.
                    browserWindows = windows.filter { window in
                        let spaces = SpaceLookup.shared.spaceIDs(forWindow: window.windowNumber)
                        return spaces?.isEmpty ?? true
                    }
                } else {
                    browserWindows = scoped.isEmpty ? windows : scoped
                }
            } else {
                browserWindows = windows
            }
            return browserState(
                for: app,
                windows: browserWindows,
                displays: displays,
                useAccessibility: useAccessibility,
                isDestination: additionalSpaceID != nil,
            )
        }

        let geometry = Self.classify(
            windows: windows,
            displays: displays,
            appPID: app.pid,
            pointer: pointerLocationCG(),
        )
        if useAccessibility, AccessibilityPermission.isTrusted,
           let state = accessibilityState(for: app, windows: windows, displays: displays)
        {
            // Some players report a small helper/control window as their
            // focused AX window while the picture lives in a covering window
            // the window list does not expose. When geometry found that
            // covering window on the active Space, trust it over the helper's
            // AXFullScreen=false.
            if state.isFullScreen || !geometry.isFullScreen {
                return state
            }
        }
        return geometry
    }

    // MARK: - Browsers

    private func browserState(
        for app: FrontmostApp,
        windows: [WindowSnapshot],
        displays: [DisplayGeometry],
        useAccessibility: Bool,
        isDestination: Bool = false,
    ) -> FullscreenState {
        let available = useAccessibility && AccessibilityPermission.isTrusted
        let application = available ? AXUIElementCreateApplication(app.pid) : nil

        let covering = Self.coveringWindows(
            windows: windows,
            displays: displays,
            appPID: app.pid,
        )
        let pointer = pointerLocationCG()
        let rawFocusedFrame = application
            .flatMap { focusedWindow(of: $0) }
            .flatMap { rect(of: $0) }

        // `CGWindowList` can be restricted inside App Sandbox and may not
        // return another app's window at all. The focused AX window is the
        // active window of the front app; if its own frame covers a display,
        // use it as the geometry anchor. A windowed focused window will not
        // pass `coversDisplay`, so normal playback still stays visible.
        let axCovering: CoveringWindow? = rawFocusedFrame.flatMap { frame in
            guard let display = displays.first(where: {
                Self.coversDisplay(frame, display: $0)
            }) else { return nil }
            return CoveringWindow(bounds: frame, display: display)
        }
        let effectiveCovering = covering.isEmpty
            ? (axCovering.map { [$0] } ?? [])
            : covering

        // When the normal window list is available, keep the active-display
        // guard that rejects a stale AX window on another Space/display. When
        // it is empty, the focused AX window is the only usable anchor.
        let focusedFrame: CGRect? = covering.isEmpty
            ? rawFocusedFrame
            : rawFocusedFrame.flatMap { frame in
                Self.isAccessibilityWindowOnActiveDisplay(
                    frame: frame,
                    windows: windows,
                    displays: displays,
                    appPID: app.pid,
                    pointer: pointer,
                ) ? frame : nil
            }
        guard let target = Self.preferredCovering(
            covering: effectiveCovering,
            windows: windows,
            displays: displays,
            appPID: app.pid,
            focusedFrame: focusedFrame,
            pointer: pointer,
        ) else {
            var state = Self.browserState(
                covering: nil,
                chromeVisible: false,
                accessibilityAvailable: available,
            )
            state.displayName = Self.activeDisplay(
                windows: windows,
                displays: displays,
                appPID: app.pid,
                focusedFrame: focusedFrame,
                pointer: pointer,
            )?.name
            return state
        }

        // Without Accessibility, Safari still gives us a reliable WindowServer
        // signal: its video-fullscreen surface has an empty window name, while
        // the normal fullscreen browser window carries the page title. If a
        // title is present but media is still playing, keep the bar hidden too;
        // that is the state reached when the user swipes back to Safari's own
        // fullscreen Space while the video continues in the page.
        if !available, BrowserApps.isWebKit(app.bundleID) {
            let coveringSnapshot = windows.first { window in
                window.ownerPID == app.pid
                    && window.layer == 0
                    && window.alpha > 0.01
                    && window.bounds.isNearly(target.bounds, tolerance: 8)
            }
            let toolbarHeight = windows
                .filter { window in
                    window.ownerPID == app.pid
                        && window.layer == 0
                        && window.alpha > 0.01
                        && window.bounds.width >= target.bounds.width - 8
                        && window.bounds.height > 1
                        && window.bounds.height < target.bounds.height - 8
                }
                .map(\.bounds.height)
                .max()
            if let content = Self.webKitContentFullscreen(
                windowName: coveringSnapshot?.name,
                toolbarHeight: toolbarHeight,
                menuBarHeight: target.display.menuBarHeight,
            ) {
                return FullscreenState(
                    isFullScreen: content,
                    scope: content ? .content : .window,
                    source: .geometry,
                    detail: content
                        ? "WebKit fullscreen surface without Accessibility (content)"
                        : "WebKit fullscreen window without Accessibility (chrome)",
                    displayName: target.display.name,
                )
            }
            // Destination-Space evaluation during an FS↔FS hop. WindowServer
            // has already moved the picture into the incoming Space, but
            // Safari creates its toolbar (or the 33 px reserved strip) only
            // after the animation starts. At this instant the covering
            // window is the picture itself; treating the missing toolbar as
            // "chrome state unknown" made the arriving video Space render
            // with the menu bar and corrected it a beat later.
            if isDestination,
               Self.webKitDestinationContentFullscreen(
                   hasCoveringWindow: coveringSnapshot != nil,
                   toolbarHeight: toolbarHeight,
                   menuBarHeight: target.display.menuBarHeight,
               ) == true
            {
                return FullscreenState(
                    isFullScreen: true,
                    scope: .content,
                    source: .geometry,
                    detail: "WebKit fullscreen surface without Accessibility (destination content)",
                    displayName: target.display.name,
                )
            }
        }

        // The chrome question has to be answered for the same window the
        // geometry matched: with two displays in play the app's focused window
        // can easily be a different one. Among windows that match the frame,
        // the app's own focused window answers for the state the user is
        // looking at — during a fullscreen/Space animation a background window
        // of the same app can share the frame and briefly lose its chrome.
        // If the frame match or the deeper AX tree is unavailable, fall back to
        // the focused AX window and to the top-level subrole / AXFullScreen
        // attributes that are still readable.
        let focused = application.flatMap { focusedWindow(of: $0) }
        let window = matchingWindow(in: application, frame: target.bounds, preferring: focused)
            ?? focused
        if available, let window, let windowFrame = rect(of: window) {
            let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
            let axFullScreen = booleanAttribute(window, "AXFullScreen")
            let heuristic = chromeVisible(in: window, windowFrame: windowFrame)
            let chrome = Self.resolvedChromeVisible(
                heuristic: heuristic,
                browserBundleID: app.bundleID,
                subrole: subrole,
                axFullScreen: axFullScreen,
            )
            return Self.browserState(
                covering: target,
                chromeVisible: chrome,
                accessibilityAvailable: true,
            )
        }

        return Self.browserState(
            covering: target,
            chromeVisible: false,
            accessibilityAvailable: false,
        )
    }

    /// Non-AX WebKit classification from WindowServer:
    /// - an empty window name is Safari's video-fullscreen surface;
    /// - with no readable name, an empty reserved strip (about 33 px) means
    ///   Safari is not drawing its own toolbar, so the picture is fullscreen;
    /// - a real browser toolbar means the Safari window itself is fullscreen
    ///   and the menu bar must be shown again.
    /// `nil` means neither signal is available, so the caller keeps the
    /// existing conservative behavior instead of guessing.
    /// Destination-Space variant of the same question. During a Space hop
    /// Safari has not created its toolbar/strip window yet, so the toolbar
    /// height is nil even though the incoming Space is a picture. Safari
    /// window fullscreen always carries its toolbar window by that point, so
    /// a covering window with no toolbar at all is the video surface.
    nonisolated static func webKitDestinationContentFullscreen(
        hasCoveringWindow: Bool,
        toolbarHeight: CGFloat?,
        menuBarHeight: CGFloat,
    ) -> Bool? {
        guard hasCoveringWindow else { return nil }
        guard let toolbarHeight else { return true }
        let reservedStrip = max(menuBarHeight, DisplayGeometry.assumedMenuBarHeight)
        return toolbarHeight <= reservedStrip + 2
    }

    nonisolated static func webKitContentFullscreen(
        windowName: String?,
        toolbarHeight: CGFloat?,
        menuBarHeight: CGFloat,
    ) -> Bool? {
        if let windowName {
            return windowName.isEmpty
        }
        guard let toolbarHeight else { return nil }
        let reservedStrip = max(menuBarHeight, DisplayGeometry.assumedMenuBarHeight)
        return toolbarHeight <= reservedStrip + 2
    }

    /// When the deeper AX tree cannot be read, use the attributes that are
    /// still reliably available:
    ///
    /// * Safari's video-fullscreen window is an `AXDialog`; Safari's browser
    ///   window in native fullscreen is an `AXStandardWindow`.
    /// * Chromium's video fullscreen is an `AXStandardWindow` with
    ///   `AXFullScreen = true`; a normal/maximised Chromium window is not
    ///   `AXFullScreen`. Chromium's browser-window fullscreen keeps its
    ///   toolbar in a separate window, so its main window normally does not
    ///   satisfy the geometry rule at all.
    ///
    /// Unknown browsers stay conservative: report chrome, so the menu bar is
    /// not hidden for a window that might just be a browser window fullscreen.
    nonisolated static func fallbackChromeVisible(
        browserBundleID: String?,
        subrole: String?,
        axFullScreen: Bool?,
    ) -> Bool {
        if subrole == "AXDialog" { return false }

        guard let browserBundleID, !browserBundleID.isEmpty else { return true }
        let chromiumPrefixes = [
            "com.google.Chrome",
            "org.chromium",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "com.operasoftware.Opera",
            "com.vivaldi.Vivaldi",
            "company.thebrowser.Browser",
            "io.github.ungoogled_software.ungoogled_chromium",
        ]
        if chromiumPrefixes.contains(where: { browserBundleID.hasPrefix($0) }) {
            return axFullScreen != true
        }
        return true
    }

    /// Browsers whose fullscreen *picture* is its own dialog window rather
    /// than a fullscreen standard window.
    nonisolated static func isWebKitBrowser(_ bundleID: String?) -> Bool {
        BrowserApps.isWebKit(bundleID)
    }

    /// Decides "is this window still drawing its own chrome?" from both the
    /// tree heuristic and the window's own subrole.
    ///
    /// The heuristic is a snapshot, and a snapshot taken mid-flight lies:
    /// while a window is animating into or out of fullscreen, while a Space
    /// changes, or while a back/forward swipe is running, the toolbar can be
    /// missing from the AX tree for a sample or two. Reading that as "the
    /// picture fills the screen" is what made the menu bar disappear for a
    /// moment during those transitions.
    ///
    /// WebKit browsers answer the same question with a property that does not
    /// flicker: Safari's fullscreen video is its own `AXDialog`, while every
    /// other window it owns — a browser window in native fullscreen, a sheet,
    /// or the placeholder window WindowServer puts up while a window animates
    /// into or out of fullscreen — is not. So for those browsers the subrole
    /// decides: only a dialog means the picture fills the screen.
    ///
    /// The placeholder matters: it is the size of the whole display but has an
    /// empty AX tree, and an empty tree reads as "no chrome" from the
    /// heuristic alone. Matching it during a fullscreen animation is what hid
    /// the menu bar for a moment while the user was only entering or leaving
    /// fullscreen.
    ///
    /// Chromium cannot use the subrole (its fullscreen video *is* an
    /// `AXFullScreen` standard window), so it keeps the heuristic and its
    /// attribute fallback.
    nonisolated static func resolvedChromeVisible(
        heuristic: Bool?,
        browserBundleID: String?,
        subrole: String?,
        axFullScreen: Bool?,
    ) -> Bool {
        if isWebKitBrowser(browserBundleID), let subrole {
            return subrole != "AXDialog"
        }

        return heuristic ?? fallbackChromeVisible(
            browserBundleID: browserBundleID,
            subrole: subrole,
            axFullScreen: axFullScreen,
        )
    }

    /// Pure combination of the three facts the browser path has, pinned by
    /// `BrowserFullscreenTests`.
    nonisolated static func browserState(
        covering: CoveringWindow?,
        chromeVisible: Bool,
        accessibilityAvailable: Bool,
    ) -> FullscreenState {
        guard let covering else {
            return FullscreenState(
                isFullScreen: false,
                scope: .none,
                source: .geometry,
                detail: "browser window does not cover a display",
                displayName: nil,
            )
        }

        guard accessibilityAvailable else {
            // A browser window that fills the screen must not hide the menu
            // bar. Without Accessibility there is no way to tell it apart from
            // a fullscreen picture, so leave the bar alone.
            return FullscreenState(
                isFullScreen: false,
                scope: .window,
                source: .geometry,
                detail: "browser window covers \(covering.display.name) — Accessibility needed to tell the picture apart",
                displayName: covering.display.name,
            )
        }

        return FullscreenState(
            isFullScreen: !chromeVisible,
            scope: chromeVisible ? .window : .content,
            source: .accessibility,
            detail: chromeVisible
                ? "browser window fullscreen on \(covering.display.name) (window chrome visible)"
                : "browser picture fullscreen on \(covering.display.name) (no window chrome)",
            displayName: covering.display.name,
        )
    }

    // MARK: - Which display is the one being looked at

    /// Every window of `appPID` that fills a display, largest first so the
    /// answer does not depend on the order `CGWindowList` happens to use.
    nonisolated static func coveringWindows(
        windows: [WindowSnapshot],
        displays: [DisplayGeometry],
        appPID: pid_t,
        tolerance: CGFloat = 2,
    ) -> [CoveringWindow] {
        var found: [CoveringWindow] = []
        for window in windows {
            guard window.ownerPID == appPID, window.layer == 0, window.alpha > 0.01 else { continue }
            guard let display = bestDisplay(for: window.bounds, in: displays),
                  coversDisplay(window.bounds, display: display, tolerance: tolerance)
            else { continue }
            found.append(CoveringWindow(bounds: window.bounds, display: display))
        }
        return found.sorted {
            let left = area($0.bounds)
            let right = area($1.bounds)
            if left != right { return left > right }
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            return $0.bounds.minY < $1.bounds.minY
        }
    }

    /// The covering window on the display the pointer is on. Kept for the
    /// low-level tests; the live path uses `preferredCovering`, which knows
    /// about the frontmost app's own window order as well.
    nonisolated static func best(
        covering: [CoveringWindow],
        near point: CGPoint?,
    ) -> CoveringWindow? {
        if let point, let hit = covering.first(where: { $0.display.frame.contains(point) }) {
            return hit
        }
        return covering.first
    }

    /// Picks a covering window on the display that owns the app's active
    /// window. The active display is resolved in this order:
    ///
    /// 1. the Accessibility focused window (exact, when permission is given),
    /// 2. the first normal on-screen window for the app (CGWindowList is
    ///    ordered front-to-back, so this is the key window in practice),
    /// 3. the display containing the pointer.
    ///
    /// A covering window on a different display is deliberately ignored.
    /// Otherwise a fullscreen video on one screen would hide the bar while the
    /// user is working in a windowed window of the same app on another screen.
    nonisolated static func preferredCovering(
        covering: [CoveringWindow],
        windows: [WindowSnapshot],
        displays: [DisplayGeometry],
        appPID: pid_t,
        focusedFrame: CGRect? = nil,
        pointer: CGPoint? = nil,
    ) -> CoveringWindow? {
        guard !covering.isEmpty else { return nil }

        if let display = activeDisplay(
            windows: windows,
            displays: displays,
            appPID: appPID,
            focusedFrame: focusedFrame,
            pointer: pointer,
        ) {
            return covering.first { $0.display.frame.isNearly(display.frame) }
        }

        // With no usable anchor, only an unambiguous single answer is safe.
        return covering.count == 1 ? covering.first : nil
    }

    /// The display that owns the front app's active window.
    nonisolated static func activeDisplay(
        windows: [WindowSnapshot],
        displays: [DisplayGeometry],
        appPID: pid_t,
        focusedFrame: CGRect? = nil,
        pointer: CGPoint? = nil,
    ) -> DisplayGeometry? {
        if let focusedFrame,
           let display = bestDisplay(for: focusedFrame, in: displays)
        {
            return display
        }

        // The pointer is a useful tie-breaker only when the app actually has
        // a window on that display. Then this is the screen the user is
        // working on, even if another app-owned window is frontmost in the
        // global window list.
        if let pointer,
           let pointerDisplay = displays.first(where: { $0.frame.contains(pointer) }),
           windows.contains(where: {
               $0.ownerPID == appPID
                   && $0.layer == 0
                   && $0.alpha > 0.01
                   && bestDisplay(for: $0.bounds, in: displays)?.frame.isNearly(pointerDisplay.frame) == true
           })
        {
            return pointerDisplay
        }

        if let frontWindow = frontmostWindow(windows: windows, appPID: appPID),
           let display = bestDisplay(for: frontWindow.bounds, in: displays)
        {
            return display
        }

        if let pointer,
           let display = displays.first(where: { $0.frame.contains(pointer) })
        {
            return display
        }

        return nil
    }

    /// CGWindowListCopyWindowInfo returns windows in front-to-back order.
    /// The first normal window for the app is therefore its key window; it is
    /// a much better "which screen am I on?" anchor than an arbitrary covering
    /// window on another display.
    nonisolated static func frontmostWindow(
        windows: [WindowSnapshot],
        appPID: pid_t,
    ) -> WindowSnapshot? {
        windows.first {
            $0.ownerPID == appPID
                && $0.layer == 0
                && $0.alpha > 0.01
                && $0.bounds.width > 1
                && $0.bounds.height > 1
        }
    }

    /// AX tells us about the focused window, but it does not promise that the
    /// window is on the active Space or on the display the user is working on.
    /// This guard rejects stale/off-screen AX answers before they can hide the
    /// menu bar for a windowed app on another screen.
    nonisolated static func isAccessibilityWindowOnActiveDisplay(
        frame: CGRect,
        windows: [WindowSnapshot],
        displays: [DisplayGeometry],
        appPID: pid_t,
        pointer: CGPoint? = nil,
    ) -> Bool {
        guard let display = bestDisplay(for: frame, in: displays) else { return false }

        let onScreen = windows.contains {
            $0.ownerPID == appPID
                && $0.layer == 0
                && $0.alpha > 0.01
                && $0.bounds.isNearly(frame, tolerance: 8)
        }
        guard onScreen else { return false }

        // The focused window is the anchor when the pointer is not on one of
        // the app's displays; otherwise the pointer's display wins, matching
        // the geometry path.
        guard let active = activeDisplay(
            windows: windows,
            displays: displays,
            appPID: appPID,
            pointer: pointer,
        ) else { return true }

        return active.frame.isNearly(display.frame)
    }

    /// Some fullscreen players keep a small windowed surface in the normal
    /// window list and render the actual fullscreen picture through a window
    /// WindowServer no longer lists as on-screen. The focused AX window still
    /// reports `AXFullScreen=true`; accept it once its frame covers a display
    /// and that display also owns the app's frontmost on-screen window (or the
    /// pointer, when there is no such window). That keeps a stale AX window on
    /// another display from hiding the menu bar.
    nonisolated static func shouldTrustUnlistedAccessibilityFullscreen(
        frame: CGRect,
        windows: [WindowSnapshot],
        displays: [DisplayGeometry],
        appPID: pid_t,
        pointer: CGPoint? = nil,
    ) -> Bool {
        guard let target = bestDisplay(for: frame, in: displays),
              coversDisplay(frame, display: target)
        else { return false }

        if let front = frontmostWindow(windows: windows, appPID: appPID),
           let frontDisplay = bestDisplay(for: front.bounds, in: displays)
        {
            return frontDisplay.frame.isNearly(target.frame)
        }

        if let pointer,
           let pointerDisplay = displays.first(where: { $0.frame.contains(pointer) })
        {
            return pointerDisplay.frame.isNearly(target.frame)
        }

        return true
    }

    /// `NSEvent.mouseLocation` is AppKit (bottom-left) coordinates; the window
    /// list and the display frames are CoreGraphics (top-left).
    private func pointerLocationCG() -> CGPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
    }

    /// The Accessibility window whose frame is the one the geometry matched.
    /// `preferred` (the app's focused window) wins when its frame matches too,
    /// so a background window with the same frame cannot answer for it.
    private func matchingWindow(
        in application: AXUIElement?,
        frame: CGRect,
        preferring preferred: AXUIElement? = nil,
    ) -> AXUIElement? {
        guard let application,
              let windows = copyAttribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement]
        else { return nil }

        if let preferred, let preferredFrame = rect(of: preferred), preferredFrame.isNearly(frame) {
            return preferred
        }

        for window in windows {
            if let windowFrame = rect(of: window), windowFrame.isNearly(frame) {
                return window
            }
        }
        return nil
    }

    /// Reads the window's Accessibility subtree and asks the pure helper.
    /// Returns `nil` when the tree cannot be read at all.
    ///
    /// Chromium nests its toolbar several generic groups deep, so the walk
    /// goes deep enough to find the real toolbar, address field or tab strip.
    /// Two guards keep that affordable: the node budget, and stopping at the
    /// page-content subtrees that can never contain browser chrome.
    private func chromeVisible(in window: AXUIElement, windowFrame: CGRect) -> Bool? {
        var budget = Self.maxAXNodes
        guard let nodes = children(of: window, depth: Self.maxAXDepth, budget: &budget) else {
            return nil
        }
        return Self.showsWindowChrome(in: nodes, windowFrame: windowFrame)
    }

    /// True when the window still draws chrome — a toolbar, tab strip or
    /// address field — along its top edge. Two hints, either of which is
    /// enough:
    ///
    /// * a chrome-shaped role sitting in the top band of the window, or
    /// * the biggest element in the window starting well below the window's
    ///   top edge, which means a genuinely tall piece of chrome is drawn
    ///   above the content.
    ///
    /// Generic AXGroups are deliberately not chrome. Chromium uses them for
    /// transient info bars and page overlays; treating one as browser chrome
    /// is what stopped the menu bar from hiding for a fullscreen video.
    nonisolated static func showsWindowChrome(in nodes: [AXNode], windowFrame: CGRect) -> Bool {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return false }

        let chromeBand = windowFrame.minY + windowFrame.height * 0.12
        let minWidth = windowFrame.width * 0.45
        let maxChromeHeight = windowFrame.height * 0.4
        // Ten percent, not three: Chromium's transient info bars are around
        // 50 pt tall and must not be mistaken for a toolbar. A real toolbar
        // (or a browser that exposes its chrome only as a large container)
        // pushes the content far enough down to clear this threshold.
        let contentLift = windowFrame.height * 0.10

        var largest: CGRect?
        var stack = nodes
        while let node = stack.popLast() {
            guard !node.hidden else { continue }
            stack.append(contentsOf: node.children)

            let frame = node.frame.intersection(windowFrame)
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { continue }

            if chromeRoles.contains(node.role),
               frame.width >= minWidth,
               frame.height >= 4,
               frame.height <= maxChromeHeight,
               frame.minY <= chromeBand
            {
                return true
            }

            if largest == nil || area(frame) > area(largest!) {
                largest = frame
            }
        }

        if let largest,
           largest.height >= windowFrame.height * 0.60,
           largest.minY > windowFrame.minY + contentLift
        {
            return true
        }
        return false
    }

    /// Roles that browser chrome shows up as. A window that is playing a
    /// picture fullscreen has none of these along its top edge.
    ///
    /// `AXGroup` is deliberately absent: Chromium's transient info bars and
    /// page overlays are groups too, and treating every group in the top band
    /// as chrome is what made video fullscreen look like window fullscreen.
    private nonisolated static let chromeRoles: Set<String> = [
        "AXToolbar",
        "AXTabGroup",
        "AXTextField",
        "AXSearchField",
        "AXComboBox",
        "AXButton",
        "AXMenuButton",
        "AXPopUpButton",
        "AXRadioButton",
    ]

    private nonisolated static let maxAXDepth = 6
    private nonisolated static let maxAXNodes = 260

    /// Page-content subtrees cannot contain a toolbar, tab strip or address
    /// field. Stopping at them keeps the deeper traversal cheap even when the
    /// page itself has a large Accessibility tree.
    private nonisolated static let contentRoles: Set<String> = [
        "AXWebArea",
        "AXScrollArea",
        "AXList",
        "AXTable",
        "AXOutline",
        "AXTree",
        "AXGrid",
    ]

    private nonisolated static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    // MARK: - Accessibility

    private func accessibilityState(
        for app: FrontmostApp,
        windows: [WindowSnapshot],
        displays: [DisplayGeometry],
    ) -> FullscreenState? {
        let application = AXUIElementCreateApplication(app.pid)
        guard let window = focusedWindow(of: application) else {
            return nil
        }
        guard let flag = booleanAttribute(window, "AXFullScreen") else {
            return nil
        }
        guard let frame = rect(of: window) else { return nil }

        // AX can still describe a window that belongs to another Space or to
        // another display, so normally the same normal-layer window has to be
        // in the on-screen list. Some players (IINA/mpv, VLC, …) render their
        // fullscreen surface through a window that WindowServer omits from
        // that list while still reporting the focused AX window as
        // `AXFullScreen=true`. Treat that strong signal as valid when the
        // window geometrically covers a display and its display matches the
        // app's own on-screen window (or the pointer).
        let pointer = pointerLocationCG()
        let listedOnActiveDisplay = Self.isAccessibilityWindowOnActiveDisplay(
            frame: frame,
            windows: windows,
            displays: displays,
            appPID: app.pid,
            pointer: pointer,
        )
        let trustedUnlistedFullscreen = flag && Self.shouldTrustUnlistedAccessibilityFullscreen(
            frame: frame,
            windows: windows,
            displays: displays,
            appPID: app.pid,
            pointer: pointer,
        )
        guard listedOnActiveDisplay || trustedUnlistedFullscreen else { return nil }

        guard let display = Self.bestDisplay(for: frame, in: displays) else { return nil }
        let state = FullscreenState(
            isFullScreen: flag,
            scope: flag ? .content : .none,
            source: .accessibility,
            detail: flag ? "AXFullScreen=true" : "AXFullScreen=false",
            displayName: display.name,
        )
        return state
    }

    private func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        let candidates: [CFString] = [
            kAXFocusedWindowAttribute as CFString,
            kAXMainWindowAttribute as CFString,
        ]
        for attribute in candidates {
            if let window = copyAttribute(application, attribute) {
                return (window as! AXUIElement)
            }
        }
        if let windows = copyAttribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement],
           let first = windows.first
        {
            return first
        }
        return nil
    }

    private func booleanAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copyAttribute(element, attribute as CFString) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else { return nil }
        return value
    }

    private func children(
        of element: AXUIElement,
        depth: Int,
        budget: inout Int,
    ) -> [AXNode]? {
        guard budget > 0 else { return [] }
        guard let raw = copyAttribute(element, kAXChildrenAttribute as CFString) else { return nil }
        guard let kids = raw as? [AXUIElement] else { return [] }

        var result: [AXNode] = []
        for kid in kids.prefix(14) {
            guard budget > 0 else { break }
            if let child = node(of: kid, depth: depth, budget: &budget) {
                result.append(child)
            }
        }
        return result
    }

    private func node(
        of element: AXUIElement,
        depth: Int,
        budget: inout Int,
    ) -> AXNode? {
        guard budget > 0 else { return nil }
        guard let role = stringAttribute(element, kAXRoleAttribute as CFString),
              let frame = rect(of: element)
        else { return nil }

        budget -= 1
        let shouldDescend = depth > 0 && !Self.contentRoles.contains(role)
        return AXNode(
            role: role,
            frame: frame,
            hidden: booleanAttribute(element, "AXHidden") ?? false,
            children: shouldDescend
                ? (children(of: element, depth: depth - 1, budget: &budget) ?? [])
                : [],
        )
    }

    private func rect(of element: AXUIElement) -> CGRect? {
        guard let position = copyAttribute(element, kAXPositionAttribute as CFString),
              let size = copyAttribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        else { return nil }

        return CGRect(origin: origin, size: dimensions)
    }

    // MARK: - Geometry

    /// Every on-screen window, translated into plain values the classifier
    /// (and the tests) can work with. Read fresh on every sample, so plugging
    /// a display in or out is picked up without any cached state.
    private func windowSnapshots() -> [WindowSnapshot]? {
        // `.optionAll` is required for players whose fullscreen surface is not
        // listed in the on-screen window list. `evaluate` keeps only windows
        // that are either on screen or on the active Space, so windows from
        // other Spaces still cannot affect the decision.
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return rawWindows.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return WindowSnapshot(
                ownerPID: pid_t(pid),
                // A window whose layer we cannot read must not be treated as a
                // normal-layer window.
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                bounds: rect,
                windowNumber: (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                name: info[kCGWindowName as String] as? String,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
            )
        }
    }

    /// Pure classification, pinned by `FullscreenDetectorTests`.
    ///
    /// Only windows owned by `appPID` are ever considered, so a fullscreen
    /// window belonging to some other app — playing in another Space, on
    /// another display, or simply in the background — can never make the app
    /// in front look like it is fullscreen.
    nonisolated static func classify(
        windows: [WindowSnapshot],
        displays: [DisplayGeometry],
        appPID: pid_t,
        pointer: CGPoint? = nil,
        tolerance: CGFloat = 2,
    ) -> FullscreenState {
        // Only the app's frontmost normal window on the display the user is
        // actually on may answer this question. Considering every covering
        // window let a stale fullscreen surface behind a windowed player
        // (IINA/mpv) hide the bar while the user was looking at a normal
        // window. `CGWindowList` is ordered front-to-back, and `activeDisplay`
        // keeps the pointer's display authoritative when the list order
        // disagrees.
        let own = windows.filter {
            $0.ownerPID == appPID && $0.layer == 0 && $0.alpha > 0.01
        }
        guard !own.isEmpty else {
            return FullscreenState(
                isFullScreen: false,
                source: .unavailable,
                detail: "no on-screen window",
            )
        }

        let active = activeDisplay(
            windows: windows,
            displays: displays,
            appPID: appPID,
            pointer: pointer,
        )
        let candidates: [WindowSnapshot]
        if let active {
            candidates = own.filter { window in
                bestDisplay(for: window.bounds, in: displays)?
                    .frame.isNearly(active.frame) == true
            }
        } else {
            candidates = own
        }

        guard let frontmost = candidates.first ?? own.first else {
            return FullscreenState(
                isFullScreen: false,
                source: .unavailable,
                detail: "no on-screen window",
            )
        }
        guard let display = bestDisplay(for: frontmost.bounds, in: displays) ?? active else {
            return FullscreenState(
                isFullScreen: false,
                source: .geometry,
                detail: "window \(Int(frontmost.bounds.width))x\(Int(frontmost.bounds.height))",
            )
        }

        if coversDisplay(frontmost.bounds, display: display, tolerance: tolerance) {
            return FullscreenState(
                isFullScreen: true,
                scope: .content,
                source: .geometry,
                detail: "\(Int(frontmost.bounds.width))x\(Int(frontmost.bounds.height)) on \(display.name)",
                displayName: display.name,
            )
        }

        return FullscreenState(
            isFullScreen: false,
            source: .geometry,
            detail: "window \(Int(frontmost.bounds.width))x\(Int(frontmost.bounds.height))",
            displayName: display.name,
        )
    }

    /// The display a window rect belongs to: the one it overlaps most.
    nonisolated static func bestDisplay(for window: CGRect, in displays: [DisplayGeometry]) -> DisplayGeometry? {
        var best: (display: DisplayGeometry, area: CGFloat)?
        for display in displays {
            let overlap = display.frame.intersection(window)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            guard area > 0 else { continue }
            if best == nil || area > best!.area {
                best = (display, area)
            }
        }
        return best?.display
    }

    /// A window counts as fullscreen when it spans the display horizontally,
    /// fills at least the height the menu bar leaves behind, and touches
    /// either the top of the display (notched Macs, browsers, borderless
    /// players) or the bottom of it (native fullscreen showing the bar).
    nonisolated static func coversDisplay(
        _ rect: CGRect,
        display: DisplayGeometry,
        tolerance: CGFloat = 2,
    ) -> Bool {
        let screen = display.frame

        let spansWidth = rect.minX <= screen.minX + tolerance
            && rect.width >= screen.width - tolerance
        // Some secondary displays report menuBarHeight == 0 even though a
        // fullscreen video still leaves the menu-bar strip visible until the
        // preference is flipped. Assume the standard strip in that case.
        let menuBarHeight = max(display.menuBarHeight, DisplayGeometry.assumedMenuBarHeight)
        let tallEnough = rect.height >= screen.height - menuBarHeight - tolerance
        let reachesTop = rect.minY <= screen.minY + tolerance
        let reachesBottom = rect.maxY >= screen.maxY - tolerance

        return spansWidth && tallEnough && (reachesTop || reachesBottom)
    }
}

extension CGRect {
    /// True when two rects describe the same window. The window list and the
    /// Accessibility tree can disagree by a rounding error, and a window that
    /// was moved between the two reads must not be mistaken for a match.
    func isNearly(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
