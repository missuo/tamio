//
//  TerminalManager.swift
//  Tamio (macOS)
//
//  Created by Lakr Aream on 2022/3/10.
//

import Combine
import Foundation
import TamioModule

/// The manager and its session list are main-thread state, like the
/// interface showing them.
@MainActor
class TerminalManager: ObservableObject {
    static let shared = TerminalManager()
    private init() {}

    @Published var sessionContexts: [Context] = []

    func createSession(
        withMachineObject machine: RDMachine,
        force: Bool = false,
        completion: @escaping (Context) -> Void = { _ in }
    ) {
        let index = sessionContexts.firstIndex { $0.machine.id == machine.id }
        if index != nil, !force {
            Dialogs.requiresConfirmation(
                message: String(localized: "\(machine.name) already has a terminal open"),
                confirmTitle: String(localized: "Open Another")
            ) { confirmed in
                if confirmed {
                    self.createSession(withMachineObject: machine, force: true, completion: completion)
                }
            }
            return
        }
        let context = Context(machine: machine)
        sessionContexts.append(context)
        completion(context)
    }

    func createSession(withMachineID machineId: RDMachine.ID, completion: @escaping (Context) -> Void = { _ in }) {
        let machine = TamioStore.shared.machineGroup[machineId]
        guard machine.isNotPlaceholder() else {
            Dialogs.presentError(with: String(localized: "This server's details could not be read."))
            return
        }
        createSession(withMachineObject: machine, completion: completion)
    }

    @discardableResult
    func createSession(withCommand command: SSHCommandReader) -> Context {
        let context = Context(command: command)
        sessionContexts.append(context)
        return context
    }

    func sessionAlive(forContext contextId: Context.ID) -> Bool {
        !(
            sessionContexts
                .first { $0.id == contextId }?
                .closed ?? true
        )
    }

    func closeSession(withMachineID machineId: RDMachine.ID) {
        let index = sessionContexts.firstIndex { $0.machine.id == machineId }
        if let index = index {
            let context = sessionContexts.remove(at: index)
            context.processShutdown()
            context.shell.destroyPermanently()
        }
    }

    func closeSession(withContextID contextId: Context.ID) {
        let index = sessionContexts.firstIndex { $0.id == contextId }
        if let index = index {
            let context = sessionContexts.remove(at: index)
            context.processShutdown()
            context.shell.destroyPermanently()
        }
    }

    func closeAll() {
        for context in sessionContexts {
            context.processShutdown()
            context.shell.destroyPermanently()
        }
        sessionContexts = []
    }
}
