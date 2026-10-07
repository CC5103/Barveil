// Accessibility is optional and is used only to distinguish a browser window
// in full screen from media that fills the browser content area. The first
// request uses macOS's own registration prompt; the app never opens System
// Settings in that same action.

import AppKit
import ApplicationServices

enum AccessibilityPermission {
    enum SetupAction: Equatable {
        case register
        case openSettings
    }

    /// First request keeps the native registration prompt and System Settings
    /// separate. Once the prompt has been requested, later actions only open
    /// the pane.
    static func setupAction(isTrusted: Bool, hasRequested: Bool) -> SetupAction {
        if isTrusted || hasRequested {
            return .openSettings
        }
        return .register
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows macOS's native registration prompt. This registers Barveil in
    /// the Accessibility list; the user still turns on the switch later. The
    /// system prompt owns the next step, so this method intentionally does not
    /// open System Settings itself.
    static func requestRegistration() {
        NSApp.applicationIconImage = BarveilIcon.app
        NSApp.activate(ignoringOtherApps: true)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Brings the exact Accessibility pane forward. Adding the app and
    /// turning on the switch remain explicit user actions in System Settings.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
