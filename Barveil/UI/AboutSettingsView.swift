import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsPage {
            Section {
                VStack(spacing: 0) {
                    Image(nsImage: BarveilIcon.app)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 84, height: 84)
                        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)

                    Text("Barveil")
                        .font(.title2.weight(.semibold))
                        .padding(.top, 13)

                    Text("Version \(model.version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section {
                Button {
                    NSWorkspace.shared.open(AppLinks.repository)
                } label: {
                    Label("GitHub", systemImage: "link")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    NSWorkspace.shared.open(AppLinks.releases)
                } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Links")
            }
        }
    }
}
