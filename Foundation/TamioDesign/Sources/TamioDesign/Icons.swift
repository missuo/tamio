//
//  Icons.swift
//  TamioDesign
//
//  Tamio's icons are Lucide's (ISC, Lucide contributors), one set drawn to one
//  grid and stroke, as custom symbols in the app's asset catalog (Icons): in
//  the app's own bundle, because AppKit makes a toolbar button and a menu item
//  from its image by name in the main bundle, and one in a package's bundle
//  came out blank. They size with the
//  text beside them and sit on its baseline as SF Symbols do. Views name an
//  icon by the SF Symbol it stands for, and get Lucide's where there is one;
//  a symbol the user picked (a snippet's) keeps its SF Symbol, and so does an
//  app without the icons in its catalog (the iOS app, for now).
//
//  The symbols are made from Lucide's SVGs (lucide-static 0.460.0), outlined
//  at Lucide's own 2-unit stroke and centred between the template's baseline
//  and cap line, the art as tall as the point size: the size of the SF Symbol
//  it stands for, so nothing beside it needed to change.
//

import SwiftUI
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

public enum RXIcon {
    /// SF Symbol name → Lucide icon name.
    static let lucide: [String: String] = [
        "arrow.clockwise": "rotate-cw",
        "arrow.counterclockwise": "rotate-ccw",
        "arrow.down.circle.fill": "circle-arrow-down",
        "arrow.down.circle": "circle-arrow-down",
        "arrow.down": "arrow-down",
        "arrow.right": "arrow-right",
        "arrow.up.circle": "circle-arrow-up",
        "arrow.up.right.square": "square-arrow-out-up-right",
        "arrow.up": "arrow-up",
        "arrow.uturn.backward": "undo-2",
        "arrow.uturn.forward": "redo-2",
        "arrowshape.turn.up.right": "forward",
        "character.cursor.ibeam": "text-cursor",
        "checkmark.circle.fill": "circle-check",
        "checkmark.circle": "circle-check",
        "checkmark.square.fill": "square-check",
        "checkmark": "check",
        "chevron.down": "chevron-down",
        "chevron.left.forwardslash.chevron.right": "code-xml",
        "chevron.right": "chevron-right",
        "chevron.up.chevron.down": "chevrons-up-down",
        "chevron.up": "chevron-up",
        "circle": "circle",
        "largecircle.fill.circle": "circle-dot",
        "clock": "clock",
        "cursorarrow.click": "mouse-pointer-click",
        "doc": "file",
        "doc.on.clipboard": "clipboard-copy",
        "doc.on.doc": "copy",
        "doc.richtext": "file-text",
        "doc.text": "file-text",
        "doc.zipper": "file-archive",
        "ellipsis.circle": "circle-ellipsis",
        "ellipsis": "ellipsis",
        "exclamationmark.triangle.fill": "triangle-alert",
        "exclamationmark.triangle": "triangle-alert",
        "eye.slash.fill": "eye-off",
        "eye.slash": "eye-off",
        "eye": "eye",
        "film": "film",
        "folder.fill": "folder",
        "folder": "folder",
        "gearshape": "settings",
        "info.circle": "info",
        "key": "key-round",
        "keyboard": "keyboard",
        "laptopcomputer": "laptop",
        "link.badge.plus": "link",
        "link": "link",
        "list.bullet": "list",
        "lock.fill": "lock",
        "macwindow": "app-window",
        "magnifyingglass": "search",
        "menubar.rectangle": "panel-top",
        "minus.circle": "circle-minus",
        "network": "globe",
        "paintpalette": "palette",
        "pencil": "pencil",
        "person": "user",
        "photo": "image",
        "play.fill": "play",
        "plus.rectangle": "square-plus",
        "plus.square.on.square": "copy-plus",
        "plus": "plus",
        "questionmark.circle": "circle-help",
        "rectangle.stack.badge.plus": "layers",
        "server.rack": "server",
        "shippingbox": "package",
        "slider.horizontal.3": "sliders-horizontal",
        "sparkles": "sparkles",
        "square.and.arrow.down": "import",
        "square": "square",
        "stop.circle": "circle-stop",
        "terminal": "square-terminal",
        "text.bubble": "message-square-text",
        "textformat.size.larger": "a-arrow-up",
        "textformat.size.smaller": "a-arrow-down",
        "textformat": "type",
        "trash": "trash-2",
        "waveform.path.ecg": "activity",
        "waveform": "audio-waveform",
        "wifi": "wifi",
        "xmark.circle.fill": "circle-x",
        "xmark.circle": "circle-x",
        "xmark": "x",
        "house": "house",
        "arrow.left.arrow.right": "arrow-left-right",
        "person.badge.key": "key-round",
    ]

    /// Whether the app carries the icons in its asset catalog (Icons): the Mac
    /// app does; an app that does not keeps SF Symbols.
    static let inMainBundle: Bool = {
        #if os(macOS)
            NSImage(symbolName: "lucide.plus", bundle: .main, variableValue: 1) != nil
        #else
            UIImage(named: "lucide.plus") != nil
        #endif
    }()

    /// Whether Tamio draws this SF Symbol with an icon of its own.
    public static func hasIcon(for systemName: String) -> Bool {
        lucide[systemName] != nil
    }
}

public extension Image {
    /// Tamio's icon for an SF Symbol name: Lucide's where there is one, else
    /// the SF Symbol itself. It takes the font's size, as a symbol does.
    init(rx systemName: String) {
        if let name = RXIcon.lucide[systemName], RXIcon.inMainBundle {
            self.init("lucide.\(name)", bundle: .main)
        } else {
            self.init(systemName: systemName)
        }
    }
}

#if os(macOS)
    extension RXIcon {
        @MainActor private static var images: [String: NSImage] = [:]

        /// The icon as an AppKit image. A toolbar button or a menu item is
        /// made from its label's image by AppKit, which finds a custom symbol
        /// only this way (by name it found nothing, and drew a blank), and then
        /// sizes it as it does an SF Symbol.
        @MainActor static func appKitImage(_ systemName: String) -> NSImage? {
            guard let name = lucide[systemName], inMainBundle else { return nil }
            if let image = images[name] { return image }
            let image = NSImage(symbolName: "lucide.\(name)", bundle: .main, variableValue: 1)
            images[name] = image
            return image
        }
    }
#endif

public extension Label where Title == Text, Icon == Image {
    /// A title with Tamio's icon for an SF Symbol name, as a toolbar button,
    /// a menu item or a list row shows it: at the size AppKit gives it there,
    /// body size elsewhere.
    @MainActor
    init(_ titleKey: LocalizedStringKey, rx systemName: String) {
        self.init { Text(titleKey) } icon: { Image.labelIcon(systemName) }
    }

    @MainActor @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, rx systemName: String) {
        self.init { Text(verbatim: String(title)) } icon: { Image.labelIcon(systemName) }
    }
}

extension Image {
    @MainActor static func labelIcon(_ systemName: String) -> Image {
        #if os(macOS)
            if let image = RXIcon.appKitImage(systemName) { return Image(nsImage: image) }
        #endif
        return Image(rx: systemName)
    }
}

#if DEBUG && os(macOS)
    public extension RXIcon {
        /// Where the icons are looked for, and whether one is found there.
        static var diagnosis: String {
            let found = NSImage(symbolName: "lucide.plus", bundle: .main, variableValue: 1) != nil
            return "\(Bundle.main.bundlePath) found \(found)"
        }
    }
#endif
