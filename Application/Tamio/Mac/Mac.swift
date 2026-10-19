//
//  Mac.swift
//  Tamio (macOS)
//
//  AppKit for the app, where SwiftUI stops: activation, appearance and
//  termination, the windows and their material, alerts and open panels, and
//  the login keychain the AppKit builds of Tamio kept their master key in.
//

import AppKit
import SwiftUI
import TamioModule

enum Mac {
    // MARK: Application

    /// Asked when the app is about to quit; false keeps it running, as when
    /// the user is being asked first.
    @MainActor static var mayTerminate: (() -> Bool)?
    /// Shows the main window, for the menu bar item's Open Tamio.
    @MainActor static var openApp: (() -> Void)?

    @MainActor static func setAppearance(_ name: String?) {
        switch name {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        for item in MacStatusItem.live.allObjects { item.popover?.appearance = NSApp.appearance }
    }

    @MainActor static func terminate() {
        NSApp.terminate(nil)
    }

    /// Brings the app forward, with its main window (or `window`) in front.
    @MainActor static func activate(window: NSWindow? = nil) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let target = window ?? mainWindow {
            if target.isMiniaturized { target.deminiaturize(nil) }
            target.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor static var hasVisibleWindow: Bool {
        hasVisibleWindow(excluding: nil)
    }

    @MainActor static func hasVisibleWindow(excluding closing: NSWindow?) -> Bool {
        ordinaryWindows.contains { $0 !== closing && ($0.isVisible || $0.isMiniaturized) }
    }

    @MainActor static func isOrdinaryWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !window.isSheet && !(window is NSPanel)
            && window.level == .normal && window.contentView != nil
    }

    /// With every window closed and a server in the menu bar, Tamio leaves
    /// the Dock and stays in the menu bar.
    @MainActor static func setAccessory(_ accessory: Bool) {
        let policy: NSApplication.ActivationPolicy = accessory ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    @MainActor static var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) }
    @MainActor static var shiftHeld: Bool { NSEvent.modifierFlags.contains(.shift) }
    @MainActor static var isFrontmost: Bool { NSApp.isActive }

    // MARK: Windows

    /// The app's own windows: not menu bar popovers, sheets or panels.
    @MainActor static var ordinaryWindows: [NSWindow] {
        NSApp.windows.filter(isOrdinaryWindow)
    }

    @MainActor static var mainWindow: NSWindow? {
        if let key = NSApp.keyWindow, ordinaryWindows.contains(key) { return key }
        return ordinaryWindows.first(where: \.isVisible) ?? ordinaryWindows.first
    }

