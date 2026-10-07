/// One-time bridge from the sandboxed builds' preference domains to the
/// unsandboxed direct-distribution domain.
///
/// The earlier builds stored `isEnabled`, the language, exclusions and the
/// hotkey inside `~/Library/Containers/<bundle-id>/Data/Library/Preferences`.
/// An unsandboxed build reads the normal `~/Library/Preferences` domain, so
/// without this migration an existing user would look like a fresh install
/// (automation off, onboarding again). Copy the legacy values once, before
/// any preference is read.
enum LegacyDefaultsMigration {
    static func migrateIfNeeded(into defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: "isEnabled") == nil else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Containers/com.barveil.app/Data/Library/Preferences/com.barveil.app.plist",
            "\(home)/Library/Containers/app.barveil.Barveil/Data/Library/Preferences/app.barveil.Barveil.plist",
            "\(home)/Library/Preferences/com.barveil.app.plist",
        ]

        for path in candidates {
            guard let values = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            if defaults.object(forKey: "isEnabled") != nil { break }
        }
    }
}

// Everything the panel and the settings window can change. Stored in
// UserDefaults, published to SwiftUI.

import Foundation

@MainActor
final class Preferences: ObservableObject {
    private enum Key {
        static let enabled = "isEnabled"
        static let mode = "hideMode"
        static let excluded = "excludedBundleIDs"
        static let useAccessibility = "useAccessibility"
        static let includeUnattributed = "includeUnattributedPlayback"
        static let showBarWhenPaused = "showBarWhenPausedInFullscreen"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasRequestedAccessibility = "hasRequestedAccessibility"
        static let language = "appLanguage"
    }

    private let defaults: UserDefaults

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    @Published var mode: HideMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }

    @Published var excludedBundles: Set<String> {
        didSet { defaults.set(excludedBundles.sorted(), forKey: Key.excluded) }
    }

    /// Exact browser detection is always enabled now that the user-facing
    /// option is gone. The published property is retained for the detection
    /// plumbing and migration compatibility.
    @Published var useAccessibility: Bool {
        didSet { defaults.set(useAccessibility, forKey: Key.useAccessibility) }
    }

    @Published var includeUnattributedPlayback: Bool {
        didSet { defaults.set(includeUnattributedPlayback, forKey: Key.includeUnattributed) }
    }

    /// Full screen *and* paused: bring the bar back (default), or keep it hidden
    /// until the full screen picture is gone.
    @Published var showBarWhenPaused: Bool {
        didSet { defaults.set(showBarWhenPaused, forKey: Key.showBarWhenPaused) }
    }

    @Published var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled) }
    }

    @Published var hotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(hotkeyKeyCode), forKey: Key.hotkeyKeyCode) }
    }

    @Published var hotkeyModifiers: UInt32 {
        didSet { defaults.set(Int(hotkeyModifiers), forKey: Key.hotkeyModifiers) }
    }

    /// Fresh installs see a short welcome panel. Existing users are not sent
    /// through onboarding again after updating Barveil.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// Ensures macOS's native Accessibility registration prompt is shown at
    /// most once per install. The user still turns on the switch in System
    /// Settings themselves.
    @Published var hasRequestedAccessibility: Bool {
        didSet { defaults.set(hasRequestedAccessibility, forKey: Key.hasRequestedAccessibility) }
    }

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A fresh install must not touch the system before the user has seen
        // the explanation and explicitly opted in from the welcome panel.
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
        mode = (defaults.string(forKey: Key.mode).flatMap(HideMode.init(rawValue:))) ?? .smart
        excludedBundles = Set(defaults.stringArray(forKey: Key.excluded) ?? [])
        useAccessibility = true
        includeUnattributedPlayback = defaults.bool(forKey: Key.includeUnattributed)
        showBarWhenPaused = defaults.object(forKey: Key.showBarWhenPaused) as? Bool ?? true
        // The old user-facing show delay is replaced by the stabilizer.
        defaults.removeObject(forKey: "showDelaySeconds")
        hotkeyEnabled = defaults.object(forKey: Key.hotkeyEnabled) as? Bool ?? true
        hotkeyKeyCode = UInt32(defaults.object(forKey: Key.hotkeyKeyCode) as? Int ?? Int(HotkeyMonitor.Chord.default.keyCode))
        hotkeyModifiers = UInt32(defaults.object(forKey: Key.hotkeyModifiers) as? Int ?? Int(HotkeyMonitor.Chord.default.modifiers))
        hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool
            ?? (defaults.object(forKey: Key.enabled) != nil)
        hasRequestedAccessibility = defaults.bool(forKey: Key.hasRequestedAccessibility)
        language = defaults.string(forKey: Key.language)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var resolvedLocale: Locale {
        language.localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    /// Resolves an interface string in the user's chosen in-app language.
    ///
    /// `String(localized:locale:)` only uses the locale for formatting — the
    /// lookup itself follows the system language — so the matching `.lproj`
    /// bundle is loaded explicitly instead. Without this, AppKit surfaces
    /// such as the settings window title ignored the in-app language.
    func localized(_ key: String.LocalizationValue) -> String {
        let bundle = language.localeIdentifier
            .flatMap { identifier in
                Bundle.main.path(forResource: identifier, ofType: "lproj")
                    .flatMap(Bundle.init(path:))
            } ?? .main
        return String(localized: key, bundle: bundle)
    }

    var hotkeyChord: HotkeyMonitor.Chord {
        HotkeyMonitor.Chord(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    func setHotkey(_ chord: HotkeyMonitor.Chord) {
        hotkeyKeyCode = chord.keyCode
        hotkeyModifiers = chord.modifiers
    }

    func toggleExclusion(bundleID: String) {
        if excludedBundles.contains(bundleID) {
            excludedBundles.remove(bundleID)
        } else {
            excludedBundles.insert(bundleID)
        }
    }
}
