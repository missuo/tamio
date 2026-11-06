//
//  Glass.swift
//  TamioDesign
//
//  Frosted glass, on unless turned off in Settings › Appearance: the window's
//  material lets the desktop's colour through, cards are a light tint over it
//  rather than a solid fill, and the terminal's background is part see-through.
//  The tint costs nothing to scroll: there is one blur, the window's, and the
//  cards only lay a colour over it.
//

import SwiftUI
#if os(macOS)
    import AppKit
#endif

public enum RXGlass {
    /// The setting, in the app's user defaults.
    public static let key = "sb.moe.tamio.glass"

    /// What the terminal's background opacity starts from with glass on; a
    /// value set under Terminal takes its place. Low, so the terminal is the
    /// same glass as the window around it, with a wash of its theme's colour.
    public static let terminalOpacity = "0.3"

    #if os(macOS)
        /// The window's blur with glass on: the clearest of AppKit's, which
        /// lets the desktop's colour through.
        static let material = NSVisualEffectView.Material.hudWindow

        /// Laid over the blur, a neutral grey at a little under half: over a
        /// dark desktop it lifts the window off black, over a white one it
        /// dims it enough for light text. Text on glass is a step further
        /// from the background than on solid colour (see `RXPalette`).
        static let tint = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2C / 255, green: 0x2E / 255, blue: 0x33 / 255, alpha: 0.45)
                : NSColor(srgbRed: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF6 / 255, alpha: 0.4)
        }
    #endif

    /// Read where the environment does not reach (the terminal's configuration).
    public static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

private struct RXGlassKey: EnvironmentKey {
    static let defaultValue = true
}

private struct RXOpenWidthKey: EnvironmentKey {
    static let defaultValue = CGFloat.infinity
}

public extension EnvironmentValues {
    /// The width this content has while the window's sidebar is open. Lists
    /// and grids choose their columns from the narrower of it and the width
    /// they have, so hiding the sidebar gives their columns more room
    /// instead of another column. Each container that insets its content
    /// takes its inset off.
    var rxOpenWidth: CGFloat {
        get { self[RXOpenWidthKey.self] }
        set { self[RXOpenWidthKey.self] = newValue }
    }

    /// Whether the window and its cards are frosted glass.
    var rxGlass: Bool {
        get { self[RXGlassKey.self] }
        set { self[RXGlassKey.self] = newValue }
    }
}

extension RXPalette {
    /// A card on the glass: white over the blur, enough to set it apart.
    static let glassSurface = Color(rxLight: 0xFFFF_FF8C, dark: 0xFFFF_FF12)
    /// Its edge, the light catching it.
    static let glassEdge = Color(rxLight: 0xFFFF_FFCC, dark: 0xFFFF_FF1C)
}
