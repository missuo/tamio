//
//  Tokens.swift
//  TamioDesign
//
//  Color, type, spacing and radius tokens of the Tamio design system.
//

import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

// MARK: - Spacing, radius, metrics

public enum RX {
    /// 4pt alignment grid.
    public enum Space {
        public static let s1: CGFloat = 4
        public static let s2: CGFloat = 8
        public static let s3: CGFloat = 12
        public static let s4: CGFloat = 16
        public static let s5: CGFloat = 20
        public static let s6: CGFloat = 24
    }

    public enum Radius {
        public static let sm: CGFloat = 5
        public static let md: CGFloat = 7
        public static let lg: CGFloat = 10
        public static let card: CGFloat = 18
    }

    /// Every button, field, segmented control and pill.
    public static let controlHeight: CGFloat = 28
    public static let smallControlHeight: CGFloat = 22
    public static let sidebarWidth: CGFloat = 216
    public static let tableRowHeight: CGFloat = 40
    public static let denseRowHeight: CGFloat = 32
    public static let tableHeaderHeight: CGFloat = 28
    public static let formRowMinHeight: CGFloat = 56
    /// The narrowest a settings row's title and description get beside the
    /// control; with less room the control goes under them.
    public static let rowMinLabelWidth: CGFloat = 160
}

// MARK: - Colors

extension Color {
    /// An appearance-aware color whose values on frosted glass differ: text
    /// there sits on whatever the desktop shows through, so it keeps further
    /// from the background than on solid colour.
    init(rxLight light: UInt32, dark: UInt32, glassLight: UInt32, glassDark: UInt32) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            let color = NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let glass = RXGlass.isOn
                return NSColor(rxRGBA: isDark ? (glass ? glassDark : dark) : (glass ? glassLight : light))
            }
            self.init(nsColor: color)
        #else
            self.init(rxLight: light, dark: dark)
        #endif
    }

    /// Builds an appearance-aware color from `0xRRGGBBAA` literals.
    init(rxLight light: UInt32, dark: UInt32) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            let color = NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(rxRGBA: isDark ? dark : light)
            }
            self.init(nsColor: color)
        #else
            let color = UIColor { traits in
                UIColor(rxRGBA: traits.userInterfaceStyle == .dark ? dark : light)
            }
            self.init(uiColor: color)
        #endif
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    extension NSColor {
        convenience init(rxRGBA value: UInt32) {
            self.init(
                srgbRed: CGFloat((value >> 24) & 0xFF) / 255,
                green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255,
                alpha: CGFloat(value & 0xFF) / 255
            )
        }
    }

#else
    extension UIColor {
        convenience init(rxRGBA value: UInt32) {
            self.init(
                red: CGFloat((value >> 24) & 0xFF) / 255,
                green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255,
                alpha: CGFloat(value & 0xFF) / 255
            )
        }
    }
#endif

