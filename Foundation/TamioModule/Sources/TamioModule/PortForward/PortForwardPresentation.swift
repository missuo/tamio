//
//  PortForwardPresentation.swift
//  TamioModule
//
//  What a port-forward row shows for a session state: a dot and a word.
//  Shared by the macOS and iOS tables so the two cannot drift apart.
//

import Foundation
import TamioDesign

public struct PortForwardPresentation: Equatable {
    public let status: RXStatus
    public let text: String

    /// `running` is whether the backend still holds the session. A
    /// finished session's last state keeps showing in the row, and a
    /// fresh row has no state yet, so both inputs matter.
    public init(state: PortForwardContext.Lifecycle?, running: Bool) {
        switch state {
        case .awaitingConnect, .openingChannel:
            (status, text) = (.running, String(localized: "Connecting"))
        case .forwardRunning:
            (status, text) = running ? (.success, String(localized: "Running")) : (.off, String(localized: "Stopped"))
        case .failedConnect:
            (status, text) = (.danger, String(localized: "Could not connect"))
        case .failedAuthenticate:
            (status, text) = (.danger, String(localized: "Could not sign in"))
        case .forwardStopped:
            (status, text) = running ? (.danger, String(localized: "Forward ended")) : (.off, String(localized: "Stopped"))
        case .terminating, .terminated, .none:
            (status, text) = running ? (.running, String(localized: "Starting")) : (.off, String(localized: "Stopped"))
        }
    }
}
