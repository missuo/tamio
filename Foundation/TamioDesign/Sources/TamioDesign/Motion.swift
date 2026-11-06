//
//  Motion.swift
//  TamioDesign
//
//  How things move: short, eased, and never in the way. Nothing here changes
//  what a view looks like at rest.
//

import SwiftUI

public extension Animation {
    /// Hover and press feedback.
    static let rxQuick = Animation.easeOut(duration: 0.12)
    /// A selection sliding to its new place, rows making room.
    static let rxMove = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// Content arriving.
    static let rxArrive = Animation.easeOut(duration: 0.28)
}

/// Fades content in as it rises into place, the first time it appears. Items
/// of a list pass their index and arrive one after another.
private struct RXRise: ViewModifier {
    let index: Int
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(index: Int, shown: Bool) {
        self.index = index
        _shown = State(initialValue: shown)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                // Past the first dozen the wait would be felt.
                withAnimation(.rxArrive.delay(Double(min(index, 12)) * 0.025)) { shown = true }
            }
    }
}

/// A symbol or badge that pops in when it first appears.
private struct RXPop: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || reduceMotion ? 1 : 0.7)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) { shown = true }
            }
    }
}

public extension View {
    /// Arrives with a fade and a slight rise; `index` staggers the items of a list.
    /// - Parameter enabled: false shows the view at rest at once: a row a
    ///   lazy list makes as it scrolls into view, long after the page arrived.
    func rxRise(_ index: Int = 0, enabled: Bool = true) -> some View {
        modifier(RXRise(index: index, shown: !enabled))
    }

    /// Pops in with a small spring.
    func rxPop() -> some View {
        modifier(RXPop())
    }
}

/// Where the selection of a toolbar's segmented control was last drawn, by its
/// options. A page's toolbar replaces the last page's, and the selection then
/// slides from where it was instead of jumping.
@MainActor
enum RXSegmentedMemory {
    static var last: [AnyHashable: AnyHashable] = [:]
}
