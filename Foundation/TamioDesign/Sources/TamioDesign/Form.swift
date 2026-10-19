//
//  Form.swift
//  TamioDesign
//
//  Grouped settings forms: caps group label above a `surface` card whose rows are
//  separated by `hairline` dividers.
//

import SwiftUI

/// Stacks its children with a divider between each pair.
public struct RXDividedStack<Content: View>: View {
    let inset: CGFloat
    let content: Content

    public init(inset: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.inset = inset
        self.content = content()
    }

    public var body: some View {
        _VariadicView.Tree(DividedLayout(inset: inset)) {
            content
        }
    }

    private struct DividedLayout: _VariadicView_MultiViewRoot {
        let inset: CGFloat

        @ViewBuilder
        func body(children: _VariadicView.Children) -> some View {
            let last = children.last?.id
            VStack(spacing: 0) {
                ForEach(children) { child in
                    child
                    if child.id != last {
                        Hairline().padding(.leading, inset)
                    }
                }
            }
        }
    }
}

/// A settings row: title and one-sentence description, control right-aligned.
public struct RXFormRow<Control: View>: View {
    let title: Text
    let description: HelpText?
    let alignTop: Bool
    let control: Control

    public init(_ title: LocalizedStringKey, description: LocalizedStringKey? = nil, alignTop: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = Text(title)
        self.description = description.map { HelpText($0) }
        self.alignTop = alignTop
        self.control = control()
    }

    public init<D: StringProtocol>(_ title: LocalizedStringKey, description: D?, alignTop: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = Text(title)
        self.description = description.flatMap { $0.isEmpty ? nil : HelpText($0) }
        self.alignTop = alignTop
        self.control = control()
    }

    public init<S: StringProtocol>(_ title: S, description: LocalizedStringKey? = nil, alignTop: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = Text(verbatim: String(title))
        self.description = description.map { HelpText($0) }
        self.alignTop = alignTop
        self.control = control()
    }

    public init<S: StringProtocol, D: StringProtocol>(_ title: S, description: D?, alignTop: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = Text(verbatim: String(title))
        self.description = description.flatMap { $0.isEmpty ? nil : HelpText($0) }
        self.alignTop = alignTop
        self.control = control()
    }

    init(titleText: Text, description: HelpText?, alignTop: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = titleText
        self.description = description
        self.alignTop = alignTop
        self.control = control()
    }

    public var body: some View {
        RXRowLayout(alignTop: alignTop) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                if let description {
                    description
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, 10)
        .frame(minHeight: RX.formRowMinHeight)
    }
}

/// A row's label and its control: side by side while the label keeps at least
/// `minLabelWidth` and wraps to at most one line more than it would across the
/// whole row, else the control goes under the label. A wide control never
/// squeezes the title and description into a narrow column. The first subview
/// is the label, the second the control.
public struct RXRowLayout: Layout {
    public var alignTop: Bool
    public var spacing: CGFloat
    public var minLabelWidth: CGFloat

    public init(alignTop: Bool = false, spacing: CGFloat = RX.Space.s6, minLabelWidth: CGFloat = RX.rowMinLabelWidth) {
        self.alignTop = alignTop
        self.spacing = spacing
        self.minLabelWidth = minLabelWidth
    }

    /// A line of a description, with a little to spare.
    static let oneLine: CGFloat = 20

    public struct Cache {
        var control: CGSize?
    }

