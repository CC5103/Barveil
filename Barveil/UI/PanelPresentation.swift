// UI-facing projection of AppModel. Keeping the copy and action selection in
// one small value type makes the popover easier to reason about and lets the
// behavior stay pinned by tests without involving SwiftUI layout.

import Foundation

enum MenuBarPanelAction: Equatable {
    case enableAutomation
    case hideMenuBar
    case showMenuBar
    case includeCurrentApp
    case clearPin
    case none

    var systemName: String {
        switch self {
        case .enableAutomation: "power"
        case .hideMenuBar: "eye.slash"
        case .showMenuBar: "eye"
        case .includeCurrentApp: "plus.circle"
        case .clearPin: "arrow.uturn.backward"
        case .none: "checkmark"
        }
    }
}

struct MenuBarPanelPresentation: Equatable {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let systemName: String
    let tone: BarveilTone
    let primaryAction: MenuBarPanelAction
    let isPinned: Bool

    static func make(
        isEnabled: Bool,
        decision: Decision,
        isFrontAppExcluded: Bool,
    ) -> MenuBarPanelPresentation {
        guard isEnabled else {
            return MenuBarPanelPresentation(
                title: "Automatic control is off",
                message: "Turn it on to let Barveil manage the menu bar. Your current system setting is unchanged.",
                systemName: "power",
                tone: .inactive,
                primaryAction: .enableAutomation,
                isPinned: false,
            )
        }

        if isFrontAppExcluded {
            return MenuBarPanelPresentation(
                title: "This app is excluded",
                message: "The menu bar stays under your control while this app is in front.",
                systemName: "hand.raised.fill",
                tone: .waiting,
                primaryAction: .includeCurrentApp,
                isPinned: false,
            )
        }

        switch decision {
        case .hide(.smart):
            return MenuBarPanelPresentation(
                title: "Menu bar hidden",
                message: "It will come back when playback pauses or the picture leaves full screen.",
                systemName: "eye.slash.fill",
                tone: .active,
                primaryAction: .showMenuBar,
                isPinned: false,
            )

        case .hide(.pinned):
            return MenuBarPanelPresentation(
                title: "Hidden until the app changes",
                message: "This manual choice stays put until the front app changes.",
                systemName: "pin.fill",
                tone: .active,
                primaryAction: .showMenuBar,
                isPinned: true,
            )

        case .show(.pinned):
            return MenuBarPanelPresentation(
                title: "Visible until the app changes",
                message: "This manual choice stays put until the front app changes.",
                systemName: "pin.fill",
                tone: .waiting,
                primaryAction: .hideMenuBar,
                isPinned: true,
            )

        case .show(.manualMode):
            return MenuBarPanelPresentation(
                title: "Manual control",
                message: "Automatic detection is off. Use the button below or your keyboard shortcut.",
                systemName: "hand.tap.fill",
                tone: .waiting,
                primaryAction: .hideMenuBar,
                isPinned: false,
            )

        case .show(.notPlaying):
            return MenuBarPanelPresentation(
                title: "Waiting for playback",
                message: "The picture is full screen. The menu bar will step aside when playback begins.",
                systemName: "pause.rectangle.fill",
                tone: .waiting,
                primaryAction: .hideMenuBar,
                isPinned: false,
            )

        case .show(.transition):
            return MenuBarPanelPresentation(
                title: "Leaving full screen",
                message: "The menu bar is returning with the system transition.",
                systemName: "arrow.uturn.backward",
                tone: .waiting,
                primaryAction: .none,
                isPinned: false,
            )

        case .show(.excludedApp):
            return MenuBarPanelPresentation(
                title: "This app is excluded",
                message: "The menu bar stays under your control while this app is in front.",
                systemName: "hand.raised.fill",
                tone: .waiting,
                primaryAction: .includeCurrentApp,
                isPinned: false,
            )

        case .show(.disabled), .show(.noFrontApp), .show(.notFullScreen):
            return MenuBarPanelPresentation(
                title: "Ready",
                message: "Start a full-screen video. Windowed playback and ordinary app windows are left alone.",
                systemName: "play.rectangle.fill",
                tone: .ready,
                primaryAction: .hideMenuBar,
                isPinned: false,
            )
        }
    }
}

extension AppModel {
    var panelPresentation: MenuBarPanelPresentation {
        .make(
            isEnabled: isAutomationEnabled,
            decision: decision,
            isFrontAppExcluded: isFrontAppExcluded,
        )
    }
}
