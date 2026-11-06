//
//  SidebarSlide.swift
//  Tamio (macOS)
//
//  The sidebar showing or hiding. The sidebar stays where it is; the content's
//  leading edge slides across it, to fill the window or to show it again, and
//  the toggle never moves (MainView).
//
//  Every frame of the slide moves the page under a still pointer, and SwiftUI
//  then hit tests every hover region on the page again to see which one is
//  under it: with many servers that was a fifth of each frame. Nothing can be
//  pointed at while the page moves, so for the slide it takes no hits at all.
//

import AppKit
import SwiftUI

@MainActor
final class SidebarSlide: ObservableObject {
    static let shared = SidebarSlide()

    /// How the content's edge moves: quick, and settling without overshoot.
    static let animation = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.28)

    /// True from the start of a slide until a moment after its end.
    @Published private(set) var sliding = false

    private var end: DispatchWorkItem?

    func begin() {
        if !sliding { sliding = true }
        end?.cancel()
        let finish = DispatchWorkItem { [weak self] in self?.sliding = false }
        end = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: finish)
    }
}

private struct PausesHitTestingWhileSliding: ViewModifier {
    @ObservedObject private var slide = SidebarSlide.shared

    func body(content: Content) -> some View {
        content.allowsHitTesting(!slide.sliding)
    }
}

extension View {
    /// Takes no clicks or hover while the sidebar slides.
    func pausesHitTestingWhileSidebarSlides() -> some View {
        modifier(PausesHitTestingWhileSliding())
    }
}
