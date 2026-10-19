//
//  TerminalTabView.swift
//  TamioMobile
//
//  Created by Lakr Aream on 2022/3/2.
//

import TamioModule
import SwiftUI

class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    private init() {
        // Shared terminal core lives in TamioModule; register the platform
        // UI handler it delegates to.
        TerminalInterface.uiHandler = IOSTerminalUIHandler()
    }

    @Published var terminals: [TerminalContext] = []

    func begin(for machineId: RDMachine.ID, force: Bool = false) {
        assert(Thread.isMainThread, "accessing to property terminals requires main thread")
        debugPrint("\(self) \(#function) \(machineId)")
        if !force {
            for terminal in terminals where terminal.machine.id == machineId {
                UIBridge.requiresConfirmation(
                    message: String(localized: "Another terminal for this machine is already running")
                ) { confirmed in
                    guard confirmed else {
                        return
                    }
                    self.begin(for: machineId, force: true)
                }
                return
            }
        }
        let machine = TamioStore.shared.machineGroup[machineId]
        guard machine.isNotPlaceholder() else {
            UIBridge.presentError(with: String(localized: "Unknown Bad Data"))
            return
        }
        let object = TerminalContext(machine: machine)
        TamioStore.shared.storeRecentIfNeeded(from: machineId)
        terminals.append(object)
    }

    func begin(for command: SSHCommandReader, force: Bool = false) {
        assert(Thread.isMainThread, "accessing to property terminals requires main thread")
        debugPrint("\(self) \(#function) \(command.command)")
        if !force {
            for terminal in terminals where terminal.command == command {
                UIBridge.requiresConfirmation(
                    message: String(localized: "Another terminal for this command is already running")
                ) { confirmed in
                    guard confirmed else {
                        return
                    }
                    self.begin(for: command, force: true)
                }
                return
            }
        }
        let object = TerminalContext(command: command)
        TamioStore.shared.storeRecentIfNeeded(from: command)
        terminals.append(object)
    }

    func end(for contextId: UUID) {
        onMainThread { [self] in
            debugPrint("\(self) \(#function) \(contextId)")
            let index = terminals.firstIndex { $0.id == contextId }
            guard let index = index else { return }
            let term = terminals.remove(at: index)
            term.processShutdown()
            term.destroyedSession = true
        }
    }
}
