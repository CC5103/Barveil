// The menu-bar panel. It is intentionally a status-first surface: the user
// sees whether Barveil is ready, hidden, or waiting, plus one primary action.
// Technical signals and diagnostics live below a disclosure or in Settings.

import AppKit
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var showsDetails = false

    private var forceWelcomePreview: Bool {
        ProcessInfo.processInfo.arguments.contains("-barveilPreviewWelcome")
    }

    var body: some View {
        Group {
            if model.shouldShowOnboarding || forceWelcomePreview {
                OnboardingPanel()
                    .environmentObject(preferences)
                    .environmentObject(model)
            } else {
                mainPanel
            }
        }
        .frame(width: BarveilMetrics.popoverWidth)
        .onAppear {
            model.promptForAccessibilityIfNeeded()
            model.refreshAccessibilityStatus()
        }
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

    private var mainPanel: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.42)

            ScrollView {
                VStack(spacing: BarveilMetrics.sectionSpacing) {
                    statusCard
                    contextCallouts
                    actions
                    detailsCard
                }
                .padding(BarveilMetrics.contentPadding)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().opacity(0.42)
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: BarveilIcon.app)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)

            Text("Barveil")
                .font(.headline)

            Spacer(minLength: 8)

            Toggle("Automatic", isOn: Binding(
                get: { model.isAutomationEnabled },
                set: { model.setAutomationEnabled($0) },
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(Text("Automatically hide the menu bar during full-screen playback."))
        }
        .padding(.horizontal, BarveilMetrics.contentPadding)
        .padding(.vertical, 11)
    }

    // MARK: - Status

    private var statusCard: some View {
        let presentation = model.panelPresentation

        return BarveilSurface {
            HStack(alignment: .top, spacing: 14) {
                BarveilIconBadge(
                    systemName: presentation.systemName,
                    tone: presentation.tone,
                    size: 50,
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(presentation.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var contextCallouts: some View {
        if showsAccessibilityPermissionWarning {
            BarveilCallout(
                systemName: "lock.open",
                title: "Exact browser detection needs permission",
                message: "macOS needs Accessibility access to tell a full-screen browser window apart from a full-screen video.",
                tone: .warning,
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    BarveilActionButton(.prominent, tint: .orange, controlSize: .small) {
                        model.beginAccessibilitySetup()
                    } label: {
                        Text("Open System Settings")
                    }

                }
            }
        }
    }

    /// Permission problems are relevant as soon as exact detection is on,
    /// so opening the panel makes the next step immediately visible.
    private var showsAccessibilityPermissionWarning: Bool {
        model.isAutomationEnabled
            && model.usesAccessibilityForDetection
            && !model.accessibilityTrusted
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        let presentation = model.panelPresentation

        if presentation.primaryAction == .none {
            BarveilSurface(padding: 13) {
                Label("No action needed right now", systemImage: "checkmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    BarveilActionButton(
                        .prominent,
                        tint: actionTint(for: presentation),
                        controlSize: .large,
                    ) {
                        perform(presentation.primaryAction)
                    } label: {
                        Label(
                            primaryTitle(for: presentation.primaryAction),
                            systemImage: presentation.primaryAction.systemName,
                        )
                        .frame(maxWidth: .infinity)
                    }

                    if let secondary = secondaryAction(for: presentation) {
                        BarveilActionButton(.standard, controlSize: .large) {
                            perform(secondary)
                        } label: {
                            Label(
                                secondaryTitle(for: secondary),
                                systemImage: secondary.systemName,
                            )
                            .lineLimit(1)
                        }
                    }
                }

                if !model.isAutomationEnabled {
                    Text("Your current macOS menu-bar setting is preserved while automation is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
            }
        }
    }

    private func primaryTitle(for action: MenuBarPanelAction) -> LocalizedStringResource {
        switch action {
        case .enableAutomation: "Turn On Automatic Control"
        case .hideMenuBar: "Hide Menu Bar"
        case .showMenuBar: "Show Menu Bar"
        case .includeCurrentApp: "Include This App"
        case .clearPin: "Done"
        case .none: "No Action Needed"
        }
    }

    private func secondaryAction(for presentation: MenuBarPanelPresentation) -> MenuBarPanelAction? {
        guard model.isAutomationEnabled else { return nil }
        if presentation.isPinned { return .clearPin }
        if presentation.primaryAction == .includeCurrentApp { return nil }
        return model.canToggleExclusion ? .includeCurrentApp : nil
    }

    private func secondaryTitle(for action: MenuBarPanelAction) -> LocalizedStringResource {
        switch action {
        case .includeCurrentApp:
            model.isFrontAppExcluded ? "Include This App" : "Exclude This App"
        case .clearPin:
            "Restore Automatic"
        case .enableAutomation, .hideMenuBar, .showMenuBar, .none:
            "Done"
        }
    }

    private func actionTint(for presentation: MenuBarPanelPresentation) -> Color? {
        presentation.tone == .warning ? .orange : nil
    }

    private func perform(_ action: MenuBarPanelAction) {
        switch action {
        case .enableAutomation:
            model.setAutomationEnabled(true)
        case .hideMenuBar, .showMenuBar:
            model.togglePinned()
        case .includeCurrentApp:
            model.toggleExclusionForFrontApp()
        case .clearPin:
            model.clearPin()
        case .none:
            break
        }
    }

    // MARK: - Details

    private var detailsCard: some View {
        BarveilSurface(padding: 13) {
            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(spacing: 9) {
                    Divider().opacity(0.45)

                    BarveilDetailRow(
                        systemName: "app",
                        label: "App",
                        value: model.frontAppName,
                    )

                    BarveilDetailRow(
                        systemName: "display",
                        label: "Display",
                        value: model.activeDisplayName,
                    )

                    BarveilDetailRow(
                        systemName: model.isFullScreen ? "rectangle.inset.filled" : "rectangle",
                        label: "Picture full screen",
                        value: yesOrNo(model.isFullScreen),
                        tone: model.isFullScreen ? .ready : .inactive,
                        showsStateIcon: true,
                    )

                    BarveilDetailRow(
                        systemName: model.isPlaying ? "waveform" : "speaker.slash",
                        label: "Playing",
                        value: yesOrNo(model.isPlaying),
                        tone: model.isPlaying ? .ready : .inactive,
                        showsStateIcon: true,
                    )

                    if !model.detectionDetail.isEmpty, model.detectionDetail != "—" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Detection details")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(model.detectionDetail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    }
                }
                .padding(.top, 9)
            } label: {
                HStack(spacing: 8) {
                    Label("Why this state?", systemImage: "info.circle")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
            }
        }
        .onChange(of: model.panelPresentation.title) { _, _ in
            if model.panelPresentation.primaryAction == .none {
                showsDetails = true
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
                AppWindowController.shared.showSettings(model: model)
            } label: {
                Label("Settings…", systemImage: "gearshape")
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                model.quit()
            } label: {
                Label("Quit", systemImage: "power")
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Quit Barveil"))
        }
        .font(.callout)
        .padding(.horizontal, BarveilMetrics.contentPadding)
        .padding(.vertical, 9)
    }

    private func yesOrNo(_ value: Bool) -> String {
        preferences.localized(value ? "Yes" : "No")
    }
}

// MARK: - First run

private struct OnboardingPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Spacer(minLength: 14)

                Image(nsImage: BarveilIcon.app)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("A quieter full screen")
                        .font(.title2.weight(.semibold))
                    Text("Barveil gets the menu bar out of the way only while a video is playing full screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300)
                }

                VStack(spacing: 9) {
                    OnboardingFeature(
                        systemName: "play.rectangle",
                        title: "Only during playback",
                        message: "Windowed video and ordinary full-screen windows are left alone.",
                    )
                    OnboardingFeature(
                        systemName: "arrow.uturn.backward.circle",
                        title: "Returns automatically",
                        message: "Pause playback or leave full screen and your menu bar comes back.",
                    )
                    OnboardingFeature(
                        systemName: "lock.shield",
                        title: "Stays on this Mac",
                        message: "No account, no analytics, and no network access.",
                    )
                }
                .padding(.top, 2)

                BarveilActionButton(.prominent, controlSize: .large) {
                    preferences.isEnabled = true
                    preferences.hasCompletedOnboarding = true
                    if !model.accessibilityTrusted {
                        model.beginAccessibilitySetup()
                    }
                } label: {
                    Text("Get Started")
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OnboardingFeature: View {
    let systemName: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    var body: some View {
        BarveilSurface(padding: 11) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }
}
