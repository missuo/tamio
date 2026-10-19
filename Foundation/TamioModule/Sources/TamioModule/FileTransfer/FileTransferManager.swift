//
//  FileTransferManager.swift
//  TamioModule
//
//  Shared transfer session registry, previously duplicated between the
//  macOS and iOS apps. Confirmation/error presentation goes through
//  FileTransferInterface.
//

import Foundation
import SwiftUI

/// The registry and its transfers are main-thread state, like the
/// interface showing them.
@MainActor
public class FileTransferManager: ObservableObject {
    public static let shared = FileTransferManager()

    private init() {}

    @Published public var transfers: [FileTransferContext] = []

    public func begin(for machineId: RDMachine.ID, force: Bool = false) {
        debugPrint("\(self) \(#function) \(machineId)")
        if !force {
            for transfer in transfers where transfer.machine.id == machineId {
                FileTransferInterface.uiHandler.requiresConfirmation(
                    "Another file transfer for this machine is already running"
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
            FileTransferInterface.uiHandler.presentError("Unknown Bad Data")
            return
        }
        var get: RDIdentity?
        if let sid = machine.associatedIdentity,
           let uid = UUID(uuidString: sid),
           TamioStore.shared.identityGroup[uid].hasCredentials
        {
            get = TamioStore.shared.identityGroup[uid]
        }
        let object = FileTransferContext(machine: machine, identity: get)
        transfers.append(object)
    }

    public func end(for contextId: UUID) {
        onMainThread { [self] in
            debugPrint("\(self) \(#function) \(contextId)")
            let index = transfers.firstIndex { $0.id == contextId }
            guard let index = index else { return }
            let sftp = transfers.remove(at: index)
            sftp.processShutdown()
            sftp.destroyedSession = true
        }
    }

    public func closeAll() {
        guard !transfers.isEmpty else { return }
        let open = transfers
        transfers = []
        for sftp in open {
            sftp.processShutdown()
            sftp.destroyedSession = true
        }
    }
}
