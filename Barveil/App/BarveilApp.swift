// Menu-bar-only app: no Dock icon, no main window. The popover is the whole
// interface; the settings window is one click away from its footer.

import SwiftUI

@main
struct BarveilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            LocalizedRoot {
                PopoverView()
            }
            .environmentObject(model)
            .environmentObject(model.preferences)
        } label: {
            Image(
                nsImage: BarveilGlyph.menuBarImage(
                    state: model.isAutomationEnabled
                        ? (model.isHidingNow ? .hiding : .ready)
                        : .off,
                ),
            )
            .renderingMode(.template)
            .accessibilityLabel(Text("Barveil"))
            .accessibilityValue(Text(model.panelPresentation.title))
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Barveil") {
                    AppWindowController.shared.showSettings(
                        model: model,
                        initialSection: .about,
                    )
                }
            }
        }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var previewWindows: [NSWindow] = []
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh the process icon before any system permission prompt is
        // presented. Without this, AppKit can keep serving the icon cached
        // when the previous build was launched.
        NSApp.applicationIconImage = BarveilIcon.app

        // Menu-bar only, always: no Dock icon and no "running" dot under one.
        // LSUIElement in Info.plist already asks for this; setting the policy
        // here keeps it true even if the app is launched in an odd way.
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-barveilPreviewUI") || arguments.contains("-barveilPreviewSettings") {
            MainActor.assumeIsolated {
                showPreviewWindow()
            }
            return
        }
        #endif

        // When Xcode runs the test bundle the app is only a host; leave the
        // menu bar alone.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        MainActor.assumeIsolated {
            AppModel.shared.start()
        }
    }

    #if DEBUG
    @MainActor
    private func showPreviewWindow() {
        let model = AppModel.shared
        let arguments = ProcessInfo.processInfo.arguments
        let isSettings = arguments.contains("-barveilPreviewSettings")

        if !arguments.contains("-barveilPreviewWelcome") {
            if arguments.contains("-barveilPreviewPlaying") {
                model.configurePreview(
                    bundleID: "com.apple.Safari",
                    appName: "Safari",
                    fullScreen: true,
                    playing: true,
                    decision: .hide(.smart),
                )
            } else if arguments.contains("-barveilPreviewExcluded") {
                model.configurePreview(
                    bundleID: "com.apple.Safari",
                    appName: "Safari",
                    fullScreen: true,
                    playing: true,
                    decision: .show(.excludedApp),
                    excluded: true,
                )
            } else if arguments.contains("-barveilPreviewPermission") {
                model.configurePreviewPermissionNeeded()
            } else if arguments.contains("-barveilPreviewUI") {
                model.completePreviewOnboarding()
            }
        }

        if isSettings {
            let appearance = arguments.contains("-barveilPreviewDark")
                ? NSAppearance(named: .darkAqua)
                : nil
            AppWindowController.shared.showSettings(model: model, appearance: appearance)
            return
        }

        let content = AnyView(
            LocalizedRoot {
                PopoverView()
            }
            .environmentObject(model)
            .environmentObject(model.preferences),
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "Barveil"
        if arguments.contains("-barveilPreviewDark") {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: BarveilMetrics.popoverWidth, height: 620))
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindows.append(window)
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif

    /// The app lives in the menu bar. Closing the settings window (or any
    /// other window) must never quit it — only the Quit button or ⌘Q does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.shutdown()
        }
    }
}
