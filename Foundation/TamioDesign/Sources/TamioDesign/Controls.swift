//
//  Controls.swift
//  TamioDesign
//
//  Buttons, segmented controls, text fields and search fields. Every control is 28pt tall.
//

import SwiftUI

// MARK: - Buttons

public struct RXButtonStyle: ButtonStyle {
    public enum Kind {
        /// `surface` fill, 1px `control-border`.
        case bordered
        /// `accent` fill; one per view at most.
        case primary
        /// Destructive confirmation only.
        case danger
        /// Toolbar text actions.
        case plain
    }

    public enum Size {
        case regular
        case small
    }

    let kind: Kind
    let size: Size
    let iconOnly: Bool

    public init(_ kind: Kind = .bordered, size: Size = .regular, iconOnly: Bool = false) {
        self.kind = kind
        self.size = size
        self.iconOnly = iconOnly
    }

    public func makeBody(configuration: Configuration) -> some View {
        RXButtonBody(configuration: configuration, kind: kind, size: size, iconOnly: iconOnly)
    }
}

private struct RXButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: RXButtonStyle.Kind
    let size: RXButtonStyle.Size
    let iconOnly: Bool

    @Environment(\.isEnabled) private var isEnabled

    var height: CGFloat { size == .small ? RX.smallControlHeight : RX.controlHeight }

    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(size == .small ? .system(size: 12, weight: weight) : .system(size: 13, weight: weight))
            .labelStyle(RXButtonLabelStyle(iconOnly: iconOnly))
            .lineLimit(1)
            // A button keeps its whole title on one line; the row around it
            // gives way instead.
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 0 : (kind == .plain ? 8 : (size == .small ? 10 : 14)))
            .frame(width: iconOnly ? height : nil, height: height)
            .background(background)
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.rxQuick, value: configuration.isPressed)
            .animation(.rxQuick, value: hovered)
            #if os(macOS) || targetEnvironment(macCatalyst)
            .onHover { hovered = $0 }
            #endif
    }

    var weight: Font.Weight {
        kind == .primary || kind == .danger ? .semibold : .medium
    }

    var foreground: Color {
        switch kind {
        case .bordered: return .rxInk
        case .primary: return .rxOnAccent
        case .danger: return .white
        case .plain: return hovered && isEnabled ? .rxInk : .rxInkSecondary
        }
    }

    /// Capsules with fills only: Liquid Glass controls carry no outline.
    @ViewBuilder var background: some View {
        let shape = Capsule()
        switch kind {
        case .bordered:
            shape.fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovered && isEnabled ? 0.11 : 0.07)))
        case .primary:
            shape.fill(Color.rxAccent.opacity(configuration.isPressed ? 0.85 : 1))
                .shadow(color: Color.rxAccent.opacity(0.25), radius: 6, y: 2)
        case .danger:
            shape.fill(Color.rxDanger.opacity(configuration.isPressed ? 0.85 : 1))
        case .plain:
            shape.fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovered && isEnabled ? 0.07 : 0)))
        }
    }
}

private struct RXButtonLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
                .font(.system(size: 14, weight: .regular))
        } else {
            HStack(spacing: 6) {
                configuration.icon
                    .font(.system(size: 13, weight: .regular))
                configuration.title
            }
        }
    }
}

public extension ButtonStyle where Self == RXButtonStyle {
    /// Bordered 28pt button.
    static var rx: RXButtonStyle { RXButtonStyle() }
    /// The one primary action of a view.
    static var rxPrimary: RXButtonStyle { RXButtonStyle(.primary) }
    static var rxDanger: RXButtonStyle { RXButtonStyle(.danger) }
    static var rxPlain: RXButtonStyle { RXButtonStyle(.plain) }

    static func rx(_ kind: RXButtonStyle.Kind = .bordered, size: RXButtonStyle.Size = .regular, iconOnly: Bool = false) -> RXButtonStyle {
        RXButtonStyle(kind, size: size, iconOnly: iconOnly)
    }
}

/// Icon-only 28×28 button with an accessible label and tooltip.
public struct RXIconButton: View {
    enum Title {
        case key(LocalizedStringKey)
        case verbatim(String)
    }

    let title: Title
    let systemImage: String
    let kind: RXButtonStyle.Kind
    let size: RXButtonStyle.Size
    let action: () -> Void

    public init(
        _ title: LocalizedStringKey,
        systemImage: String,
        kind: RXButtonStyle.Kind = .bordered,
        size: RXButtonStyle.Size = .regular,
        action: @escaping () -> Void
    ) {
        self.title = .key(title)
        self.systemImage = systemImage
        self.kind = kind
        self.size = size
        self.action = action
    }

    public init<S: StringProtocol>(
        _ title: S,
        systemImage: String,
        kind: RXButtonStyle.Kind = .bordered,
        size: RXButtonStyle.Size = .regular,
        action: @escaping () -> Void
    ) {
        self.title = .verbatim(String(title))
        self.systemImage = systemImage
        self.kind = kind
        self.size = size
        self.action = action
    }

