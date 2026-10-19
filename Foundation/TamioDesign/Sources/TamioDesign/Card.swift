//
//  Card.swift
//  TamioDesign
//

import SwiftUI

/// A card on the window: solid `surface`, a hairline edge and a soft shadow.
/// Content is never glass; that is for the controls floating above it.
struct RXCardBackground: View {
    var radius: CGFloat = RX.Radius.card
    var fill: Color = .rxSurface
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(fill)
            .overlay(shape.strokeBorder(Color.rxHairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 8, x: 0, y: 3)
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

    init<S: StringProtocol>(_ title: S) {
        self.init(title) { EmptyView() }
    }
}

/// Small scale or source hint (`axis` style, `ink-tertiary`).
public struct HintText: View {
    let text: Text
    public init(_ text: LocalizedStringKey) { self.text = Text(text) }
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
