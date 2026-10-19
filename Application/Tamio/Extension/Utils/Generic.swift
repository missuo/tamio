//
//  Generic.swift
//  Tamio
//
//  Created by Lakr Aream on 2022/2/11.
//

import AppKit
import Foundation
import TamioModule
import SwiftUI

/// Presents SwiftUI content as a sheet on the main window from code that
/// has no view to hang a `.sheet` on (router actions, menu bar).
enum SheetPresenter {
    @MainActor
    static func present<Content: View>(
        size: CGSize? = nil,
        @ViewBuilder content: @escaping (_ dismiss: @escaping () -> Void) -> Content
    ) {
        guard let parent = Mac.mainWindow else { return }
        weak var sheet: NSWindow?
        let dismiss = {
            if let sheet { parent.endSheet(sheet) }
            sheet = nil
        }
        let root = content(dismiss)
            .environmentObject(TamioStore.shared)
            .frame(width: size?.width, height: size?.height)
        let hosting = NSHostingController(rootView: root)
        // The sheet is as large as its content, as a SwiftUI sheet is.
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        sheet = window
        parent.beginSheet(window) { _ in }
    }
}

enum ServerPickerPanel {
    /// The multi-select server picker used by Open Terminals, Run snippet and Port Forward.
    @MainActor
    static func present(
        title: LocalizedStringKey,
        lead: LocalizedStringKey? = nil,
        confirmTitle: LocalizedStringKey,
        allowsMany: Bool,
        preselected: Set<RDMachine.ID> = [],
        onComplete: @escaping ([RDMachine.ID]) -> Void
    ) {
        SheetPresenter.present { dismiss in
            ServerPickerSheet(
                title: title,
                lead: lead,
                confirmTitle: confirmTitle,
                allowsMany: allowsMany,
                initialSelection: preselected
            ) { selection in
                dismiss()
                guard let selection, !selection.isEmpty else { return }
                onComplete(selection)
            }
        }
    }
}

enum IdentityPickerPanel {
    @MainActor
    static func present(onComplete: @escaping (RDIdentity.ID?) -> Void) {
        SheetPresenter.present { dismiss in
            IdentityPickerSheet { selection in
                dismiss()
                onComplete(selection)
            }
        }
    }
}
