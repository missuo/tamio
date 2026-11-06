//
//  AlignedWithContent.swift
//  Tamio (macOS)
//
//  A toolbar item at the toolbar's leading edge, lined up with the page's
//  content: Home's server groups, Snippets' groups.
//

import AppKit
import SwiftUI
import TamioDesign

/// What it shows starts where the page's content does, `margin` in from the
/// content's edge. The toolbar places the item after the sidebar button,
/// which with the sidebar open is over the sidebar, so it is moved along to
/// the content, and back to the button as the sidebar hides. The item keeps
/// one width (what it shows and the room it moves in) and only what is drawn
/// in it moves, so the toolbar is not laid out again at every frame of the
/// slide.
/// Where the toolbar put its leading item last, kept for the next page.
@MainActor
private enum ToolbarLeadingItem {
    static var origin: CGFloat?
}

struct AlignedWithContent<Content: View>: View {
    let margin: CGFloat
    @ViewBuilder let content: Content

    @ObservedObject private var router = AppRouter.shared
    /// The item's leading edge in the window, where the toolbar put it. Kept
    /// from the last time a page showed one: the toolbar puts it in the same
    /// place each time, and measured afresh it is known only a frame late, so
    /// what it shows appeared at the toolbar's edge and then moved across.
    @State private var origin: CGFloat? = ToolbarLeadingItem.origin

    var body: some View {
        let target = MainWindow.sidebarSpan + margin
        let room = origin.map { max(0, target - $0) } ?? 0
        content
            .padding(.trailing, room)
            .offset(x: router.sidebarOpen ? room : 0)
            .animation(SidebarSlide.animation, value: router.sidebarOpen)
            // Not seen until it is in its place, the first time.
            .opacity(origin == nil ? 0 : 1)
            // Read where the item is, not where its content was moved to.
            .background(WindowOriginReader { x in
                guard x != origin else { return }
                ToolbarLeadingItem.origin = x
                // Put there at once: the page's arrival animates, this must not.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { origin = x }
            })
    }
}

/// Tells where in its window the view it backs starts.
private struct WindowOriginReader: NSViewRepresentable {
    let changed: (CGFloat) -> Void

    final class Probe: NSView {
        var changed: ((CGFloat) -> Void)?
        private var last: CGFloat?

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        private func report() {
            guard window != nil else { return }
            let x = convert(bounds.origin, to: nil).x.rounded()
            guard x != last else { return }
            last = x
            DispatchQueue.main.async { [weak self] in self?.changed?(x) }
        }
    }

    func makeNSView(context _: Context) -> Probe {
        let probe = Probe()
        probe.changed = changed
        return probe
    }

    func updateNSView(_ probe: Probe, context _: Context) {
        probe.changed = changed
    }
}
