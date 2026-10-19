import AppKit
import SwiftUI
import TamioDesign
import TamioModule

@MainActor
private final class SSHConfigImportModel: ObservableObject {
    @Published var source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
    @Published var scan: OpenSSHScan?
    @Published var candidates: [OpenSSHImportCandidate] = []
    @Published var choices: [String: SSHConfigImportChoice] = [:]
    @Published var busy = false
    @Published var error: String?
    @Published var summary: String?
    @Published var asksForTrust = false
    private var operation: Task<Void, Never>?

    func load(store: TamioStore) {
        cancel()
        scan = nil
        candidates = []
        choices = [:]
        error = nil
        summary = nil
        busy = true
        let path = source
        operation = Task {
            do {
                let worker = Task.detached { try OpenSSHConfigScanner.scan(path: path) }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                scan = result
                if result.requiresTrust {
                    busy = false
                    asksForTrust = true
                } else {
                    await resolve(result, trusted: false, store: store)
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    func trust(store: TamioStore) {
        guard let scan else { return }
        busy = true
        operation = Task { await resolve(scan, trusted: true, store: store) }
    }

    private func resolve(_ scan: OpenSSHScan, trusted: Bool, store: TamioStore) async {
        do {
            let resolved = try await OpenSSHConfigResolver.resolve(scan: scan, trusted: trusted)
            try Task.checkCancellation()
            candidates = OpenSSHImportPlanner.plan(scan: scan, resolved: resolved,
                                                   machines: store.machineGroup.machines,
                                                   identities: store.identityGroup.identities)
            choices = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
                var choice = SSHConfigImportChoice()
                choice.selected = candidate.status == .ready && candidate.existing == nil
                if let identity = candidate.machine.associatedIdentity { choice.credential = identity }
                return (candidate.id, choice)
            })
            busy = false
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            busy = false
        }
    }

    func cancel() {
        operation?.cancel()
        operation = nil
        busy = false
    }

    var selected: [OpenSSHImportCandidate] {
        candidates.filter { choices[$0.id]?.selected == true }
    }

    var canImport: Bool {
        TamioStore.savesChanges && !busy && !selected.isEmpty && selected.allSatisfy { candidate in
            guard candidate.canImport, let choice = choices[candidate.id] else { return false }
            if candidate.existing != nil && !choice.replace { return false }
            if choice.credential.hasPrefix("file:") && !choice.importKey { return false }
            if choice.credential == "none" && !choice.reviewed { return false }
            if (candidate.status == .needsReview || candidate.status == .needsCredentials || !candidate.diagnostics.isEmpty) && !choice.reviewed { return false }
            return true
        }
    }

    func commit(store: TamioStore) {
        guard canImport else { return }
        let machinesBefore = store.machineGroup.machines
        let identitiesBefore = store.identityGroup.identities
        let candidatesBefore = candidates
        let selections = selected.map { candidate in
            let choice = choices[candidate.id] ?? SSHConfigImportChoice()
            let credential: OpenSSHCredentialChoice
            if choice.credential.hasPrefix("file:") {
                credential = .importFile(String(choice.credential.dropFirst(5)), passphrase: choice.passphrase)
            } else if let id = UUID(uuidString: choice.credential) {
                credential = .existing(id)
            } else {
                credential = .none
            }
            return OpenSSHImportSelection(alias: candidate.id, credential: credential,
                                          replaceExisting: choice.replace, acknowledgeWarnings: choice.reviewed)
        }
        busy = true
        operation = Task {
            do {
                let worker = Task.detached {
                    try OpenSSHImportPlanner.prepare(candidates: candidatesBefore, selections: selections,
                                                     machines: machinesBefore, identities: identitiesBefore)
                }
                let batch = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard store.machineGroup.machines == machinesBefore,
                      store.identityGroup.identities == identitiesBefore,
                      TamioStore.savesChanges else {
                    error = String(localized: "Saved servers or identities changed. Preview again before importing.")
                    busy = false
                    return
                }
                // Publish only after every selected key and host validates. There
                // is no suspension between the stale-data check and publication.
                var identities = store.identityGroup
                var machines = store.machineGroup
                identities.items = batch.identities
                machines.items = batch.machines
                store.identityGroup = identities
                store.machineGroup = machines
                summary = String(localized: "Created \(batch.created) servers and updated \(batch.updated) servers.")
                choices = [:]
                candidates = []
                error = nil
                busy = false
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

private struct SSHConfigImportChoice {
    var selected = false
    var credential = "none"
    var passphrase = ""
    var importKey = false
    var replace = false
    var reviewed = false
}

struct SSHConfigImportSheet: View {
    @EnvironmentObject private var store: TamioStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SSHConfigImportModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import from SSH Config").font(.rxSheetTitle)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .padding(RX.Space.s5)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: RX.Space.s4) {
                    sourceSection
                    if !TamioStore.savesChanges {
                        Text("Import is unavailable while Tamio’s encryption key is locked. Unlock the keychain and reopen Tamio.")
                            .foregroundStyle(.red)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let summary = model.summary {
                        Label(summary, systemImage: "checkmark.circle").font(.headline)
                    } else {
                        safetyNotice
                        if let scan = model.scan {
                            ForEach(scan.warnings, id: \.self) { Text($0).foregroundStyle(.secondary) }
                            if scan.requiresTrust && model.candidates.isEmpty && !model.busy {
                                Button("Review configuration trust…") { model.asksForTrust = true }
                            }
                        }
                        if !model.candidates.isEmpty {
                            HStack {
                                Text("\(model.candidates.count) hosts found · \(model.selected.count) selected")
                                Spacer()
                                Button("Select importable hosts") {
                                    for candidate in model.candidates where candidate.canImport && candidate.existing == nil {
                                        model.choices[candidate.id]?.selected = true
                                    }
                                }
                                Button("Deselect all") {
                                    for id in model.choices.keys { model.choices[id]?.selected = false }
                                }
                            }
                            ForEach(model.candidates) { candidate in
                                SSHConfigImportRow(candidate: candidate,
                                                   identities: store.identityGroup.identities.filter {
                                                       $0.hasCredentials && (!$0.isPrivate || $0.id.uuidString == candidate.existing?.associatedIdentity)
                                                   },
                                                   choice: Binding(get: { model.choices[candidate.id] ?? SSHConfigImportChoice() },
                                                                   set: { model.choices[candidate.id] = $0 }))
                                .disabled(model.busy)
                            }
                        } else if model.scan != nil && !model.busy && !model.asksForTrust && model.error == nil && model.scan?.requiresTrust == false {
                            Text("No concrete Host aliases found. Wildcard-only blocks provide defaults, not servers.")
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(RX.Space.s5)
            }
            Hairline()
            HStack {
                if model.summary == nil {
                    Text("No changes until confirmed").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.summary == nil ? String(localized: "Cancel") : String(localized: "Done")) {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if model.summary == nil {
                    Button("Import Selected") { model.commit(store: store) }
                        .buttonStyle(.rx(.primary))
                        .disabled(!model.canImport)
                }
            }
            .padding(RX.Space.s5)
        }
        .frame(minWidth: 680, idealWidth: 780, maxWidth: 1000, minHeight: 500, idealHeight: 700)
        .background(Color.rxSurface)
        .onDisappear { model.cancel() }
        .alert("Trust this SSH configuration?", isPresented: $model.asksForTrust) {
            Button("Cancel", role: .cancel) { }
            Button("Trust and Resolve") { model.trust(store: store) }
        } message: {
            Text("OpenSSH may execute local commands from Match exec or read files that could not be inspected. Continue only if you trust this configuration and every included file. No SSH connection is opened during resolution.")
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            Text("Discover existing OpenSSH hosts and choose what to import.")
            TextField("~/.ssh/config", text: $model.source, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.rx)
                .disabled(model.busy)
                .onSubmit { model.load(store: store) }
                .onChange(of: model.source) {
                    model.scan = nil
                    model.candidates = []
                    model.choices = [:]
                    model.summary = nil
                    model.error = nil
                }
            HStack {
                Button("Use ~/.ssh/config") {
                    model.source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
                    model.load(store: store)
                }
                Button("Choose another config file…") { chooseSource() }
                Button("Preview") { model.load(store: store) }
            }
            .disabled(model.busy)
        }
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            Text("The original configuration is never modified. This is a one-time import, not background synchronization.")
            Text("OpenSSH known_hosts is not imported. Tamio keeps its own host-key verification and records a key on first connection; insecure OpenSSH trust settings are not copied.")
            Text("Private keys are copied only when you explicitly choose Import this private key. If Identities iCloud Sync is enabled, imported keys join Tamio’s end-to-end encrypted sync.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = String(localized: "Choose an OpenSSH configuration file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.source = url.path
        model.load(store: store)
    }
}

private struct SSHConfigImportRow: View {
    let candidate: OpenSSHImportCandidate
    let identities: [RDIdentity]
    @Binding var choice: SSHConfigImportChoice

    private var status: LocalizedStringKey {
        switch candidate.status {
        case .ready: "Ready"
        case .needsCredentials: choice.credential == "none" ? "Needs credentials" : "Needs review"
        case .needsReview: "Needs review"
        case .alreadyExists: "Already exists"
        case .unsupported: "Unsupported"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            HStack(alignment: .top) {
                Toggle(isOn: $choice.selected) { Text(candidate.id).font(.headline) }
                    .toggleStyle(.checkbox)
                    .disabled(!candidate.canImport)
                Spacer()
                Text(status).foregroundStyle(.secondary)
            }
            Text("\(candidate.machine.username)@\(candidate.machine.remoteAddress):\(candidate.machine.remotePort)")
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text("\(candidate.host.candidate.source.path):\(candidate.host.candidate.source.line)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(candidate.diagnostics, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            if choice.selected {
                credentialSection
                if let existing = candidate.existing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Existing: \(existing.name) — \(existing.username)@\(existing.remoteAddress):\(existing.remotePort)")
                        if existing.proxyCommand != candidate.machine.proxyCommand {
                            Text("Previous proxy: \(existing.proxyCommand)")
                            Text("Imported proxy: \(candidate.machine.proxyCommand)")
                        }
                        Toggle("Replace this existing server’s connection settings", isOn: $choice.replace)
                    }
                }
                Toggle("I reviewed the warnings and credential choice", isOn: $choice.reviewed)
                    .toggleStyle(.checkbox)
            }
            DisclosureGroup("Effective OpenSSH settings") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidate.host.options.keys.sorted(), id: \.self) { key in
                        Text("\(key) \((candidate.host.options[key] ?? []).joined(separator: "\n"))")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .rxCard()
    }

    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            Picker("Credentials", selection: $choice.credential) {
                Text("Configure credentials later").tag("none")
                ForEach(identities) { identity in
                    Text(identity.displayName).tag(identity.id.uuidString)
                }
                ForEach(candidate.identityFiles, id: \.self) { path in
                    Text("Import key: \(path)").tag("file:" + path)
                }
            }
            .onChange(of: choice.credential) {
                choice.importKey = false
                choice.passphrase = ""
                choice.reviewed = false
            }
            if choice.credential.hasPrefix("file:") {
                Text(String(choice.credential.dropFirst(5))).textSelection(.enabled)
                Toggle("Import this private key into Tamio", isOn: $choice.importKey)
                    .toggleStyle(.checkbox)
                SecureField("Key passphrase (only if encrypted)", text: $choice.passphrase)
                    .textFieldStyle(.rx)
                Text("A passphrase you enter is saved with this identity. It is never read from Keychain automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if choice.credential == "none" {
                Text("This server will be saved without credentials. Configure an identity before connecting.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
