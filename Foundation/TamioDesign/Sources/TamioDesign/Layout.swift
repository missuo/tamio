//
//  Layout.swift
//  TamioDesign
//

import SwiftUI

#if os(macOS)
    import AppKit

    /// The translucent window backdrop: the desktop shows through, blurred.
    public struct RXWindowBackground: NSViewRepresentable {
        public init() {}

        public func makeNSView(context _: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .underWindowBackground
            view.blendingMode = .behindWindow
            view.state = .followsWindowActiveState
            return view
        }

        public func updateNSView(_: NSVisualEffectView, context _: Context) {}
    }

    /// Lets the user move a hidden-title-bar window by dragging empty chrome,
    /// and zoom it on double-click.
    public struct RXWindowDragArea: NSViewRepresentable {
        public init() {}

        public final class DragView: NSView {
            override public var mouseDownCanMoveWindow: Bool { true }

            override public func mouseDown(with event: NSEvent) {
                if event.clickCount == 2 {
                    window?.performZoom(nil)
                    return
                }
                window?.performDrag(with: event)
            }
        }

        public func makeNSView(context _: Context) -> NSView { DragView() }
        public func updateNSView(_: NSView, context _: Context) {}
    }

#elseif targetEnvironment(macCatalyst)
    import UIKit

    /// The window backdrop on Mac Catalyst. Content sits on the solid `window`
    /// colour: as Apple's guidance has it, only the controls and navigation
    /// that float above content are glass. With `material`, for a menu bar
    /// popover, the view is clear and the AppKit material shows through.
    /// Either way it keeps the UIKit views it sits in clear and hands its
    /// window to `install`, where the app puts the material underneath, for
    /// the sidebar.
    public struct RXWindowBackground: UIViewRepresentable {
        /// Called with every window a backdrop appears in.
        @MainActor public static var install: ((UIWindow) -> Void)?
        let material: Bool

        public init(material: Bool = false) {
            self.material = material
        }

        public final class ClearView: UIView {
            override public func didMoveToWindow() {
                super.didMoveToWindow()
                clearAncestors()
                if let window { RXWindowBackground.install?(window) }
            }

            override public func layoutSubviews() {
                super.layoutSubviews()
                clearAncestors()
            }

            override public func traitCollectionDidChange(_ previous: UITraitCollection?) {
                super.traitCollectionDidChange(previous)
                // Hosting views take their background colour back on a change
                // of appearance.
                DispatchQueue.main.async { [weak self] in self?.clearAncestors() }
            }

            private func clearAncestors() {
                var next = superview
                while let view = next {
                    if view.backgroundColor != .clear { view.backgroundColor = .clear }
                    view.isOpaque = false
                    next = view.superview
                }
            }
        }

        public func makeUIView(context _: Context) -> ClearView {
            let view = ClearView()
            view.backgroundColor = material ? .clear : UIColor(Color.rxWindow)
            view.isUserInteractionEnabled = false
            return view
        }

        public func updateUIView(_: ClearView, context _: Context) {}
    }
#endif

/// Wraps children onto new lines (toggle chips, tags).
public struct RXFlowLayout: Layout {
    let spacing: CGFloat
    let alignment: HorizontalAlignment

    public init(spacing: CGFloat = 6, alignment: HorizontalAlignment = .leading) {
        self.spacing = spacing
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - row.width
            case .center: x = bounds.minX + (bounds.width - row.width) / 2
            default: x = bounds.minX
            }
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Toggle chip used by feature lists.
public struct RXChip: View {
    let title: Text
    let isOn: Bool
    let action: () -> Void

    public init(_ title: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void) {
        self.title = Text(title)
        self.isOn = isOn
        self.action = action
    }

    public init<S: StringProtocol>(_ title: S, isOn: Bool, action: @escaping () -> Void) {
        self.title = Text(verbatim: String(title))
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.system(size: 9, weight: .bold))
                title
                    .font(.system(size: 12))
            }
            .foregroundStyle(isOn ? Color.rxAccent : Color.rxInk)
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .frame(height: 24)
            .background(
                Capsule().fill(isOn ? Color.rxAccentFill : Color.primary.opacity(0.06))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Lists

public extension View {
    /// Inset-grouped lists on `window`, rows on `surface` cards, `accent` tint.
    func rxGroupedList() -> some View {
        scrollContentBackground(.hidden)
            .background(RXBackdrop().ignoresSafeArea())
            .tint(.rxAccent)
    }

    /// A list row on a frosted `surface`.
    func rxListRow() -> some View {
        listRowBackground(Rectangle().fill(.regularMaterial))
    }
}

/// Caps section header for grouped lists.
public struct RXSectionHeader: View {
    let label: CapsLabel
    public init(_ title: LocalizedStringKey) { self.label = CapsLabel(title) }
    public init<S: StringProtocol>(_ title: S) { self.label = CapsLabel(title) }
    public var body: some View {
        label
            .textCase(nil)
    }
}

/// The page backdrop: the translucent window on the Mac; on iOS, where the desktop
/// cannot show through, a soft tinted gradient that the frosted cards blur.
public struct RXBackdrop: View {
    public init() {}

    public var body: some View {
        #if os(macOS) || targetEnvironment(macCatalyst)
            RXWindowBackground()
        #else
            ZStack {
                Color.rxWindow
                LinearGradient(
                    colors: [Color.rxAccent.opacity(0.10), .clear, Color.rxSeries2.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        #endif
    }
}
