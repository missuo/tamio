//
//  Tabs.swift
//  TamioDesign
//
//  A row of tabs in a track: Home's groups, a server's Terminal, Files and
//  Monitor. The track and the raised selection say it can be switched, as a
//  Mac segmented control does; the system's own lost its track in a toolbar
//  without Liquid Glass capsules and read as plain words.
//

import SwiftUI

public struct RXTabs<Value: Hashable>: View {
    public struct Option {
        let value: Value
        let title: Text
        let help: Text?
        let accessibilityLabel: Text?

        public init(_ value: Value, _ title: Text, help: Text? = nil, accessibilityLabel: Text? = nil) {
            self.value = value
            self.title = title
            self.help = help
            self.accessibilityLabel = accessibilityLabel
        }
    }

    let options: [Option]
    let selection: Value?
    let select: (Value) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ options: [Option], selection: Value?, select: @escaping (Value) -> Void) {
        self.options = options
        self.selection = selection
        self.select = select
    }

    public var body: some View {
        RXTabsLayout(selected: options.firstIndex { $0.value == selection }) {
            // First, so it is drawn under the tabs.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(RXPalette.tabSelected)
                .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                .accessibilityHidden(true)
            ForEach(options.indices, id: \.self) { index in
                RXTab(option: options[index], selected: options[index].value == selection) {
                    if options[index].value != selection { select(options[index].value) }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(RXPalette.tabTrack)
        )
        .fixedSize()
        .animation(reduceMotion ? nil : .rxMove, value: selection)
        .accessibilityElement(children: .contain)
    }
}

private struct RXTab<Value: Hashable>: View {
    let option: RXTabs<Value>.Option
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            option.title
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.rxInk : Color.rxInkSecondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minWidth: 52, minHeight: 24, maxHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovered && !selected ? 0.05 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.rxQuick, value: hovered)
        .modifier(OptionalHelp(text: option.help))
        .accessibilityLabel(option.accessibilityLabel ?? option.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct OptionalHelp: ViewModifier {
    let text: Text?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// The tabs side by side and the selection under the selected one, its first
/// subview. Placed here, in the control's own space, the selection slides
/// when it changes (SwiftUI animates placements) and does nothing when the
/// toolbar it sits in moves: a matched geometry effect followed its place in
/// the window, so at every frame of a sidebar slide the control was drawn
/// again and AppKit measured its toolbar item again.
struct RXTabsLayout: Layout {
    let selected: Int?

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let sizes = subviews.dropFirst().map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.map(\.width).reduce(0, +), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let selection = subviews.first else { return }
        var x = bounds.minX
        var frames: [CGRect] = []
        for tab in subviews.dropFirst() {
            let size = tab.sizeThatFits(.unspecified)
            let frame = CGRect(x: x, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            tab.place(at: frame.origin, proposal: ProposedViewSize(frame.size))
            frames.append(frame)
            x += size.width
        }
        if let selected, frames.indices.contains(selected) {
            selection.place(at: frames[selected].origin, proposal: ProposedViewSize(frames[selected].size))
        } else {
            selection.place(at: CGPoint(x: bounds.minX, y: bounds.midY), proposal: .zero)
        }
    }
}

extension RXPalette {
    /// The track of a row of tabs.
    static let tabTrack = Color(rxLight: 0x0000_000F, dark: 0xFFFF_FF12)
    /// The selected tab, raised off the track.
    static let tabSelected = Color(rxLight: 0xFFFF_FFFF, dark: 0xFFFF_FF2E)
}
