// Detection edge cases, system recovery, and the short diagnostics trail.

import AppKit
import SwiftUI

struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: Preferences
    @State private var showsRestoreConfirmation = false
    @State private var didCopyDiagnostics = false

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: $preferences.includeUnattributedPlayback) {
                    SettingsLabel(
                        systemName: "waveform",
                        title: "Treat unattributed audio as playback",
                        subtitle: "May help with unusual players that route audio through another process.",
                    )
                }
            } header: {
                Text("Detection")
            } footer: {
                Text("Leave this off unless a player is not detected. It can produce more false positives.")
            }

            Section {
                LabeledContent("Barveil control") {
                    Text(model.isAutomationEnabled ? "Active" : "Off")
                        .foregroundStyle(.secondary)
                }

                if model.isAutomationEnabled {
                    Button("Restore and Turn Off Automation") {
                        showsRestoreConfirmation = true
                    }
                }

                Text("While Barveil is running, it uses a consistent visible baseline and temporarily hides the menu bar only during playback. Your original full-screen menu-bar setting is restored when Barveil is turned off or quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("System Recovery")
            }

            Section {
                HStack {
                    Label("\(model.recentEvents.count) recorded events", systemImage: "list.bullet.rectangle")
                        .font(.callout)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnosticsText, forType: .string)
                        didCopyDiagnostics = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            didCopyDiagnostics = false
                        }
                    } label: {
                        Label(didCopyDiagnostics ? "Copied" : "Copy", systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)

                    Button(role: .destructive) {
                        model.clearDiagnostics()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .controlSize(.small)
                }

                DiagnosticsLogView(events: model.recentEvents)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The log is kept in memory, is limited to 30 events, and can be copied when you report a problem.")
            }
        }
        .confirmationDialog(
            "Restore System Setting?",
            isPresented: $showsRestoreConfirmation,
            titleVisibility: .visible,
        ) {
            Button("Restore and Turn Off Automation", role: .destructive) {
                model.restoreSystemSettingAndDisable()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This turns off automatic control and restores the menu-bar setting that was active before Barveil changed it.")
        }
    }
}

private struct DiagnosticsLogView: View {
    let events: [DiagnosticEvent]

    var body: some View {
        ScrollView {
            if events.isEmpty {
                Text("Nothing recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.tag)
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(event.detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(9)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 128, maxHeight: 150)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }
}