    public func makeCache(subviews: Subviews) -> Cache {
        Cache(control: subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified) : nil)
    }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    /// Where each part goes in `width`: the label's and the control's frames.
    private func arrange(_ width: CGFloat, subviews: Subviews, cache: Cache) -> (label: CGRect, control: CGRect?) {
        guard let label = subviews.first else { return (.zero, nil) }
        guard let ideal = cache.control, ideal.width > 0 || ideal.height > 0 else {
            let size = label.sizeThatFits(ProposedViewSize(width: width, height: nil))
            return (CGRect(x: 0, y: 0, width: width, height: size.height), nil)
        }
        let room = width - ideal.width - spacing
        let whole = label.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let size = room >= minLabelWidth ? label.sizeThatFits(ProposedViewSize(width: room, height: nil)) : nil
        if let size, size.height <= whole.height + Self.oneLine {
            let height = max(size.height, ideal.height)
            let labelY = alignTop ? 0 : (height - size.height) / 2
            let controlY = alignTop ? 0 : (height - ideal.height) / 2
            return (
                CGRect(x: 0, y: labelY, width: room, height: size.height),
                CGRect(x: width - ideal.width, y: controlY, width: ideal.width, height: ideal.height)
            )
        }
        let control = subviews[1].sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
        return (
            CGRect(x: 0, y: 0, width: width, height: whole.height),
            CGRect(x: 0, y: whole.height + RX.Space.s3, width: min(control.width, width), height: control.height)
        )
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let width = proposal.width, width.isFinite else {
            let label = subviews.first?.sizeThatFits(.unspecified) ?? .zero
            let control = cache.control ?? .zero
            return CGSize(width: label.width + (control.width > 0 ? spacing + control.width : 0), height: max(label.height, control.height))
        }
        let frames = arrange(width, subviews: subviews, cache: cache)
        return CGSize(width: width, height: max(frames.label.maxY, frames.control?.maxY ?? 0))
    }

    public func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let frames = arrange(bounds.width, subviews: subviews, cache: cache)
        subviews.first?.place(
            at: CGPoint(x: bounds.minX + frames.label.minX, y: bounds.minY + frames.label.minY),
            proposal: ProposedViewSize(frames.label.size)
        )
        if subviews.count > 1 {
            let control = frames.control ?? .zero
            subviews[1].place(
                at: CGPoint(x: bounds.minX + control.minX, y: bounds.minY + control.minY),
                proposal: ProposedViewSize(control.size)
            )
        }
    }
}

/// A boolean preference: title, description and a switch on the right.
public struct SwitchRow: View {
    let title: Text
    let description: HelpText?
    @Binding var isOn: Bool

    public init(_ title: LocalizedStringKey, description: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.title = Text(title)
        self.description = description.map { HelpText($0) }
        _isOn = isOn
    }

    public init<D: StringProtocol>(_ title: LocalizedStringKey, description: D?, isOn: Binding<Bool>) {
        self.title = Text(title)
        self.description = description.flatMap { $0.isEmpty ? nil : HelpText($0) }
        _isOn = isOn
    }

    public init<S: StringProtocol>(_ title: S, description: String? = nil, isOn: Binding<Bool>) {
        self.title = Text(verbatim: String(title))
        self.description = description.flatMap { $0.isEmpty ? nil : HelpText($0) }
        _isOn = isOn
    }

    public var body: some View {
        RXFormRow(titleText: title, description: description) {
            Toggle(isOn: $isOn) { title }
                .labelsHidden()
                .rxSwitchToggle()
                .tint(.rxAccent)
                #if os(macOS) || targetEnvironment(macCatalyst)
                .controlSize(.small)
                #endif
        }
    }
}

