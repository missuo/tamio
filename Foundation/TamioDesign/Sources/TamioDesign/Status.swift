//
//  Status.swift
//  TamioDesign
//

import SwiftUI

/// Connection and work states. Never show a dot without a word.
public enum RXStatus: Equatable {
    /// Connected, online, done.
    case success
    /// Connecting, running, refreshing.
    case running
    /// High load, reconnecting.
    case warning
    /// Offline, failed.
    case danger
    /// Off, stopped, not monitored.
    case off

    public var color: Color {
        switch self {
        case .success: return .rxSuccess
        case .running: return .rxAccent
        case .warning: return .rxWarning
        case .danger: return .rxDanger
        case .off: return .rxInkTertiary
        }
    }
}

public struct StatusDot: View {
    public enum Size {
        case small
        case regular
        case large
    }

    let status: RXStatus
    let size: Size

    public init(_ status: RXStatus, size: Size = .regular) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        let diameter: CGFloat = size == .small ? 6 : size == .regular ? 8 : 14
        Circle()
            .fill(status.color)
            .frame(width: diameter, height: diameter)
            .background {
                if size == .large, status == .success {
                    Circle()
                        .fill(Color.rxSuccessHalo)
                        .frame(width: diameter + 12, height: diameter + 12)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Small label for groups, orientation, auth type.
public struct RXTag: View {
    public enum Style {
        case neutral
        case accent
        case warning
    }

    let text: Text
    let systemImage: String?
    let style: Style

    public init(_ text: LocalizedStringKey, systemImage: String? = nil, style: Style = .neutral) {
        self.text = Text(text)
        self.systemImage = systemImage
        self.style = style
    }

    public init<S: StringProtocol>(_ text: S, systemImage: String? = nil, style: Style = .neutral) {
        self.text = Text(verbatim: String(text))
        self.systemImage = systemImage
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            text
                .font(.rxCaption)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.sm, style: .continuous)
                .fill(style == .accent ? Color.rxAccentFill : Color.rxSurfaceSunken)
        )
    }

    private var foreground: Color {
        switch style {
        case .neutral: return .rxInkSecondary
        case .accent: return .rxAccent
        case .warning: return .rxWarning
        }
    }
}

/// Screen-sharing redaction: the text becomes a `surface-sunken` bar its own length.
public struct RedactableText: View {
    let text: String
    let redacted: Bool

    public init(_ text: String, redacted: Bool) {
        self.text = text
        self.redacted = redacted
    }

    public var body: some View {
        Text(verbatim: text)
            .opacity(redacted ? 0 : 1)
            .overlay(alignment: .leading) {
                if redacted {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.rxSurfaceSunken)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Color.rxHairline, lineWidth: 1)
                        )
                        .frame(height: 10)
                        .accessibilityLabel("Hidden")
                }
            }
            .animation(.easeOut(duration: 0.2), value: redacted)
    }
}

/// An SF Symbol on a soft tile, for items that carry their own symbol (snippets, recents).
public struct SymbolTile: View {
    let systemImage: String
    let size: CGFloat
    let tinted: Bool

    public init(_ systemImage: String, size: CGFloat = 28, tinted: Bool = true) {
        self.systemImage = systemImage
        self.size = size
        self.tinted = tinted
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size >= 28 ? RX.Radius.lg : 6, style: .continuous)
            .fill(tinted ? Color.rxAccentFill : Color.rxSurfaceSunken)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .regular))
                    .foregroundStyle(tinted ? Color.rxAccent : Color.rxInkSecondary)
            )
            .accessibilityHidden(true)
    }
}
