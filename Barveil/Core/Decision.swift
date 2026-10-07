// The pure decision table. Everything that touches AppKit, CoreAudio or
// preferences lives elsewhere, so this file stays trivially testable and is
// pinned by `DecisionTests`.

import Foundation

/// How Barveil decides when the menu bar should get out of the way.
enum HideMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Fullscreen *and* playing. The scoped version of macOS's own
    /// "hide the menu bar in full screen" setting. Windowed playback is
    /// deliberately left alone.
    case smart
    /// Nothing automatic. Hotkey (or the switch in the panel) only.
    case manual

    var id: String { rawValue }

    var localizedName: LocalizedStringResource {
        switch self {
        case .smart: "Smart"
        case .manual: "Manual"
        }
    }

    var localizedSummary: LocalizedStringResource {
        switch self {
        case .smart:
            "Hides the menu bar only when the front app is playing full-screen video. Windowed playback is left alone."
        case .manual:
            "Turns automatic detection off. Use the menu-bar button or keyboard shortcut to hide and show the bar."
        }
    }
}

/// A manual overrule from the hotkey. Cleared as soon as the front app
/// changes, so automatic control always comes back on its own.
enum ManualPin: Equatable, Sendable {
    case none
    case show
    case hide

    var flipped: ManualPin {
        self == .hide ? .show : .hide
    }
}

enum HideReason: String, Equatable, Sendable {
    /// Fullscreen + playing.
    case smart
    /// The user pinned this state with the hotkey.
    case pinned
}

enum ShowReason: String, Equatable, Sendable {
    case disabled
    case pinned
    case manualMode
    case noFrontApp
    case notFullScreen
    case notPlaying
    case excludedApp
    /// The app just left fullscreen; a short guard keeps the bar from
    /// hiding again during the window/Space transition.
    case transition
}

enum Decision: Equatable, Sendable {
    case hide(HideReason)
    case show(ShowReason)

    var shouldHide: Bool {
        if case .hide = self { return true }
        return false
    }

    /// Stable identifier for the diagnostics list, e.g. `hide(smart)`.
    var diagnosticTag: String {
        switch self {
        case .hide(let reason): "hide(\(reason.rawValue))"
        case .show(let reason): "show(\(reason.rawValue))"
        }
    }
}

struct DecisionInput: Equatable, Sendable {
    var enabled: Bool
    var mode: HideMode
    var pin: ManualPin
    var frontAppBundleID: String?
    var isFullScreen: Bool
    var isPlaying: Bool
    var isExcluded: Bool
    /// The user's choice for "full screen and paused": showing the bar again
    /// is the default; turning it off keeps the bar hidden until the full
    /// screen picture actually goes away.
    var showBarWhenPaused: Bool = true
}

/// Gate order matters: the first gate that fails wins, and the reason it
/// reports is what the panel shows and what lands in the log.
func decide(_ input: DecisionInput) -> Decision {
    guard input.enabled else { return .show(.disabled) }

    // A pinned state outranks every automatic gate, in every mode.
    switch input.pin {
    case .hide: return .hide(.pinned)
    case .show: return .show(.pinned)
    case .none: break
    }

    guard input.mode != .manual else { return .show(.manualMode) }

    // Without a front app there is nothing to reason about.
    guard input.frontAppBundleID != nil else { return .show(.noFrontApp) }

    // The user asked us to keep our hands off this app.
    guard !input.isExcluded else { return .show(.excludedApp) }

    switch input.mode {
    case .smart:
        guard input.isFullScreen else { return .show(.notFullScreen) }
        guard input.isPlaying else {
            return input.showBarWhenPaused ? .show(.notPlaying) : .hide(.smart)
        }
        return .hide(.smart)

    case .manual:
        return .show(.manualMode)
    }
}