/// Color tokens. Usage notes follow the design system's token table.
public extension ShapeStyle where Self == Color {
    /// Window background behind the sidebar and the card grid.
    static var rxWindow: Color { RXPalette.window }
    /// Fill of the selected sidebar row.
    static var rxSidebarSelected: Color { RXPalette.sidebarSelected }
    /// Card fill.
    static var rxSurface: Color { RXPalette.surface }
    /// Tracks of segmented controls and usage bars; inset areas inside a card.
    static var rxSurfaceSunken: Color { RXPalette.surfaceSunken }
    /// Fill of toolbar status pills.
    static var rxPill: Color { RXPalette.pill }
    /// 1px dividers, list separators, chart gridlines.
    static var rxHairline: Color { RXPalette.hairline }
    /// 1px border of bordered buttons, fields and segmented tracks.
    static var rxControlBorder: Color { RXPalette.controlBorder }
    /// Primary text and numbers.
    static var rxInk: Color { RXPalette.ink }
    /// Captions, section labels and units.
    static var rxInkSecondary: Color { RXPalette.inkSecondary }
    /// Chart axes and scale hints on `surface` only.
    static var rxInkTertiary: Color { RXPalette.inkTertiary }
    /// Tamio indigo: first data series, selection, links, focus.
    static var rxAccent: Color { RXPalette.accent }
    /// Text and icons on an `accent` fill.
    static var rxOnAccent: Color { RXPalette.onAccent }
    /// A solid fill in the accent colour, under `onAccent` text or symbols:
    /// in Dark mode a deeper indigo than `accent`, which is light for text
    /// on dark and too light for white on it.
    static var rxAccentSolid: Color { RXPalette.accentSolid }
    /// Second data series.
    static var rxSeries2: Color { RXPalette.series2 }
    static var rxSeries2Fill: Color { RXPalette.series2Fill }
    static var rxAccentFill: Color { RXPalette.accentFill }
    /// Selected segment of a segmented control.
    static var rxSegmentSelected: Color { RXPalette.segmentSelected }
    static var rxOnSegment: Color { RXPalette.onSegment }
    static var rxSuccess: Color { RXPalette.success }
    static var rxSuccessHalo: Color { RXPalette.successHalo }
    static var rxWarning: Color { RXPalette.warning }
    static var rxDanger: Color { RXPalette.danger }
    static var rxRowSelected: Color { RXPalette.rowSelected }
    static var rxRowHover: Color { RXPalette.rowHover }
    /// Dims the window behind a sheet or dialog.
    static var rxScrim: Color { RXPalette.scrim }
    /// Terminal surface in both themes; also code previews.
    static var rxTerminalBackground: Color { RXPalette.terminalBackground }
    static var rxTerminalForeground: Color { RXPalette.terminalForeground }
    static var rxTerminalMuted: Color { RXPalette.terminalMuted }
    static var rxTerminalGreen: Color { RXPalette.terminalGreen }
    static var rxTerminalBlue: Color { RXPalette.terminalBlue }
    static var rxTerminalYellow: Color { RXPalette.terminalYellow }
    static var rxTerminalRed: Color { RXPalette.terminalRed }
    static var rxTerminalCursor: Color { RXPalette.terminalCursor }
}

