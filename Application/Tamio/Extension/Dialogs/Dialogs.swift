//
//  InterfaceBridge.swift
//  Tamio
//
//  Created by Lakr Aream on 2022/2/9.
//

import AppKit
import Foundation
import TamioModule

enum Dialogs {
    static func sendPasteboard(str: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }

    @MainActor static func open(url: URL) {
        NSWorkspace.shared.open(url)
    }

    @MainActor static func askForInput(title: String, message: String, defaultValue: String, complete: @escaping (String) -> Void) {
        Mac.alert(message: title, informative: message, buttons: [String(localized: "OK"), String(localized: "Cancel")], textField: defaultValue) { button, text in
            if button == 0, let text { complete(text) }
        }
    }
}
