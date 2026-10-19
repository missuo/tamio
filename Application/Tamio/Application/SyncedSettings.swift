//
//  SyncedSettings.swift
//  Tamio (macOS)
//
//  The preferences in Settings that iCloud sync keeps the same on every Mac.
//  Left out on purpose: whether the MCP server runs and which agents may act
//  without asking (an approval on one Mac must not hold on another), update
//  checks, and the diagnostic log.
//

import MachineStatusView
import TamioModule
import TamioTerminal
import AppKit

@MainActor
enum SyncedSettings {
    /// The keys name each preference in iCloud: never change one.
    static var all: [SyncedPreference] {
        let store = TamioStore.shared
        let defaults = UserDefaults.standard
        return [
            .string(
                AppearancePreference.key,
                get: { defaults.string(forKey: AppearancePreference.key) ?? AppearancePreference.system.rawValue },
                set: { raw in
                    guard raw != defaults.string(forKey: AppearancePreference.key),
                          let appearance = AppearancePreference(rawValue: raw)
                    else { return }
                    defaults.set(raw, forKey: AppearancePreference.key)
                    appearance.apply(crossFade: true)
                }
            ),
            SyncedPreference(
                "sb.moe.tamio.ghosttyConfiguration",
                read: { TerminalConfigurationSync.value.map { .data($0) } },
                write: { if case let .data(data) = $0 { TerminalConfigurationSync.adopt(data) } }
            ),
            .int(
                "sb.moe.tamio.terminalFontSize",
                get: { store.terminalFontSize },
                set: { if store.terminalFontSize != $0 { store.terminalFontSize = $0 } }
            ),
            .bool(
                "sb.moe.tamio.openInterfaceAutomatically",
                get: { store.openInterfaceAutomatically },
                set: { if store.openInterfaceAutomatically != $0 { store.openInterfaceAutomatically = $0 } }
            ),
            .bool(
                "sb.moe.tamio.disableConformation",
                get: { store.disableConformation },
                set: { if store.disableConformation != $0 { store.disableConformation = $0 } }
            ),
            .bool(
                FilesPreference.showsHiddenKey,
                get: { defaults.bool(forKey: FilesPreference.showsHiddenKey) },
                set: { if defaults.bool(forKey: FilesPreference.showsHiddenKey) != $0 { defaults.set($0, forKey: FilesPreference.showsHiddenKey) } }
            ),
            .int(
                "sb.moe.tamio.timeout",
                get: { store.timeout },
                set: { if store.timeout != $0 { store.timeout = $0 } }
            ),
            .bool(
                LiveStatusCenter.enabledKey,
                get: { LiveStatusCenter.shared.isEnabled },
                set: { if LiveStatusCenter.shared.isEnabled != $0 { LiveStatusCenter.shared.isEnabled = $0 } }
            ),
            .int(
                "sb.moe.tamio.monitorInterval",
                get: { store.monitorInterval },
                set: { if store.monitorInterval != $0 { store.monitorInterval = $0 } }
            ),
        ]
    }
}