enum RXPalette {
    static let window = Color(rxLight: 0xEEF0_F5FF, dark: 0x1B1C_1FFF)
    static let sidebarSelected = Color(rxLight: 0xE1E3_EAFF, dark: 0x3436_3BFF)
    static let surface = Color(rxLight: 0xFFFF_FFFF, dark: 0x2627_2BFF)
    static let surfaceSunken = Color(rxLight: 0xF1F2_F5FF, dark: 0x1F20_23FF)
    static let pill = Color(rxLight: 0xE3E5_EBFF, dark: 0x2F31_35FF)
    /// On glass, a line a little lighter (darker in Light mode) than what is
    /// behind it: a solid grey made for the solid window read as a black
    /// stripe over the lighter glass in Dark mode.
    static let hairline = Color(rxLight: 0xE3E5_EAFF, dark: 0x3A3B_40FF, glassLight: 0x0000_0014, glassDark: 0xFFFF_FF1A)
    static let controlBorder = Color(rxLight: 0x8A8D_96FF, dark: 0x7678_7FFF)
    static let ink = Color(rxLight: 0x1D1D_1FFF, dark: 0xF5F5_F7FF)
    static let inkSecondary = Color(rxLight: 0x5F61_68FF, dark: 0xA1A3_AAFF, glassLight: 0x4447_4EFF, glassDark: 0xC6C8_CEFF)
    static let inkTertiary = Color(rxLight: 0x7073_80FF, dark: 0x8A8D_96FF, glassLight: 0x585B_64FF, glassDark: 0xA9AC_B3FF)
    static let accent = Color(rxLight: 0x4B49_C8FF, dark: 0x8583_FFFF)
    static let onAccent = Color(rxLight: 0xFFFF_FFFF, dark: 0xFFFF_FFFF)
    static let accentSolid = Color(rxLight: 0x4B49_C8FF, dark: 0x5E5C_E6FF)
    static let series2 = Color(rxLight: 0x3B94_D6FF, dark: 0x6CBC_F2FF)
    static let series2Fill = Color(rxLight: 0x3B94_D633, dark: 0x6CBC_F229)
    static let accentFill = Color(rxLight: 0x4B49_C826, dark: 0x8583_FF2E)
    static let segmentSelected = Color(rxLight: 0x6E70_79FF, dark: 0x5F61_69FF)
    static let onSegment = Color(rxLight: 0xFFFF_FFFF, dark: 0xFFFF_FFFF)
    static let success = Color(rxLight: 0x24A1_48FF, dark: 0x34D1_58FF)
    static let successHalo = Color(rxLight: 0x24A1_4826, dark: 0x34D1_5833)
    static let warning = Color(rxLight: 0xA864_00FF, dark: 0xFFB3_40FF)
    static let danger = Color(rxLight: 0xD930_25FF, dark: 0xFF69_61FF)
    static let rowSelected = Color(rxLight: 0xE4E4_F7FF, dark: 0x3434_5AFF)
    static let rowHover = Color(rxLight: 0xF4F5_F8FF, dark: 0x2C2D_32FF)
    static let scrim = Color(rxLight: 0x1416_1E66, dark: 0x0000_008C)
    static let terminalBackground = Color(rxLight: 0x1617_1AFF, dark: 0x1213_16FF)
    static let terminalForeground = Color(rxLight: 0xE6E7_EAFF, dark: 0xE6E7_EAFF)
    static let terminalMuted = Color(rxLight: 0x8B8E_96FF, dark: 0x8B8E_96FF)
    static let terminalGreen = Color(rxLight: 0x5FD3_83FF, dark: 0x5FD3_83FF)
    static let terminalBlue = Color(rxLight: 0x7CB7_FFFF, dark: 0x7CB7_FFFF)
    static let terminalYellow = Color(rxLight: 0xE8C2_6AFF, dark: 0xE8C2_6AFF)
    static let terminalRed = Color(rxLight: 0xFF7B_72FF, dark: 0xFF7B_72FF)
    static let terminalCursor = Color(rxLight: 0xA9A7_FFFF, dark: 0xA9A7_FFFF)
}

// MARK: - Type

public extension Font {
    /// One per page, top-left of the content column.
    static let rxPageTitle = Font.system(size: 26, weight: .bold)
    /// The headline number of a card.
    static let rxMetricXL = Font.system(size: 32, weight: .semibold).monospacedDigit()
    /// Sub-metrics and header values.
    static let rxMetricMD = Font.system(size: 16, weight: .semibold).monospacedDigit()
    /// Sheet and editor titles.
    static let rxSheetTitle = Font.system(size: 18, weight: .bold)
    /// Section titles above a card group on a page.
    static let rxSectionTitle = Font.system(size: 13, weight: .semibold)
    /// Default text: rows, form labels.
    static let rxBody = Font.system(size: 13)
    /// Row titles, values in a usage list.
    static let rxBodyStrong = Font.system(size: 13, weight: .semibold)
    /// Card titles and metric labels (always uppercase, use `CapsLabel`).
    static let rxCaption = Font.system(size: 11, weight: .medium)
    /// Sidebar section headers in sentence case.
    static let rxSectionLabel = Font.system(size: 11, weight: .medium)
    /// One-sentence descriptions under a title.
    static let rxHelp = Font.system(size: 11)
    /// Unit after a metric number.
    static let rxUnit = Font.system(size: 13, weight: .medium)
    /// Chart axis and scale labels.
    static let rxAxis = Font.system(size: 10).monospacedDigit()
    /// Addresses, ports, commands, paths and keys.
    static let rxCode = Font.system(size: 12, design: .monospaced)
}

/// Letter spacing of `caption-caps` (0.04em of 11pt).
public let rxCapsTracking: CGFloat = 0.44
