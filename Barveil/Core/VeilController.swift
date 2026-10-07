// The one system preference Barveil touches:
//
//     NSGlobalDomain · AppleMenuBarVisibleInFullscreen
//     System Settings ▸ Control Center ▸ "Automatically hide and show the
//     menu bar in full screen"
//
// The user's original value is only a restore point. While Barveil is enabled
// it manages a consistent visible baseline itself:
//
//     visible baseline -> true
//     video playback   -> false
//
// That makes the feature behave the same for users who initially chose
// "Always", "On Desktop", or "In Full Screen". The original value is restored
// when Barveil is disabled or quits. The distributed notification makes
// WindowServer re-read a value for a window that is already fullscreen.

import Foundation

@MainActor
final class VeilController {
    private enum Key {
        static let name = "AppleMenuBarVisibleInFullscreen" as CFString
        static let domain = kCFPreferencesAnyApplication
        static let user = kCFPreferencesCurrentUser
        static let host = kCFPreferencesAnyHost
        static let notification = Notification.Name("AppleInterfaceFullScreenMenuBarVisibilityChangedNotification")
        static let baseline = "userBaselineMenuBarVisibleInFullscreen"
        static let managedActive = "managedMenuBarPreferenceActive"
        static let legacyAppliedHidden = "lastAppliedHidden"
    }

    /// The value to restore when Barveil stops managing the preference.
    private(set) var baseline: Bool
    /// Whether Barveil is currently the reason the bar is hidden.
    private(set) var isHiding = false

    private let defaults: UserDefaults
    private var lastWrittenValue: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.baseline) != nil {
            baseline = defaults.bool(forKey: Key.baseline)
        } else {
            baseline = Self.readPreference() ?? true
        }

        // Restore after an abnormal exit no matter whether the last managed
        // value was hidden (false) or visible (true). The legacy flag only
        // covered the hidden case and is kept for migration.
        let needsRecovery = defaults.bool(forKey: Key.managedActive)
            || defaults.bool(forKey: Key.legacyAppliedHidden)
        if needsRecovery {
            Self.write(visible: baseline)
            defaults.set(false, forKey: Key.managedActive)
            defaults.set(false, forKey: Key.legacyAppliedHidden)
        }
    }

    /// The stable visible value used while Barveil is enabled.
    static func managedValue(hidden: Bool) -> Bool {
        !hidden
    }

    func apply(hidden: Bool) {
        adoptUserChangeIfAny()

        let desired = Self.managedValue(hidden: hidden)
        let current = Self.readPreference()
        guard hidden != isHiding || lastWrittenValue != desired || current != desired else {
            defaults.set(true, forKey: Key.managedActive)
            return
        }

        // Only touch the preference when its value actually has to move:
        // every write is re-broadcast to WindowServer, and a needless one
        // re-animates the menu bar inside a fullscreen window.
        if current != desired {
            Self.write(visible: desired)
        }
        lastWrittenValue = desired
        isHiding = hidden
        defaults.set(true, forKey: Key.managedActive)
        defaults.set(false, forKey: Key.legacyAppliedHidden)
    }

    /// Puts the user's own value back and stops managing the preference.
    func resetToUserSetting() {
        Self.write(visible: baseline)
        lastWrittenValue = baseline
        isHiding = false
        defaults.set(false, forKey: Key.managedActive)
        defaults.set(false, forKey: Key.legacyAppliedHidden)
    }

    /// Re-reads the preference so a change made in System Settings while
    /// Barveil is idle becomes the value restored later.
    @discardableResult
    func adoptUserChangeIfAny() -> Bool {
        guard !isHiding, let current = Self.readPreference(), current != lastWrittenValue else {
            return false
        }
        baseline = current
        defaults.set(current, forKey: Key.baseline)
        return true
    }

    // MARK: - Preference plumbing

    private static func readPreference() -> Bool? {
        CFPreferencesSynchronize(Key.domain, Key.user, Key.host)
        guard let raw = CFPreferencesCopyValue(Key.name, Key.domain, Key.user, Key.host) else { return nil }
        return (raw as? Bool)
    }

    private static func write(visible: Bool) {
        CFPreferencesSetValue(Key.name, visible as CFBoolean, Key.domain, Key.user, Key.host)
        CFPreferencesSynchronize(Key.domain, Key.user, Key.host)
        DistributedNotificationCenter.default().postNotificationName(
            Key.notification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true,
        )
    }
}
