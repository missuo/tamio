//
//  RDMachine+Redacted.swift
//  Tamio (macOS)
//
//  Created by Lakr Aream on 2022/3/1.
//

import Foundation

public extension RDMachine {
    enum RedactedLevel: Int, Codable {
        case none = 0
        case sensitive = 1
        case all = 2
    }
}

public extension RDMachine.RedactedLevel {
    /// Hover tooltip describing the current redaction state.
    var tooltip: String {
        switch self {
        case .none:
            return String(localized: "Show Everything")
        case .sensitive:
            return String(localized: "Hide Addresses")
        case .all:
            return String(localized: "Hide Names and Addresses")
        }
    }
}
