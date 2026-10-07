// Per-app exceptions. The current app can be added here as well as from the
// menu-bar panel.

import SwiftUI

struct ExcludedAppsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Section {
            if let frontApp = model.sample?.frontApp, !model.isFrontAppExcluded {
                HStack(spacing: 12) {
                    AppBundleIcon(bundleID: frontApp.bundleID, size: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(frontApp.name)
                            .font(.callout.weight(.medium))
                        Text("Current app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Exclude") {
                        model.toggleExclusionForFrontApp()
                    }
                    .controlSize(.small)
                }
            }

            if preferences.excludedBundles.isEmpty {
                ContentUnavailableView {
                    Label("No excluded apps", systemImage: "hand.raised")
                } description: {
                    Text("When an app is excluded, Barveil leaves the menu bar exactly as it is whenever that app is in front.")
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ForEach(preferences.excludedBundles.sorted(), id: \.self) { bundleID in
                    HStack(spacing: 12) {
                        AppBundleIcon(bundleID: bundleID, size: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppModel.displayName(forBundleID: bundleID))
                                .font(.callout.weight(.medium))
                            Text(bundleID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button {
                            preferences.toggleExclusion(bundleID: bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Remove"))
                        .accessibilityLabel(Text("Remove"))
                    }
                }
            }
        } header: {
            Text("Excluded Apps")
        } footer: {
            Text("You can also exclude the current app directly from the Barveil panel.")
        }
    }
}
