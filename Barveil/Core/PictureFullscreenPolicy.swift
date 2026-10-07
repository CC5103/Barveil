// Dock tells us that a native fullscreen *Space* is active and which PID owns
// it. That is not the same as "the picture is fullscreen": a browser window in
// native fullscreen can still show its tab strip and address bar while media
// plays in the page. The policy below combines the two facts:
//
//   Dock fullscreen Space + owner match + picture confirmation -> hide
//   Dock fullscreen Space + owner match + browser chrome        -> show
//   Dock fullscreen Space + different owner                    -> show
//
// For non-browsers the picture confirmation is the existing geometry/AX
// "frontmost window covers the display" result. For browsers it is the
// browser-specific chrome heuristic: `.content` means the browser chrome is
// gone (video/picture fullscreen); `.window` means tabs/address bar are still
// visible, or Accessibility was unavailable to prove otherwise.

import Foundation

enum PictureFullscreenPolicy {
    static func resolve(
        raw: FullscreenState,
        dockIsFullScreen: Bool,
        frontOwnsDock: Bool,
        isBrowser: Bool,
        isPlaying: Bool,
    ) -> FullscreenState {
        if dockIsFullScreen {
            guard frontOwnsDock else {
                return FullscreenState(
                    isFullScreen: false,
                    scope: .none,
                    source: .dock,
                    detail: "front app does not own the fullscreen Space",
                )
            }

            if isBrowser {
                guard raw.scope == .content else {
                    return FullscreenState(
                        isFullScreen: false,
                        scope: .window,
                        source: .dock,
                        detail: "Dock fullscreen Space but browser chrome is still visible (or Accessibility is unavailable)",
                    )
                }
                return FullscreenState(
                    isFullScreen: true,
                    scope: .content,
                    source: .dock,
                    detail: "Dock fullscreen Space with picture fullscreen",
                )
            }

            guard raw.isFullScreen else {
                return FullscreenState(
                    isFullScreen: false,
                    scope: .none,
                    source: .dock,
                    detail: "Dock fullscreen Space but the front window is not a covering picture",
                )
            }
            return FullscreenState(
                isFullScreen: true,
                scope: .content,
                source: .dock,
                detail: "Dock fullscreen Space with covering picture",
            )
        }

        // No native fullscreen Space: keep a legacy/borderless fullscreen
        // result only while media is actually playing. This is what preserves
        // IINA's legacy fullscreen without letting a stale window hide the bar
        // in an ordinary windowed app.
        if raw.isFullScreen, isPlaying {
            return raw
        }
        return FullscreenState(
            isFullScreen: false,
            scope: .none,
            source: .dock,
            detail: "no fullscreen Space",
        )
    }
}
