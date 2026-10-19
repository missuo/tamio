//
//  PortForwardBackend.swift
//  TamioMobile
//
//  The session lifecycle lives in TamioModule.PortForwardContext; this
//  backend keeps the container, the per-forward states and validation.
//

import Combine
import Foundation
import TamioModule

class PortForwardBackend: ObservableObject {
    static let shared = PortForwardBackend()

    private init() {}

    @Published var container = [PortForwardContext]()

    @Published var lastStatus = [RDPortForward.ID: PortForwardContext.Lifecycle]()

    func createSession(withPortForwardID pid: RDPortForward.ID) {
        if sessionExists(withPortForwardID: pid) {
            // multiple start
            return
        }
        let portFwd = TamioStore.shared.portForwardGroup[pid]
        guard portFwd.isValid(),
              let mid = portFwd.usingMachine
        else {
            UIBridge.presentError(with: String(localized: "Invalid Info"))
            return
        }
        let machine = TamioStore.shared.machineGroup[mid]
        guard machine.isNotPlaceholder() else {
            UIBridge.presentError(with: String(localized: "Invalid Info"))
            return
        }
        let context = PortForwardContext(
            info: portFwd,
            machine: machine
        )
        context.lifecycleHandler = { [weak self] state in
            self?.putStatus(for: pid, with: state)
        }
        context.terminationHandler = { [weak self] context in
            self?.endLifecycle(for: context)
        }
        container.append(context)
        context.begin()
        UIBridge.presentSuccess(with: String(localized: "Forward Created"))
    }

    private func putStatus(for pid: RDPortForward.ID, with state: PortForwardContext.Lifecycle) {
        onMainThread {
            self.lastStatus[pid] = state
        }
    }

    /// Removes a finished session's context, so the row's switch turns off.
    /// Called on the main thread by the context's termination handler.
    private func endLifecycle(for context: PortForwardContext) {
        container.removeAll { $0.id == context.id }
    }

    func sessionExists(withPortForwardID pid: RDPortForward.ID) -> Bool {
        container.first { $0.info.id == pid } != nil
    }

    func endSession(withPortForwardID pid: RDPortForward.ID) {
        let index = container.firstIndex { $0.info.id == pid }
        if let index = index {
            let context = container.remove(at: index)
            context.terminate()
        }
    }
}
