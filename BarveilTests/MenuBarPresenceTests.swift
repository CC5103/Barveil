// The app must live in the menu bar only: a status item while it runs, and no
// Dock icon (and therefore no "running" dot under one) at any point.

import AppKit
import XCTest

@testable import Barveil

final class MenuBarPresenceTests: XCTestCase {
    /// The built app carries LSUIElement, which is what keeps it out of the Dock.
    func testAppIsBuiltAsAMenuBarAccessory() throws {
        let value = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool,
            "LSUIElement is missing from the app's Info.plist",
        )
        XCTAssertTrue(value, "LSUIElement must stay true so the app never gets a Dock icon or dot.")
    }

    /// Closing the settings window keeps the app alive in the menu bar.
    func testClosingTheLastWindowDoesNotQuit() {
        let delegate = AppDelegate()
        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
        )
    }

    /// The running app reports the accessory activation policy, so the Dock
    /// shows neither an icon nor a running dot.
    func testRunningAppUsesTheAccessoryActivationPolicy() {
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification),
        )
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .accessory)
    }
}
