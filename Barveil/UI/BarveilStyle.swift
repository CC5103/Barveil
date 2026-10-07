// Shared visual language for Barveil.
//
// macOS 26/27 uses Liquid Glass for controls and layered surfaces. Older
// systems fall back to native materials. Decorative colour is intentionally
// reduced to one system accent; orange/red are reserved for warnings.

import AppKit
import SwiftUI

enum BarveilMetrics {
    static let popoverWidth: CGFloat = 376
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 12
    static let contentPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
}

enum BarveilColor {
    static var systemAccent: Color {
        Color(nsColor: .controlAccentColor)
    }
}

enum BarveilTone: Equatable {
    case active
    case ready
    case waiting
    case warning
    case inactive

    /// One accent keeps the interface calm. Amber is the only extra colour,
    /// and appears only when the user has something to resolve.
    var tint: Color {
        switch self {
        case .active, .ready: BarveilColor.systemAccent
        case .waiting, .inactive: .secondary
        case .warning: .orange
        }
    }
}

/// Loads the icon from the app bundle instead of asking LaunchServices for
/// `NSApp.applicationIconImage`. The latter can keep serving a cached icon
/// after the asset catalog changes.
enum BarveilIcon {
    static let app: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSApp.applicationIconImage
    }()
}

/// A native glass surface on macOS 26+, and a quiet system material on older
/// systems. No custom gradient or decorative tint is applied.
struct BarveilSurface<Content: View>: View {
    var padding: CGFloat
    var cornerRadius: CGFloat
    var interactive: Bool
    let content: Content

    init(
        padding: CGFloat = 14,
        cornerRadius: CGFloat = BarveilMetrics.cardRadius,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content,
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                )
        } else {
            content
                .padding(padding)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.5)
                }
        }
    }
}

/// A native compact control on macOS 26+, with the system bordered styles on
/// macOS 14. This avoids baking a bespoke button appearance into the app.
struct BarveilActionButton<Label: View>: View {
    enum Kind {
        case prominent
        case standard
    }

    let kind: Kind
    let action: () -> Void
    var tint: Color?
    var isEnabled = true
    var controlSize: ControlSize = .regular
    let label: Label

    init(
        _ kind: Kind,
        tint: Color? = nil,
        isEnabled: Bool = true,
        controlSize: ControlSize = .regular,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label,
    ) {
        self.kind = kind
        self.tint = tint
        self.isEnabled = isEnabled
        self.controlSize = controlSize
        self.action = action
        self.label = label()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            switch kind {
            case .prominent:
                Button(action: action) { label }
                    .buttonStyle(.glassProminent)
            case .standard:
                Button(action: action) { label }
                    .buttonStyle(.glass)
            }
        } else {
            switch kind {
            case .prominent:
                Button(action: action) { label }
                    .buttonStyle(.borderedProminent)
            case .standard:
                Button(action: action) { label }
                    .buttonStyle(.bordered)
            }
        }
    }
}

struct BarveilIconBadge: View {
    let systemName: String
    let tone: BarveilTone
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .fill(tone == .warning ? tone.tint.opacity(0.13) : Color.primary.opacity(0.055))
            Image(systemName: systemName)
                .font(.system(size: size * 0.41, weight: .medium))
                .foregroundStyle(tone.tint)
                .symbolRenderingMode(.monochrome)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A compact label/value row used in disclosure areas and settings summaries.
struct BarveilDetailRow: View {
    let systemName: String
    let label: LocalizedStringResource
    let value: String
    var tone: BarveilTone = .inactive
    var showsStateIcon = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tone == .inactive ? Color.secondary : tone.tint)
                .frame(width: 17)
                .accessibilityHidden(true)

            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 10)

            if showsStateIcon {
                Image(systemName: tone == .ready || tone == .active ? "checkmark.circle.fill" : "minus.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone == .ready || tone == .active ? tone.tint : Color.secondary)
                    .accessibilityHidden(true)
            }

            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(tone == .inactive ? Color.primary : tone.tint)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A neutral glass message with one or two actions. The tone only colours a
/// narrow leading rule and the icon; the surface itself stays neutral.
struct BarveilCallout<Actions: View>: View {
    let systemName: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let tone: BarveilTone
    let actions: Actions

    init(
        systemName: String,
        title: LocalizedStringResource,
        message: LocalizedStringResource,
        tone: BarveilTone,
        @ViewBuilder actions: () -> Actions,
    ) {
        self.systemName = systemName
        self.title = title
        self.message = message
        self.tone = tone
        self.actions = actions()
    }

    var body: some View {
        BarveilSurface(padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    BarveilIconBadge(systemName: systemName, tone: tone, size: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                actions
                    .controlSize(.small)
            }
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(tone.tint.opacity(tone == .warning ? 0.72 : 0.36))
                .frame(width: 2)
                .padding(.vertical, 14)
                .padding(.leading, 1)
                .accessibilityHidden(true)
        }
    }
}

struct AppBundleIcon: View {
    let bundleID: String?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image = Self.image(for: bundleID) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func image(for bundleID: String?) -> NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
