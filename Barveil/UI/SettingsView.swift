// Settings use a native sidebar/detail hierarchy without the automatic
// navigation toolbar. That keeps the page header visible and avoids the tall
// transparent toolbar region introduced by NavigationSplitView on macOS 27.

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case privacy
    case advanced
    case about

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .general: "General"
        case .privacy: "Privacy"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var systemName: String {
        switch self {
        case .general: "gearshape"
        case .privacy: "hand.raised"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SettingsSection

    init(initialSection: SettingsSection? = nil) {
        _selection = State(initialValue: initialSection ?? Self.initialSelection)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.systemName)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 158)

            Divider().opacity(0.5)

            detail
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Couldn’t Update Settings",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } },
            ),
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettingsView()
        case .privacy: PrivacySettingsView()
        case .advanced: AdvancedSettingsView()
        case .about: AboutSettingsView()
        }
    }

    private static var initialSelection: SettingsSection {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-barveilPreviewTab"),
              arguments.indices.contains(index + 1),
              let section = SettingsSection(rawValue: arguments[index + 1])
        else { return .general }
        return section
    }
}
