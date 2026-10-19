//
//  Page.swift
//  TamioDesign
//
//  Page headers, empty states, code surfaces, tables, sheets and the progress HUD.
//

import SwiftUI

// MARK: - Page header

/// Page title plus an optional one-line subtitle.
public struct PageTitle: View {
    let title: Text
    let subtitle: Text?

    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
    }

    public init<Sub: StringProtocol>(_ title: LocalizedStringKey, subtitle: Sub?) {
        self.title = Text(title)
        self.subtitle = subtitle.flatMap { $0.isEmpty ? nil : Text(verbatim: String($0)) }
    }

    public init<S: StringProtocol>(_ title: S, subtitle: String? = nil) {
        self.title = Text(verbatim: String(title))
        self.subtitle = subtitle.flatMap { $0.isEmpty ? nil : Text(verbatim: $0) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s1) {
            title
                .font(.rxPageTitle)
                .tracking(-0.26)
                .foregroundStyle(.rxInk)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                subtitle
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty state

/// What a list shows when empty: icon, heading, one sentence, the one fixing action.
public struct EmptyStateView: View {
    let systemImage: String
    let title: Text
    let message: Text?
    let actionTitle: Text?
    let action: (() -> Void)?

    public init(
        _ title: LocalizedStringKey,
        systemImage: String,
        message: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.message = message.map { Text($0) }
        self.actionTitle = actionTitle.map { Text($0) }
        self.action = action
    }

    public init<M: StringProtocol>(
        _ title: LocalizedStringKey,
        systemImage: String,
        message: M,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.message = message.isEmpty ? nil : Text(verbatim: String(message))
        self.actionTitle = actionTitle.map { Text($0) }
        self.action = action
    }

    public init<M: StringProtocol, A: StringProtocol>(
        _ title: LocalizedStringKey,
        systemImage: String,
        message: M,
        actionTitle: A?,
        action: (() -> Void)? = nil
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.message = message.isEmpty ? nil : Text(verbatim: String(message))
        self.actionTitle = actionTitle.flatMap { $0.isEmpty ? nil : Text(verbatim: String($0)) }
        self.action = action
    }

    public init<S: StringProtocol>(
        _ title: S,
        systemImage: String,
        message: String = "",
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = Text(verbatim: String(title))
        self.systemImage = systemImage
        self.message = message.isEmpty ? nil : Text(verbatim: message)
        self.actionTitle = actionTitle.flatMap { $0.isEmpty ? nil : Text(verbatim: $0) }
        self.action = action
    }

    public var body: some View {
        VStack(spacing: RX.Space.s3) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.rxInkSecondary)
                .frame(height: 36)
                .rxPop()
            title
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.rxInk)
            if let message {
                message
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let actionTitle, let action {
                Button(action: action) { actionTitle }
                    .buttonStyle(.rxPrimary)
                    .padding(.top, RX.Space.s1)
            }
        }
        .padding(RX.Space.s6)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Code

/// Commands and snippet bodies on `terminal-bg`, so they always look like the terminal.
public struct CodeBlock: View {
    let code: String
    let lineLimit: Int?

    public init(_ code: String, lineLimit: Int? = nil) {
        self.code = code
        self.lineLimit = lineLimit
    }

    public var body: some View {
        Text(verbatim: code.isEmpty ? " " : code)
            .font(.rxCode)
            .foregroundStyle(.rxTerminalForeground)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                    .fill(Color.rxTerminalBackground)
            )
            .textSelection(.enabled)
    }
}

// MARK: - Tables

/// A column caption in a table header.
public struct TableHeaderLabel: View {
    let label: CapsLabel
    let alignment: Alignment

    public init(_ text: LocalizedStringKey, alignment: Alignment = .leading) {
        self.label = CapsLabel(text)
        self.alignment = alignment
    }

    public init<S: StringProtocol>(_ text: S, alignment: Alignment = .leading) {
        self.label = CapsLabel(text)
        self.alignment = alignment
    }

    public var body: some View {
        label
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// A group row inside a table.
public struct TableGroupRow: View {
    let title: Text
    let trailing: String?

    public init(_ title: LocalizedStringKey, trailing: String? = nil) {
        self.title = Text(title)
        self.trailing = trailing
    }

    public init<S: StringProtocol>(_ title: S, trailing: String? = nil) {
        self.title = Text(verbatim: String(title))
        self.trailing = trailing
    }

    public var body: some View {
        HStack {
            title
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.rxInkSecondary)
            Spacer()
            if let trailing {
                Text(verbatim: trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.rxInkSecondary)
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .padding(.top, RX.Space.s3)
        .padding(.bottom, 6)
    }
}

public extension View {
    /// Row chrome: `row-selected` with rounded ends, `row-hover` on hover.
    func rxRowBackground(selected: Bool, hovered: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                .fill(selected ? Color.rxRowSelected : (hovered ? Color.rxRowHover : Color.clear))
                .animation(.rxQuick, value: hovered)
                .animation(.rxQuick, value: selected)
        )
    }
}

// MARK: - Sheets

/// The standard sheet: title, one-line lead, body, then a footer of actions.
public struct SheetScaffold<Content: View, Footer: View>: View {
    let title: Text
    let lead: Text?
    let content: Content
    let footer: Footer

    public init(_ title: LocalizedStringKey, lead: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = Text(title)
        self.lead = lead.map { Text($0) }
        self.content = content()
        self.footer = footer()
    }

    public init<L: StringProtocol>(_ title: LocalizedStringKey, lead: L?, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = Text(title)
        self.lead = lead.flatMap { $0.isEmpty ? nil : Text(verbatim: String($0)) }
        self.content = content()
        self.footer = footer()
    }

    public init<S: StringProtocol>(_ title: S, lead: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = Text(verbatim: String(title))
        self.lead = lead.flatMap { $0.isEmpty ? nil : Text(verbatim: $0) }
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: RX.Space.s1) {
                title
                    .font(.rxSheetTitle)
                    .foregroundStyle(.rxInk)
                if let lead {
                    lead
                        .font(.rxBody)
                        .foregroundStyle(.rxInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, RX.Space.s5)
            content
            HStack(spacing: RX.Space.s2) {
                footer
            }
            .padding(.top, RX.Space.s5)
        }
        .padding(RX.Space.s6)
    }
}

// MARK: - Progress

/// Blocking "Operation in progress" HUD over a `scrim`.
public struct ProgressHUD: View {
    let text: Text

    public init(_ text: LocalizedStringKey = "Working…") {
        self.text = Text(text)
    }

    public init<S: StringProtocol>(_ text: S) {
        self.text = Text(verbatim: String(text))
    }

    public var body: some View {
        ZStack {
            Color.rxScrim.ignoresSafeArea()
            VStack(spacing: RX.Space.s3) {
                ProgressView()
                    .rxSpinner()
                text
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
            }
            .padding(.horizontal, RX.Space.s6)
            .padding(.vertical, RX.Space.s5)
            .frame(minWidth: 200)
            .background(RXCardBackground())
        }
        .accessibilityElement(children: .combine)
    }
}

/// A running transfer: file and direction, done/total, speed, a 4pt bar and Cancel.
public struct ProgressRowView: View {
    let title: String
    let detail: String
    let fraction: Double?
    let cancel: (() -> Void)?

    public init(title: String, detail: String, fraction: Double?, cancel: (() -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.fraction = fraction
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            HStack(spacing: RX.Space.s2) {
                Text(verbatim: title)
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: RX.Space.s2)
                Text(verbatim: detail)
                    .font(.rxBody.monospacedDigit())
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
                if let cancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.rx(size: .small))
                }
            }
            if let fraction {
                RXProgressBar(fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.rxAccent)
            }
        }
    }
}

// MARK: - Layout helpers

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

public extension View {
    /// Writes the view's width into a binding, for tables that drop columns when narrow.
    func readWidth(_ width: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(WidthKey.self) { value in
            if abs(width.wrappedValue - value) > 0.5 { width.wrappedValue = value }
        }
    }
}