/// A bounded number: a continuous slider and a number field side by side. The
/// slider snaps to `step` without drawing tick marks and writes the binding once,
/// when the drag ends; the field takes an exact value (clamped to the range) on
/// Return or when it loses focus.
public struct RXSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String?
    @State private var draft: Double?
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, unit: String? = nil) {
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    private var current: Double { draft ?? value }

    /// Decimals shown in the field: as many as the step needs.
    private var decimals: Int {
        guard step > 0, step < 1 else { return 0 }
        var places = 0
        var scaled = step
        while places < 4, abs(scaled.rounded() - scaled) > 1e-9 {
            scaled *= 10
            places += 1
        }
        return places
    }

    private func format(_ number: Double) -> String {
        String(format: "%.\(decimals)f", number)
    }

    private func snap(_ raw: Double) -> Double {
        guard step > 0 else { return raw }
        let snapped = ((raw - range.lowerBound) / step).rounded() * step + range.lowerBound
        return clamp(snapped)
    }

    private func clamp(_ number: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, number))
    }

    private func commitText() {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: unit ?? "").union(.whitespaces))
        if let typed = Double(cleaned) {
            let next = clamp(typed)
            if next != value { value = next }
            text = format(next)
        } else {
            text = format(value)
        }
    }

    public var body: some View {
        HStack(spacing: RX.Space.s2) {
            Slider(
                value: Binding(get: { current }, set: { draft = snap($0); text = format(snap($0)) }),
                in: range
            ) { editing in
                guard !editing, let draft else { return }
                if draft != value { value = draft }
                self.draft = nil
            }
            .labelsHidden()
            .tint(.rxAccent)
            .frame(width: 180)
            #if os(macOS) || targetEnvironment(macCatalyst)
            .controlSize(.small)
            #endif
            TextField("Value", text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.rxBody.monospacedDigit())
                .textFieldStyle(.rx)
                .frame(width: 64)
                .focused($fieldFocused)
                .onSubmit(commitText)
                .onChange(of: fieldFocused) { focused in
                    if !focused { commitText() }
                }
            if let unit {
                Text(LocalizedStringKey(unit))
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
            }
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { newValue in
            if !fieldFocused { text = format(newValue) }
        }
    }
}

/// A right-aligned number field with an optional unit. The field is a draft
/// while typing; the value is written (clamped to the range) on Return or
/// when the field loses focus, so "25" can be typed inside 10...60.
public struct NumberFieldRow: View {
    let title: Text
    let description: HelpText?
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: Text?
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    public init(_ title: LocalizedStringKey, description: LocalizedStringKey? = nil, value: Binding<Int>, in range: ClosedRange<Int>, unit: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self.description = description.map { HelpText($0) }
        _value = value
        self.range = range
        self.unit = unit.map { Text($0) }
    }

    public init<S: StringProtocol>(_ title: S, description: String? = nil, value: Binding<Int>, in range: ClosedRange<Int>, unit: String? = nil) {
        self.title = Text(verbatim: String(title))
        self.description = description.flatMap { $0.isEmpty ? nil : HelpText($0) }
        _value = value
        self.range = range
        self.unit = unit.map { Text(verbatim: $0) }
    }

    private func commitText() {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        if let typed = Int(cleaned) {
            let next = min(range.upperBound, max(range.lowerBound, typed))
            if next != value { value = next }
            text = String(next)
        } else {
            text = String(value)
        }
    }

    public var body: some View {
        RXFormRow(titleText: title, description: description) {
            HStack(spacing: RX.Space.s2) {
                TextField(text: $text) { title }
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.rx)
                    .frame(width: 72)
                    .focused($fieldFocused)
                    .onSubmit(commitText)
                    .onChange(of: fieldFocused) { focused in
                        if !focused { commitText() }
                    }
                Stepper(value: $value, in: range) { title }
                    .labelsHidden()
                if let unit {
                    unit
                        .font(.rxBody)
                        .foregroundStyle(.rxInkSecondary)
                }
            }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { newValue in
            if !fieldFocused { text = String(newValue) }
        }
    }
}

/// Page-level section title with optional count and trailing controls.
public struct SectionTitle<Trailing: View>: View {
    let title: Text
    let count: Int?
    let trailing: Trailing

    public init(_ title: LocalizedStringKey, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.count = count
        self.trailing = trailing()
    }

    public init<S: StringProtocol>(_ title: S, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: String(title))
        self.count = count
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: RX.Space.s2) {
            title
                .font(.rxSectionTitle)
                .foregroundStyle(.rxInk)
            if let count {
                CapsLabel(String(count))
            }
            Spacer(minLength: 0)
            trailing
        }
        .frame(height: RX.controlHeight)
    }
}

public extension SectionTitle where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, count: Int? = nil) {
        self.init(title, count: count) { EmptyView() }
    }

    init<S: StringProtocol>(_ title: S, count: Int? = nil) {
        self.init(title, count: count) { EmptyView() }
    }
}