    /// TamioDesign's `RXPalette.window`, the colour the pages are drawn on.
    static let windowColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1B / 255, green: 0x1C / 255, blue: 0x1F / 255, alpha: 1)
            : NSColor(srgbRed: 0xEE / 255, green: 0xF0 / 255, blue: 0xF5 / 255, alpha: 1)
    }

    /// The material of Tamio's windows: the desktop shows through, blurred.
    @MainActor static func makeBackdrop(frame: NSRect) -> NSVisualEffectView {
        let effect = NSVisualEffectView(frame: frame)
        effect.autoresizingMask = [.width, .height]
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }

    // MARK: Alerts and panels

    private static var sheetParent: NSWindow? {
        MainActor.assumeIsolated { mainWindow.flatMap { $0.isVisible ? $0 : nil } }
    }

    /// An alert, as a sheet on the main window when there is one. `buttons`
    /// in order, the first the default; `textField` adds a field holding
    /// that text. The completion gets the index of the button and the
    /// field's text.
    @MainActor static func alert(
        message: String,
        informative: String?,
        buttons: [String],
        destructiveFirstButton: Bool = false,
        textField: String? = nil,
        completion: ((Int, String?) -> Void)? = nil
    ) {
        let alert = NSAlert()
        alert.messageText = message
        if let informative { alert.informativeText = informative }
        for (index, title) in buttons.enumerated() {
            let button = alert.addButton(withTitle: title)
            if index == 0 { button.hasDestructiveAction = destructiveFirstButton }
        }
        var field: NSTextField?
        if let textField {
            // As wide as its text (a path, often), within reason; past that it
            // wraps onto more lines, so all of it shows.
            let input = NSTextField(string: textField)
            input.font = .systemFont(ofSize: NSFont.systemFontSize)
            input.cell?.wraps = true
            input.cell?.isScrollable = false
            input.usesSingleLineMode = false
            input.lineBreakMode = .byCharWrapping
            let textWidth = (textField as NSString).size(withAttributes: [.font: input.font as Any]).width
            let width = min(560, max(320, ceil(textWidth) + 16))
            let height = input.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 24
            input.frame = NSRect(x: 0, y: 0, width: width, height: max(24, ceil(height)))
            alert.accessoryView = input
            alert.layout()
            alert.window.initialFirstResponder = input
            field = input
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            completion?(index, field?.stringValue)
        }
        if let parent = sheetParent {
            alert.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    @MainActor static func openPanel(
        message: String?,
        prompt: String?,
        directory: URL?,
        canChooseFiles: Bool,
        canChooseDirectories: Bool,
        allowsMultipleSelection: Bool,
        canCreateDirectories: Bool,
        showsHiddenFiles: Bool,
        completion: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        if let message { panel.message = message }
        if let prompt { panel.prompt = prompt }
        if let directory { panel.directoryURL = directory }
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = canCreateDirectories
        panel.showsHiddenFiles = showsHiddenFiles
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : [])
        }
        if let parent = sheetParent {
            panel.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    // MARK: Login keychain

    /// Lets the store find the master key the AppKit builds of Tamio kept in
    /// the login keychain. Call before `TamioStore.shared` is first used.
    static func installLegacyKeyStore() {
        let service = "sb.moe.tamio.kcAccess"
        let account = "sb.moe.tamio.MasterCrypto"
        AES.legacyKeyStore = LegacyKeyStore(
            read: { readLoginKeychain(service: service, account: account) },
            write: { key in writeLoginKeychain(service: service, account: account, label: "Tamio Master Crypto Key", value: key) }
        )
    }

    static func readLoginKeychain(service: String, account: String) -> LegacyKeyStore.ReadResult {
        var length: UInt32 = 0
        var data: UnsafeMutableRawPointer?
        let status = SecKeychainFindGenericPassword(
            nil,
            UInt32(service.utf8.count), service,
            UInt32(account.utf8.count), account,
            &length, &data, nil
        )
        defer { if let data { SecKeychainItemFreeContent(nil, data) } }
        switch status {
        case errSecSuccess:
            guard let data, let value = String(data: Data(bytes: data, count: Int(length)), encoding: .utf8) else {
                return .unavailable
            }
            return .found(value)
        case errSecItemNotFound:
            return .absent
        default:
            // Denied, cancelled, or a locked keychain: the item may well be there.
            return .unavailable
        }
    }

    static func writeLoginKeychain(service: String, account: String, label: String, value: String) -> Bool {
        var item: SecKeychainItem?
        let status = SecKeychainAddGenericPassword(
            nil,
            UInt32(service.utf8.count), service,
            UInt32(account.utf8.count), account,
            UInt32(value.utf8.count), value,
            &item
        )
        guard status == errSecSuccess else { return false }
        // The name the item goes by in Keychain Access.
        if let item {
            var bytes = Array(label.utf8)
            bytes.withUnsafeMutableBytes { buffer in
                var attribute = SecKeychainAttribute(
                    tag: SecItemAttr.labelItemAttr.rawValue,
                    length: UInt32(buffer.count),
                    data: buffer.baseAddress
                )
                withUnsafeMutablePointer(to: &attribute) { pointer in
                    var list = SecKeychainAttributeList(count: 1, attr: pointer)
                    _ = SecKeychainItemModifyAttributesAndData(item, &list, 0, nil)
                }
            }
        }
        return true
    }
}