    public var body: some View {
        switch title {
        case let .key(key):
            Button(action: action) {
                Label(key, systemImage: systemImage)
            }
            .buttonStyle(RXButtonStyle(kind, size: size, iconOnly: true))
            .help(key)
            .accessibilityLabel(key)
        case let .verbatim(text):
            Button(action: action) {
                Label(text, systemImage: systemImage)
            }
            .buttonStyle(RXButtonStyle(kind, size: size, iconOnly: true))
            .help(text)
            .accessibilityLabel(text)
        }
    }
}

// MARK: - Segmented control

/// Two to four mutually exclusive options on a `surface-sunken` track.
/// Caps labels for toolbar and card filters, sentence case (`caps: false`) in settings rows.
public struct RXSegmented<Value: Hashable>: View {
    public struct Option {
        let value: Value
        let title: Text
        let systemImage: String?

        public init(_ value: Value, _ title: LocalizedStringKey, systemImage: String? = nil) {
            self.value = value
            self.title = Text(title)
            self.systemImage = systemImage
        }

        public init<S: StringProtocol>(_ value: Value, _ title: S, systemImage: String? = nil) {
            self.value = value
            self.title = Text(verbatim: String(title))
            self.systemImage = systemImage
        }
    }

    @Binding var selection: Value
    let options: [Option]
    let caps: Bool
    let fullWidth: Bool

    public init(selection: Binding<Value>, options: [Option], caps: Bool = true, fullWidth: Bool = false) {
        _selection = selection
        self.options = options
        self.caps = caps
        self.fullWidth = fullWidth
    }

    #if targetEnvironment(macCatalyst)
        @Environment(\.rxControlsAtRest) private var atRest
        @Namespace private var pill

        // UIKit's segmented control is a full-width grey capsule; the Mac one is
        // a compact track of equal segments with the selection in the accent colour.
        public var body: some View {
            RXEqualWidths {
                ForEach(options.indices, id: \.self) { index in
                    segment(index)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(atRest ? 0.088 : 0.07))
            )
            .fixedSize()
            .frame(maxWidth: fullWidth ? .infinity : nil)
            // The selection slides to the segment that was clicked.
            .animation(.rxMove, value: selection)
            .accessibilityElement(children: .contain)
        }

        private func segment(_ index: Int) -> some View {
            let option = options[index]
            let isSelected = option.value == selection
            // A hairline separates two neighbours when neither is the selection.
            let separated = index + 1 < options.count && !isSelected && options[index + 1].value != selection
            return HStack(spacing: 4) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage)
                }
                option.title
            }
            .font(.system(size: 13))
            .foregroundStyle(isSelected && !atRest ? Color.white : Color.primary.opacity(isSelected || atRest ? 1 : 0.85))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(atRest ? Color.primary.opacity(0.142) : Color.rxAccent)
                        .matchedGeometryEffect(id: "selection", in: pill)
                }
            }
            .overlay(alignment: .trailing) {
                if separated {
                    Rectangle()
                        .fill(Color.primary.opacity(0.26))
                        .frame(width: 1, height: 14)
                        .offset(x: 0.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = option.value }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }
    #else
        public var body: some View {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    if let systemImage = option.systemImage {
                        Label { option.title } icon: { Image(systemName: systemImage) }.tag(option.value)
                    } else {
                        option.title.tag(option.value)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .fixedSize(horizontal: !fullWidth, vertical: false)
        }
    #endif
}

#if targetEnvironment(macCatalyst)
    /// Lays its subviews in a row, each as wide as the widest.
    struct RXEqualWidths: Layout {
        func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let width = sizes.map(\.width).max() ?? 0
            return CGSize(width: width * CGFloat(subviews.count), height: sizes.map(\.height).max() ?? 0)
        }

        func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
            let width = bounds.width / CGFloat(max(subviews.count, 1))
            for (index, subview) in subviews.enumerated() {
                subview.place(
                    at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                    proposal: ProposedViewSize(width: width, height: bounds.height)
                )
            }
        }
    }
#endif

// MARK: - Text fields

/// 28pt field: `surface` fill, 1px `control-border`, `radius-md`.
public struct RXTextFieldStyle: TextFieldStyle {
    let monospaced: Bool

    public init(monospaced: Bool = false) {
        self.monospaced = monospaced
    }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(monospaced ? .rxCode : .rxBody)
            .foregroundStyle(.rxInk)
            .padding(.horizontal, 8)
            .frame(height: RX.controlHeight)
            .rxFieldBackground()
    }
}

public extension TextFieldStyle where Self == RXTextFieldStyle {
    static var rx: RXTextFieldStyle { RXTextFieldStyle() }
    static var rxMono: RXTextFieldStyle { RXTextFieldStyle(monospaced: true) }
}

public extension View {
    /// The field chrome used by text fields, pop-ups and editors.
    func rxFieldBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

/// Caption label above a field, optional help or error underneath.
public struct RXField<Content: View>: View {
    let label: CapsLabel
    let help: HelpText?
    let error: HelpText?
    let content: Content

