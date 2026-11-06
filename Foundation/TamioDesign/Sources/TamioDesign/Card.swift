//
//  Card.swift
//  TamioDesign
//

import SwiftUI

/// A card on the window: solid `surface`, a hairline edge and a soft shadow;
/// with frosted glass on, a light tint over the window's blur with an edge
/// that catches the light, and no shadow, which would only muddy the tint.
public struct RXCardBackground: View {
    var radius: CGFloat = RX.Radius.card
    /// False for a card that floats over a scrim, which stays solid.
    var glassy = true

    public init(radius: CGFloat = RX.Radius.card, glassy: Bool = true) {
        self.radius = radius
        self.glassy = glassy
    }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rxGlass) private var glass

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if glass, glassy {
            shape
                .fill(RXPalette.glassSurface)
                .overlay(shape.strokeBorder(RXPalette.glassEdge, lineWidth: 0.5))
        } else {
            shape
                .fill(Color.rxSurface)
                .overlay(shape.strokeBorder(Color.rxHairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 8, x: 0, y: 3)
        }
    }
}

public extension View {
    /// Places the view on a `surface` card with `radius-card` and `shadow-card`.
    /// - Parameter padding: inner padding, `space-4` by default; pass 8 for flush lists.
    func rxCard(padding: CGFloat = RX.Space.s4) -> some View {
        self
            .padding(padding)
            .background(RXCardBackground())
    }

    /// Card chrome without inner padding, clipped to the card shape.
    func rxCardChrome(radius: CGFloat = RX.Radius.card) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(RXCardBackground(radius: radius))
    }
}

/// Uppercase `caption-caps` label in `ink-secondary`.
public struct CapsLabel: View {
    let text: Text
    var color: Color = .rxInkSecondary

    public init(_ text: LocalizedStringKey, color: Color = .rxInkSecondary) {
        self.text = Text(text)
        self.color = color
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ text: S, color: Color = .rxInkSecondary) {
        self.text = Text(verbatim: String(text))
        self.color = color
    }

    public var body: some View {
        text
            .textCase(.uppercase)
            .font(.rxCaption)
            .tracking(rxCapsTracking)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A card's head row: caption on the left, at most one control on the right.
public struct CardHead<Trailing: View>: View {
    let label: CapsLabel
    let trailing: Trailing

    public init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.label = CapsLabel(title)
        self.trailing = trailing()
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, @ViewBuilder trailing: () -> Trailing) {
        self.label = CapsLabel(title)
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: RX.Space.s2) {
            label
            Spacer(minLength: RX.Space.s2)
            trailing
        }
        .frame(minHeight: RX.controlHeight)
    }
}

public extension CardHead where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title) { EmptyView() }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S) {
        self.init(title) { EmptyView() }
    }
}

/// Small scale or source hint (`axis` style, `ink-tertiary`).
public struct HintText: View {
    let text: Text
    public init(_ text: LocalizedStringKey) { self.text = Text(text) }
    @_disfavoredOverload
    public init<S: StringProtocol>(_ text: S) { self.text = Text(verbatim: String(text)) }
    public var body: some View {
        text
            .font(.rxAxis)
            .foregroundStyle(.rxInkTertiary)
            .lineLimit(1)
    }
}

/// One-sentence help text (`ink-secondary`, 11pt); `danger` when `isError`.
public struct HelpText: View {
    let text: Text
    let isError: Bool
    public init(_ text: LocalizedStringKey, isError: Bool = false) {
        self.text = Text(text)
        self.isError = isError
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ text: S, isError: Bool = false) {
        self.text = Text(verbatim: String(text))
        self.isError = isError
    }

    public var body: some View {
        text
            .font(.rxHelp)
            .foregroundStyle(isError ? Color.rxDanger : Color.rxInkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 1px `hairline` divider.
public struct Hairline: View {
    let vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        Rectangle()
            .fill(Color.rxHairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Key-cap hint such as `⌘↩`.
public struct KeyHint: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.rxInkSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.rxSurfaceSunken))
    }
}
