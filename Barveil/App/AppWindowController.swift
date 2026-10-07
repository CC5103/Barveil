// Owns the settings window explicitly instead of relying on SwiftUI's
// Settings scene. Menu-bar-only apps are frequently inactive when a popover
// closes, and an accessory app needs an explicit activation pass to make a
// settings window reliably visible in front.

import AppKit
import SwiftUI

@MainActor
final class AppWindowController: NSObject, NSWindowDelegate {
    static let shared = AppWindowController()

    private var settingsWindow: NSWindow?

    private override init() {
        super.init()
    }

    func showSettings(
        model: AppModel,
        appearance: NSAppearance? = nil,
        initialSection: SettingsSection? = nil,
    ) {
        if initialSection != nil, let existingWindow = settingsWindow {
            existingWindow.close()
            settingsWindow = nil
        }

        let window = settingsWindow ?? makeSettingsWindow(model: model, initialSection: initialSection)
        settingsWindow = window
        if let appearance {
            window.appearance = appearance
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            center(window, on: targetScreen())
        }
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeSettingsWindow(model: AppModel, initialSection: SettingsSection? = nil) -> NSWindow {
        let content = LocalizedRoot {
            SettingsView(initialSection: initialSection)
        }
        .environmentObject(model)
        .environmentObject(model.preferences)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )
        window.title = model.preferences.localized("Barveil Settings")
        window.contentViewController = NSHostingController(rootView: content)
        // NSHostingController lays out asynchronously. Without an explicit
        // content size, NSWindow.center() operates on a tiny placeholder
        // frame and SwiftUI later grows the window from the wrong corner.
        window.setContentSize(NSSize(width: 700, height: 560))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }

    /// The settings window is deliberately centered on every fresh open. A
    /// saved frame from an older build or a removed display must not make it
    /// reappear off-center or partly off-screen.
    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let windowFrame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - windowFrame.width / 2,
            y: visibleFrame.midY - windowFrame.height / 2,
        )
        window.setFrameOrigin(origin)
    }

    /// The settings window floats while the user is actively working in it,
    /// then returns to normal level when focus moves elsewhere. This avoids
    /// both the "opens behind everything" bug and an always-on-top window.
    func windowDidBecomeKey(_ notification: Notification) {
        settingsWindow?.level = .floating
    }

    func windowDidResignKey(_ notification: Notification) {
        settingsWindow?.level = .normal
    }
}
