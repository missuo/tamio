//
//  RDPortForward.swift
//
//
//  Created by Lakr Aream on 2022/3/10.
//

import Foundation
import NSRemoteShell

public struct RDPortForward: Codable, Identifiable, Equatable, Sendable {
    public init(
        id: UUID = .init(),
        forwardOrientation: ForwardOrientation = .listenLocal,
        bindPort: Int = 0,
        targetHost: String = "",
        targetPort: Int = 0,
        usingMachine: RDMachine.ID? = nil,
        attachment: [String: String] = [:]
    ) {
        self.id = id
        self.forwardOrientation = forwardOrientation
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.usingMachine = usingMachine
        self.attachment = attachment
    }

    public var id: UUID

    public enum ForwardOrientation: String, Codable, CaseIterable, Sendable {
        case listenLocal = "Local"
        case listenRemote = "Remote"
    }

    public var forwardOrientation: ForwardOrientation = .listenLocal

    public var forwardReversed: Bool {
        get {
            forwardOrientation == .listenRemote
        }
        set {
            switch newValue {
            case true: forwardOrientation = .listenRemote
            case false: forwardOrientation = .listenLocal
            }
        }
    }

    public var bindPort: Int // UInt32 maybe?

    public var targetHost: String
    public var targetPort: Int // UInt32 maybe?

    public var usingMachine: RDMachine.ID?

    public var attachment: [String: String]

    public func isValid() -> Bool {
        guard bindPort >= 0, bindPort <= 65535,
              !targetHost.isEmpty,
              targetPort >= 0, targetPort <= 65535,
              let machine = usingMachine,
              TamioStore.shared.machineGroup[machine].isNotPlaceholder()
        else {
            return false
        }
        return true
    }

    public func getMachineName() -> String? {
        guard let mid = usingMachine else {
            return nil
        }
        let machine = TamioStore.shared.machineGroup[mid]
        if machine.isNotPlaceholder() {
            return machine.name
        }
        return nil
    }

    public func shortDescription() -> String {
        guard isValid() else {
            return String(localized: "Invalid Forward")
        }
        switch forwardOrientation {
        case .listenLocal:
            return "localhost:\(bindPort) -\(getMachineName() ?? String(localized: "Unknown"))-> \(targetHost):\(targetPort)"
        case .listenRemote:
            return "\(getMachineName() ?? String(localized: "Unknown")):\(bindPort) -localhost-> \(targetHost):\(targetPort)"
        }
    }

    public func getCommand() -> String? {
        guard isValid(), let using = usingMachine else {
            return nil
        }
        let machineCommand = TamioStore.shared.machineGroup[using]
        switch forwardOrientation {
        case .listenLocal:
            return "ssh -L \(bindPort):\(targetHost):\(targetPort) \(machineCommand.getCommand(insertLeadingSSH: false))"
        case .listenRemote:
            return "ssh -R \(bindPort):\(targetHost):\(targetPort) \(machineCommand.getCommand(insertLeadingSSH: false))"
        }
    }
}

extension RDPortForward: RDGroupItem {
    public init() { self.init(id: UUID()) }
}
