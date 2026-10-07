// General preferences: behavior, language, startup, and exceptions.

import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        SettingsPage {
            Section {
                Picker("Control mode", selection: $preferences.mode) {
                    ForEach(HideMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(preferences.mode.localizedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("When full screen is paused", selection: $preferences.showBarWhenPaused) {
                    Text("Show Menu Bar").tag(true)
                    Text("Keep Hidden").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(preferences.mode != .smart)

                Text("“Keep Hidden” leaves the menu bar out of the way until the full-screen picture closes. This choice has no effect in manual mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Behavior")
            }

            Section {
                Picker("Language", selection: $preferences.language) {
                    Text("System Default").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                    Text(verbatim: "日本語").tag(AppLanguage.japanese)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Language")
            } footer: {
                Text("Changes take effect immediately.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) },
                )) {
                    SettingsLabel(
                        systemName: "power",
                        title: "Launch at login",
                        subtitle: "Start quietly in the menu bar after you sign in.",
                    )
                }

                if LoginItem.requiresApproval {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text("Waiting for approval in System Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open") { LoginItem.openSystemSettings() }
                                .controlSize(.small)
                        }
                    } label: {
                        Label("Waiting for approval", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Startup")
            }

            ExcludedAppsSection()
        }
        .onAppear {
            model.refreshLoginItem()
        }
    }
}
