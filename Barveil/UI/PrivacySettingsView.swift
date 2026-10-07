// Permission status and the single action needed to resolve it.

import Combine
import SwiftUI

struct PrivacySettingsView: View {
    @EnvironmentObject private var model: AppModel
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(model.accessibilityTrusted ? BarveilColor.systemAccent : Color.orange)
                        .frame(width: 26)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.accessibilityTrusted ? "Accessibility access granted" : "Accessibility access not granted")
                            .font(.callout.weight(.medium))
                        if model.accessibilityTrusted {
                            Text("The system switch for Barveil is on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)
                }

                if !model.accessibilityTrusted {
                    BarveilActionButton(.prominent, controlSize: .regular) {
                        model.beginAccessibilitySetup()
                    } label: {
                        Text("Open System Settings")
                    }
                } else {
                    BarveilActionButton(.standard, controlSize: .regular) {
                        model.openAccessibilitySettings()
                    } label: {
                        Text("Open System Settings")
                    }
                }
            } header: {
                Text("Accessibility")
            }
        }
        .onAppear {
            model.promptForAccessibilityIfNeeded()
            model.refreshAccessibilityStatus()
        }
        .onReceive(permissionTimer) { _ in
            model.refreshAccessibilityStatus()
        }
    }
}
