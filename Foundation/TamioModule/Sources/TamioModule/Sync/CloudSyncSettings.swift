//
//  CloudSyncSettings.swift
//  TamioModule
//
//  The rows of Settings › General › iCloud Sync, the same on the Mac and on iOS.
//

import TamioDesign
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

public struct CloudSyncSettings: View {
    @ObservedObject private var sync = CloudSync.shared
    @State private var asking: PassphraseSheet.Purpose?
    @State private var confirmsDelete = false
    /// The passphrase, while the user has it showing.
    @State private var shown: String?

    public init() {}

    public var body: some View {
        RXDividedStack {
            RXFormRow("Sync with iCloud", description: (sync.isOn ? nil : sync.problem) ?? String(localized: """
            On unless you turn it off, so your servers and what agents did on them are never lost \
            with a Mac. Everything is encrypted on this device before it goes to iCloud, under a \
            passphrase kept in your iCloud Keychain, so your other Macs sync by themselves. Apple \
            cannot read it.
            """)) {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { sync.isOn },
                    set: { on in
                        if on {
                            asking = sync.hasStoredData ? .enter : .create
                        } else {
                            sync.turnOff()
                        }
                    }
                ))
                .labelsHidden()
                .rxSwitchToggle()
                .tint(.rxAccent)
                #if os(macOS) || targetEnvironment(macCatalyst)
                    .controlSize(.small)
                #endif
                    .disabled(sync.problem != nil && !sync.isOn)
            }
            if sync.isOn {
                RXFormRow("Status", description: statusText) {
                    HStack(spacing: RX.Space.s2) {
                        switch sync.status {
                        case .locked:
                            Button("Enter Passphrase…") { asking = .enter }
                                .buttonStyle(.rx(size: .small))
                            Button("Replace…") { asking = .change }
                                .buttonStyle(.rx(size: .small))
                        case .unreadable:
                            Button("Replace…") { asking = .change }
                                .buttonStyle(.rx(size: .small))
                        case .unavailable, .off:
                            EmptyView()
                        case .syncing, .synced, .failed:
                            Button("Sync Now") { sync.sync() }
                                .buttonStyle(.rx(size: .small))
                                .disabled(sync.status == .syncing)
                        }
                    }
                }
                SwitchRow("Servers", description: "Addresses, names, groups and comments.", isOn: $sync.syncsServers)
                SwitchRow(
                    "Identities",
                    description: "User names, passwords and private keys.",
                    isOn: $sync.syncsIdentities
                )
                SwitchRow("Snippets", description: "Saved commands and their groups.", isOn: $sync.syncsSnippets)
                SwitchRow("Port forwards", description: "Local and remote forwards, and the server each uses.", isOn: $sync.syncsPortForwards)
                SwitchRow(
                    "Known hosts",
                    description: "The servers' keys: one trusted on a device is trusted on the others.",
                    isOn: $sync.syncsKnownHosts
                )
                SwitchRow(
                    "Settings",
                    description: "Appearance, the terminal's configuration, sessions, hidden files, the connection timeout and live status.",
                    isOn: $sync.syncsSettings
                )
                SwitchRow(
                    "Agent activity",
                    description: "What agents did on each server, so agents on other devices know.",
                    isOn: $sync.syncsActivity
                )
                RXFormRow("Passphrase", description: shown.map { String(localized: "\($0) — type it on a device without iCloud Keychain.") }
                    ?? String(localized: "Your other devices take it from iCloud Keychain, or ask for it."))
                {
                    HStack(spacing: RX.Space.s2) {
                        if let passphrase = sync.currentPassphrase {
                            Button(shown == nil ? String(localized: "Show") : String(localized: "Hide")) { shown = shown == nil ? passphrase : nil }
                                .buttonStyle(.rx(size: .small))
                            #if canImport(UIKit)
                                if shown != nil {
                                    Button("Copy") { UIPasteboard.general.string = passphrase }
                                        .buttonStyle(.rx(size: .small))
                                }
                            #endif
                        }
                        Button("Change…") { asking = .change }
                            .buttonStyle(.rx(size: .small))
                    }
                }
                RXFormRow("Data in iCloud", description: "Remove it and stop syncing on this device.") {
                    Button("Delete…") { confirmsDelete = true }
                        .buttonStyle(.rx(size: .small))
                }
            }
        }
        .sheet(item: $asking) { purpose in
            PassphraseSheet(purpose: purpose) { passphrase in
                switch purpose {
                case .create, .enter: sync.turnOn(passphrase: passphrase)
                case .change: sync.replaceStoredData(passphrase: passphrase)
                }
            }
        }
        .alert("Delete what Tamio keeps in iCloud?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { sync.deleteStoredData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Your servers and identities stay on this device. A device that still syncs will store \
            its own again, so turn sync off there too.
            """)
        }
    }

    private var statusText: String {
        switch sync.status {
        case .off: return ""
        case let .unavailable(reason): return reason
        case .syncing: return String(localized: "Syncing…")
        case let .synced(date):
            return String(localized: "Up to date. Last synced at \(date.formatted(date: .omitted, time: .shortened)).")
        case .locked:
            return String(localized: """
            The passphrase on this device does not open what is in iCloud. Enter the one your \
            other device uses, or replace what is stored with this device's data.
            """)
        case .unreadable:
            return String(localized: "What is in iCloud cannot be read. Replace it with this device's data to go on.")
        case let .failed(reason): return reason
        }
    }
}

private struct PassphraseSheet: View {
    enum Purpose: String, Identifiable {
        /// The first device: choose a passphrase.
        case create
        /// Another device stored data already: give its passphrase.
        case enter
        /// Choose a new passphrase and store this device's data under it.
        case change

        var id: String { rawValue }
    }

    let purpose: Purpose
    let done: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var again = ""
    @FocusState private var focused: Bool

    private var chooses: Bool { purpose != .enter }

    private var problem: String? {
        guard chooses else { return nil }
        if passphrase.isEmpty { return nil }
        if passphrase.count < CloudSync.minimumPassphraseLength {
            return String(localized: "At least \(CloudSync.minimumPassphraseLength) characters.")
        }
        if !again.isEmpty, again != passphrase { return String(localized: "The two do not match.") }
        return nil
    }

    private var ready: Bool {
        if chooses {
            return passphrase.count >= CloudSync.minimumPassphraseLength && again == passphrase
        }
        return !passphrase.isEmpty
    }

    private var title: String {
        switch purpose {
        case .create: return String(localized: "Choose a Passphrase")
        case .enter: return String(localized: "Enter Your Passphrase")
        case .change: return String(localized: "Choose a New Passphrase")
        }
    }

    private var lead: String {
        switch purpose {
        case .create:
            return String(localized: """
            It encrypts your servers and identities before they leave this device. You will \
            enter it once on each of your devices. It cannot be recovered if you forget it.
            """)
        case .enter:
            return String(localized: "iCloud already holds data from one of your devices. Enter the passphrase you chose there.")
        case .change:
            return String(localized: """
            What is in iCloud is replaced with this device's servers and identities, encrypted \
            with the new passphrase. Your other devices will ask for it.
            """)
        }
    }

    var body: some View {
        SheetScaffold(title, lead: lead) {
            VStack(alignment: .leading, spacing: RX.Space.s4) {
                RXField("Passphrase", error: chooses ? nil : problem) {
                    SecureField("", text: $passphrase)
                        .textFieldStyle(.rx)
                        .focused($focused)
                        .onSubmit(submit)
                }
                if chooses {
                    RXField("Again", error: problem) {
                        SecureField("", text: $again)
                            .textFieldStyle(.rx)
                            .onSubmit(submit)
                    }
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(purpose == .change ? String(localized: "Replace") : String(localized: "Turn On"), action: submit)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
        }
        #if targetEnvironment(macCatalyst) || os(macOS)
        .frame(width: 440)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        #endif
        .onAppear { focused = true }
    }

    private func submit() {
        guard ready else { return }
        done(passphrase)
        dismiss()
    }
}
