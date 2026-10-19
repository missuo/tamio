//
//  MenubarTool.swift
//  Tamio (macOS)
//
//  Created by Lakr Aream on 2022/3/1.
//

import Foundation
import TamioModule

/// The menu bar items and their persistence are main-thread state, like
/// the AppKit items they model; the lock is the bridge's callback contract.
@MainActor
class MenubarTool {
    let bootstrapLock = NSLock()

    static let shared = MenubarTool()

    var statusItem: [MenubarStatusItem] = []
    var hasCat: Bool {
        bootstrapLock.lock()
        let ret = !statusItem.isEmpty
        bootstrapLock.unlock()
        return ret
    }

    private init() {}

    /// Servers shown in the menu bar, so they come back after Tamio restarts.
    private static let persistedKey = "sb.moe.tamio.menubarMachines"

    private func persist() {
        bootstrapLock.lock()
        let ids = statusItem.map(\.machine.id.uuidString)
        bootstrapLock.unlock()
        UserDefaults.standard.set(ids, forKey: Self.persistedKey)
    }

    /// Puts back the menu bar items from the last run. A server that was deleted,
    /// or lost its identity, is dropped without an alert.
    @MainActor func restore() {
        let ids = UserDefaults.standard.stringArray(forKey: Self.persistedKey) ?? []
        for id in ids.compactMap(UUID.init(uuidString:)) {
            createRuncat(for: id, quiet: true)
        }
        persist()
        AppDelegate.shared?.updateWindowStatus()
    }

    struct ArgumentCompiler: Codable {
        let machine: RDMachine.ID
        /// Nil for a server that signs in with no password or key.
        let identity: RDIdentity.ID?

        init(machine: RDMachine.ID, identity: RDIdentity.ID?) {
            self.machine = machine
            self.identity = identity
        }

        @MainActor func createStatusItem() -> MenubarStatusItem? {
            let machine = TamioStore.shared.machineGroup[machine]
            let identity = self.identity.map { TamioStore.shared.identityGroup[$0] }
            // Callers validate these invariants and present errors already;
            // degrade gracefully instead of crashing the whole app.
            guard machine.isNotPlaceholder(), machine.signsInWithoutCredentials || identity?.hasCredentials == true else {
                debugPrint("failed to create status item: malformed machine or identity")
                return nil
            }
            return .init(machine: machine, identity: identity)
        }
    }

    /// - Parameter quiet: restoring at launch; problems are skipped, not shown.
    @MainActor func createRuncat(for machineId: RDMachine.ID, quiet: Bool = false) {
        func fail(_ message: String) {
            if !quiet { Dialogs.presentError(with: message, delay: 0) }
        }
        bootstrapLock.lock()
        let copy = statusItem
        bootstrapLock.unlock()
        for item in copy where item.machine.id == machineId {
            fail(String(localized: "This server is already in the menu bar"))
            return
        }

        let machine = TamioStore.shared.machineGroup[machineId]
        guard machine.isNotPlaceholder() else {
            fail(String(localized: "Could not add the server to the menu bar: its details are missing"))
            return
        }
        let identity: RDIdentity?
        if machine.signsInWithoutCredentials {
            identity = nil
        } else {
            guard machine.associatedIdentity != nil else {
                fail(String(localized: "To show a server in the menu bar, choose an identity for it first (Edit Server › Identity)"))
                return
            }
            guard let resolved = TamioStore.shared.associatedIdentity(for: machine) else {
                fail(String(localized: "Could not add the server to the menu bar: its identity is missing"))
                return
            }
            identity = resolved
        }
        let compiler = ArgumentCompiler(machine: machine.id, identity: identity?.id)
        guard let item = compiler.createStatusItem() else {
            return
        }
        bootstrapLock.lock()
        statusItem.append(item)
        bootstrapLock.unlock()
        if !quiet {
            persist()
            AppDelegate.shared?.updateWindowStatus()
        }
    }

    #if DEBUG
        /// Adds a sample server whose monitor never connects, and opens its
        /// popover. Launch the debug build with TAMIO_PREVIEW_MENUBAR=1 to check
        /// the popover's layout. The sample is not saved.
        @MainActor func showPreview() {
            let machine = RDMachine(remoteAddress: "203.0.113.10", remotePort: "22", name: "web-01")
            let item = MenubarStatusItem(machine: machine, identity: RDIdentity(), session: .preview(machine: machine))
            bootstrapLock.lock()
            statusItem.append(item)
            bootstrapLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { item.togglePopover() }
        }
    #endif

    func item(withKey key: String) -> MenubarStatusItem? {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        return statusItem.first { $0.key == key }
    }

    @MainActor func remove(menubarItem: MenubarStatusItem.ID) {
        bootstrapLock.lock()
        statusItem = statusItem
            .filter { $0.id != menubarItem }
        bootstrapLock.unlock()
        persist()
        AppDelegate.shared?.updateWindowStatus()
    }
}