    public init(_ label: LocalizedStringKey, help: LocalizedStringKey? = nil, error: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.label = CapsLabel(label)
        self.help = help.map { HelpText($0) }
        self.error = error.map { HelpText($0, isError: true) }
        self.content = content()
    }

    public init<H: StringProtocol>(_ label: LocalizedStringKey, help: H?, error: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = CapsLabel(label)
        self.help = help.flatMap { $0.isEmpty ? nil : HelpText($0) }
        self.error = error.flatMap { $0.isEmpty ? nil : HelpText($0, isError: true) }
        self.content = content()
    }

    public init<E: StringProtocol>(_ label: LocalizedStringKey, error: E?, @ViewBuilder content: () -> Content) {
        self.label = CapsLabel(label)
        self.help = nil
        self.error = error.flatMap { $0.isEmpty ? nil : HelpText($0, isError: true) }
        self.content = content()
    }

    public init<S: StringProtocol>(_ label: S, help: String? = nil, error: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = CapsLabel(label)
        self.help = help.flatMap { $0.isEmpty ? nil : HelpText($0) }
        self.error = error.flatMap { $0.isEmpty ? nil : HelpText($0, isError: true) }
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            label
            content
            if let error {
                error
            } else if let help {
                help
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A read-only value drawn like a field.
public struct RXValueField: View {
    let text: String
    let placeholder: Text
    let monospaced: Bool

    public init(_ text: String, placeholder: LocalizedStringKey = "", monospaced: Bool = false) {
        self.text = text
        self.placeholder = Text(placeholder)
        self.monospaced = monospaced
    }

    public init<P: StringProtocol>(_ text: String, placeholder: P, monospaced: Bool = false) {
        self.text = text
        self.placeholder = Text(verbatim: String(placeholder))
        self.monospaced = monospaced
    }

    public var body: some View {
        (text.isEmpty ? placeholder : Text(verbatim: text))
            .font(monospaced ? .rxCode : .rxBody)
            .foregroundStyle(text.isEmpty ? Color.rxInkSecondary : Color.rxInk)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: RX.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .textSelection(.enabled)
    }
}

/// A 28pt filter field at the left of a toolbar. Filters the current list live.
public struct RXSearchField: View {
    let prompt: Text
    @Binding var text: String
    let width: CGFloat?

    public init(_ prompt: LocalizedStringKey, text: Binding<String>, width: CGFloat? = 220) {
        self.prompt = Text(prompt)
        _text = text
        self.width = width
    }

    public init<S: StringProtocol>(_ prompt: S, text: Binding<String>, width: CGFloat? = 220) {
        self.prompt = Text(verbatim: String(prompt))
        _text = text
        self.width = width
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.rxInkSecondary)
            TextField(text: $text, prompt: prompt) { prompt }
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.rxBody)
                .disableAutocorrection(true)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.rxInkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: RX.controlHeight)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Button groups

public struct RXGroupedButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        RXGroupedButtonBody(configuration: configuration)
    }
}

private struct RXGroupedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13))
            .foregroundStyle(.rxInk)
            .frame(minWidth: RX.controlHeight + 4, maxHeight: .infinity)
            .padding(.horizontal, 2)
            .background(configuration.isPressed ? Color.rxSurfaceSunken : Color.clear)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Pop-up field

/// A pop-up drawn as a 28pt field with a chevron, for choices inside forms and sheets.
public struct RXPicker<Value: Hashable>: View {
    public struct Option {
        let value: Value
        let title: Text

        public init(_ value: Value, _ title: LocalizedStringKey) {
            self.value = value
            self.title = Text(title)
        }

        public init<S: StringProtocol>(_ value: Value, _ title: S) {
            self.value = value
            self.title = Text(verbatim: String(title))
        }
    }

    @Binding var selection: Value
    let options: [Option]
    let placeholder: Text

    public init(selection: Binding<Value>, options: [Option], placeholder: LocalizedStringKey = "Choose…") {
        _selection = selection
        self.options = options
        self.placeholder = Text(placeholder)
    }

    public init<S: StringProtocol>(selection: Binding<Value>, options: [Option], placeholder: S) {
        _selection = selection
        self.options = options
        self.placeholder = Text(verbatim: String(placeholder))
    }

    var title: Text {
        options.first { $0.value == selection }?.title ?? placeholder
    }

    public var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    options[index].title.tag(options[index].value)
                }
            } label: {
                placeholder
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                title
                    .font(.rxBody)
                    .foregroundStyle(options.contains { $0.value == selection } ? Color.rxInk : Color.rxInkSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.rxInkSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: RX.controlHeight)
            .frame(maxWidth: .infinity)
            .rxFieldBackground()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

// MARK: - Liquid Glass actions

public extension View {
    /// The one primary action of a view: Liquid Glass prominent on macOS 26 / iOS 26,
    /// a prominent bordered capsule before that.
    @ViewBuilder
    func rxPrimaryAction() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(.rxAccent)
        } else {
            buttonStyle(.borderedProminent).tint(.rxAccent)
        }
    }

}
