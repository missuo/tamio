//
//  IdentitiesView.swift
//  Tamio (macOS)
//
//  Identities grouped by group, with the editor beside the list. An identity
//  is a credential, a password or a key; the user it signs in as belongs to
//  each server.
//

import TamioModule
import SwiftUI

struct IdentitiesView: View {
    @EnvironmentObject var store: TamioStore

    @State private var searchText = ""
    @State private var selection: RDIdentity.ID?
    @State private var creating = false

    var filtered: [RDIdentity] {
        let all = store.identityGroup.shared
        guard !searchText.isEmpty else { return all }
        let key = searchText.lowercased()
        return all.filter {
            $0.name.lowercased().contains(key)
                || $0.group.lowercased().contains(key)
                || $0.comment.lowercased().contains(key)
        }
    }

    var groups: [(name: String, identities: [RDIdentity])] {
        let identities = filtered
        let names = Set(identities.map(\.group)).sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.map { name in
            (name, identities.filter { $0.group == name }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
        }
    }

    var body: some View {
        PageScaffold(
            search: $searchText,
            searchPrompt: "Search identities",
            primary: ToolbarAction("New Key", systemImage: "plus", primary: true) { creating = true }
        ) {
        } trailing: {
        } header: {
            PageTitle("Identities")
        } content: {
            if store.identityGroup.shared.isEmpty {
                EmptyStateView(
                    "No identities yet",
                    systemImage: "person",
                    message: "SSH keys you can use on any server, as any user.",
                    actionTitle: "New Key"
                ) {
                    creating = true
                }
                .rxCard()
            } else {
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    list
                        .frame(width: 320)
                    if let selection, store.identityGroup.shared.contains(where: { $0.id == selection }) {
                        IdentityDetail(identity: selection)
                            .id(selection)
                    } else {
                        EmptyStateView("Select an identity", systemImage: "person")
                        .rxCard()
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            IdentityEditorSheet { created in
                creating = false
                if let created { selection = created }
            }
            .environmentObject(TamioStore.shared)
        }
        .onAppear {
            if selection == nil { selection = groups.first?.identities.first?.id }
        }
    }

    var list: some View {
        VStack(spacing: 0) {
            if filtered.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
            }
            ForEach(groups, id: \.name) { group in
                TableGroupRow(group.name.isEmpty ? String(localized: "Default") : group.name)
                    .transition(.opacity)
                ForEach(Array(group.identities.enumerated()), id: \.element.id) { index, identity in
                    IdentityRow(identity: identity, selected: selection == identity.id)
                        .onTapGesture { selection = identity.id }
                        .rxRise(index)
                        .transition(.opacity)
                }
            }
        }
        .animation(.rxMove, value: groups.flatMap { $0.identities.map(\.id) })
        .rxCard(padding: RX.Space.s2)
    }
}

private struct IdentityRow: View {
    let identity: RDIdentity
    let selected: Bool
    @EnvironmentObject var store: TamioStore
    @State private var hovered = false

    var usage: Int {
        store.machineGroup.machines.filter { $0.associatedIdentity == identity.id.uuidString }.count
    }

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(identity.displayName)
                    .font(.rxBody)
                    .foregroundStyle(Color.rxInk)
                    .lineLimit(1)
                Text(identity.authDescription)
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
            }
            Spacer()
            Text(usage == 1 ? String(localized: "1 server") : String(localized: "\(usage) servers"))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableRowHeight)
        .rxRowBackground(selected: selected, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Duplicate") { IdentityActions.duplicate(identity.id) }
            Button("Copy Public Key") { Dialogs.sendPasteboard(str: identity.publicKey) }
                .disabled(identity.publicKey.isEmpty)
            Divider()
            Button("Delete…", role: .destructive) { IdentityActions.delete(identity.id) }
        }
    }
}

enum IdentityActions {
    static func duplicate(_ id: RDIdentity.ID) {
        var copy = TamioStore.shared.identityGroup[id]
        guard copy.hasCredentials else { return }
        copy.id = UUID()
        copy.name = copy.displayName + " copy"
        TamioStore.shared.identityGroup.insert(copy)
    }

    static func delete(_ id: RDIdentity.ID) {
        let store = TamioStore.shared
        let identity = store.identityGroup[id]
        let users = store.machineGroup.machines.filter { $0.associatedIdentity == id.uuidString }.count
        Dialogs.requiresConfirmation(
            message: String(localized: "Delete identity \(identity.displayName)?"),
            informative: users > 0
                ? (users == 1 ? String(localized: "1 server uses it and will try automatic identities instead.") : String(localized: "\(users) servers use it and will try automatic identities instead."))
                : String(localized: "Its password and keys are removed from Tamio."),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            store.identityGroup.delete(id)
        }
    }
}

/// The editor beside the list.
private struct IdentityDetail: View {
    let identity: RDIdentity.ID
    @EnvironmentObject var store: TamioStore
    @State private var draft = IdentityDraft()
    @State private var loaded = false

    var original: RDIdentity { store.identityGroup[identity] }

    var usedBy: [String] {
        store.machineGroup.machines
            .filter { $0.associatedIdentity == identity.uuidString }
            .map(\.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                // The name is the first field below; the header says where
                // the identity is used.
                HelpText(usageLine.isEmpty ? String(localized: "Not used by any server") : usageLine)
                Spacer()
                Menu {
                    Button("Duplicate") { IdentityActions.duplicate(identity) }
                    Divider()
                    Button("Delete…", role: .destructive) { IdentityActions.delete(identity) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.rx(.plain, iconOnly: true))
                .fixedSize()
            }
            IdentityForm(draft: $draft)
                .padding(.top, RX.Space.s5)
            HStack(spacing: RX.Space.s2) {
                Spacer()
                Button("Revert") { draft = IdentityDraft(original) }
                    .buttonStyle(.rx)
                    .disabled(!draft.differs(from: original))
                Button("Save") {
                    store.identityGroup.insert(draft.apply(to: original))
                }
                .buttonStyle(.rxPrimary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!draft.differs(from: original) || !draft.isValid)
            }
            .padding(.top, RX.Space.s4)
        }
        .rxCard()
        .frame(maxWidth: .infinity)
        .onAppear {
            draft = IdentityDraft(original)
        }
        .onDisappear {
            // Keep edits when another identity is selected.
            let stillExists = store.identityGroup.identities.contains { $0.id == identity }
            if stillExists, draft.differs(from: original), draft.isValid {
                store.identityGroup.insert(draft.apply(to: original))
            }
        }
    }

    var usageLine: String {
        let names = usedBy
        guard !names.isEmpty else { return "" }
        let shown = names.prefix(4).joined(separator: ", ")
        let more = names.count > 4 ? " " + String(localized: "and \(names.count - 4) more") : ""
        return String(localized: "Used by \(shown)\(more)")
    }
}

/// Editable copy of an identity.
struct IdentityDraft: Equatable {
    enum Method: Hashable {
        case key
        case password
    }

    var name = ""
    var group = ""
    var method: Method = .key
    var password = ""
    var privateKey = ""
    var publicKey = ""
    var comment = ""
    var automatic = false

    init() {}

    init(_ identity: RDIdentity) {
        name = identity.name
        group = identity.group
        method = identity.privateKey.isEmpty && !identity.password.isEmpty ? .password : .key
        password = identity.password
        privateKey = identity.privateKey
        publicKey = identity.publicKey
        comment = identity.comment
        automatic = identity.authenticAutomatically
    }

    var trimmedPrivateKey: String { privateKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the identity cannot be saved yet, or nil.
    var problem: String? {
        switch method {
        case .password:
            return password.isEmpty ? String(localized: "Type the password.") : nil
        case .key:
            if trimmedPrivateKey.isEmpty { return String(localized: "Paste or load the private key.") }
            if !trimmedPrivateKey.contains("PRIVATE KEY") {
                return trimmedPrivateKey.hasPrefix("ssh-") || trimmedPrivateKey.hasPrefix("ecdsa-")
                    ? String(localized: "That is a public key. The private key starts with -----BEGIN … PRIVATE KEY-----.")
                    : String(localized: "This does not look like a private key: it starts with -----BEGIN … PRIVATE KEY-----.")
            }
            return nil
        }
    }

    var isValid: Bool { problem == nil }

    func apply(to identity: RDIdentity) -> RDIdentity {
        var result = identity
        result.name = name.trimmingCharacters(in: .whitespaces)
        result.group = group
        switch method {
        case .password:
            result.password = password
            result.privateKey = ""
            result.publicKey = ""
        case .key:
            // The password field is the key's passphrase.
            result.password = password
            result.privateKey = trimmedPrivateKey + "\n"
            result.publicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        result.comment = comment
        result.authenticAutomatically = automatic
        return result
    }

    /// RDIdentity compares by id only, so compare the edited fields.
    func differs(from identity: RDIdentity) -> Bool {
        let edited = apply(to: identity)
        return edited.name != identity.name
            || edited.group != identity.group
            || edited.password != identity.password
            || edited.privateKey != identity.privateKey
            || edited.publicKey != identity.publicKey
            || edited.comment != identity.comment
            || edited.authenticAutomatically != identity.authenticAutomatically
    }
}

/// Name, Group, the key (pasted, loaded or generated), Passphrase, Comment.
/// No username: that is set on each server. Identities are SSH keys; one
/// saved with a password before keeps it, editable here.
struct IdentityForm: View {
    @Binding var draft: IdentityDraft
    @EnvironmentObject var store: TamioStore
    @State private var showsSecret = false
    /// Whether the identity already was a password one when the form opened.
    @State private var allowsPassword: Bool?
    /// Whether the form opened with a private key, one already saved.
    @State private var savedPrivateKey = false

    var algorithm: String? {
        RDIdentity.keyAlgorithm(publicKey: draft.publicKey, privateKey: draft.privateKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: RX.Space.s4) {
                RXField("Name") {
                    TextField(draft.method == .key ? "Deploy key" : "Office password", text: $draft.name)
                        .textFieldStyle(.rx)
                        .disableAutocorrection(true)
                }
                RXField("Group") {
                    TextField("Default", text: $draft.group)
                        .textFieldStyle(.rx)
                }
            }
            if allowsPassword == true {
                RXField("Authentication") {
                    RXSegmented(selection: $draft.method, options: [
                        .init(.key, "SSH key"),
                        .init(.password, "Password"),
                    ], caps: false, fullWidth: true)
                }
            }
            if draft.method == .key {
                RXField(
                    "Private key",
                    help: draft.privateKey.isEmpty ? "Ed25519, RSA and ECDSA keys work, in OpenSSH or PEM format." : nil
                ) {
                    if draft.privateKey.isEmpty {
                        KeyEditor(
                            text: $draft.privateKey,
                            placeholder: "Paste the private key: -----BEGIN OPENSSH PRIVATE KEY-----",
                            loadTitle: "Load from File…",
                            height: 120
                        ) {
                            Button("Generate Ed25519 Key") { generate() }
                                .buttonStyle(.rx(size: .small))
                                .help(String(localized: "Make a new key pair; add its public key to the server's ~/.ssh/authorized_keys"))
                        }
                    } else {
                        // Once in, a private key is never shown again: not here,
                        // not in a copy. It can only be replaced.
                        SealedKeyRow(algorithm: algorithm) { replacePrivateKey() }
                    }
                }
                RXField("Public key", help: "Goes in the server's ~/.ssh/authorized_keys. Optional for signing in.") {
                    KeyEditor(
                        text: $draft.publicKey,
                        placeholder: "ssh-ed25519 AAAA… user@host",
                        loadTitle: "Load from File…",
                        height: 54
                    ) {
                        if !draft.publicKey.isEmpty {
                            Button("Copy") { Dialogs.sendPasteboard(str: draft.publicKey) }
                                .buttonStyle(.rx(size: .small))
                        }
                    }
                }
                RXField("Passphrase") {
                    secretField("None", text: $draft.password)
                }
            } else {
                RXField("Password") {
                    secretField("Required", text: $draft.password)
                }
            }
            RXField("Comment") {
                TextField("Optional", text: $draft.comment)
                    .textFieldStyle(.rx)
            }
            if let problem = draft.problem, !(draft.method == .key && draft.trimmedPrivateKey.isEmpty) {
                HelpText(problem, isError: true)
            }
        }
        .onAppear {
            if allowsPassword == nil {
                allowsPassword = draft.method == .password
                savedPrivateKey = !draft.privateKey.isEmpty
            }
        }
    }

    /// Clears the private key so another can be pasted, loaded or generated;
    /// asks first for a key that was already saved.
    func replacePrivateKey() {
        let clear = {
            draft.privateKey = ""
            draft.publicKey = ""
            draft.password = ""
        }
        guard savedPrivateKey else { return clear() }
        Dialogs.requiresConfirmation(
            message: String(localized: "Replace this private key?"),
            informative: String(localized: "The saved key is discarded when you save. Servers that trust it will not accept a new key until its public key is added."),
            confirmTitle: String(localized: "Replace"),
            destructive: true
        ) { confirmed in
            if confirmed { clear() }
        }
    }

    func generate() {
        let replace = {
            // A text view being edited keeps its own text and writes it back
            // over a new value, so editing ends before the keys are filled in.
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async {
                let comment = draft.name.isEmpty ? "tamio" : draft.name.replacingOccurrences(of: " ", with: "-")
                let pair = SSHKeyGenerator.ed25519(comment: comment)
                draft.privateKey = pair.privateKey
                draft.publicKey = pair.publicKey
                draft.password = ""
                if draft.name.isEmpty { draft.name = "Ed25519 key" }
            }
        }
        replace()
    }

    func secretField(_ placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: RX.Space.s1) {
            Group {
                if showsSecret {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textFieldStyle(.rx)
            Button {
                showsSecret.toggle()
            } label: {
                Label(showsSecret ? "Hide" : "Show", systemImage: showsSecret ? "eye.slash" : "eye")
            }
            .buttonStyle(.rx(.plain, iconOnly: true))
            .help(showsSecret ? String(localized: "Hide") : String(localized: "Show"))
        }
    }
}

/// A private key that is in: its kind and a Replace button, never its text.
private struct SealedKeyRow: View {
    let algorithm: String?
    let replace: () -> Void

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(.rxInkSecondary)
            Text("••••••")
                .font(.rxCode)
                .foregroundStyle(.rxInkSecondary)
                .fixedSize()
            Text(algorithm.map(Self.title) ?? String(localized: "Private key"))
                .font(.rxBody)
                .foregroundStyle(.rxInk)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            Button("Replace…", action: replace)
                .buttonStyle(.rx(size: .small))
                .help(String(localized: "Paste, load or generate another key"))
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 40)
        .rxFieldBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(algorithm.map { String(localized: "\($0) private key, hidden") } ?? String(localized: "Private key, hidden"))
    }

    /// "Ed25519", "RSA", "ECDSA".
    static func title(_ algorithm: String) -> String {
        algorithm == "ed25519" ? "Ed25519" : algorithm.uppercased()
    }
}

/// A key typed or pasted in place, with Load from File…, Clear and any
/// extra buttons.
struct KeyEditor<Extra: View>: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    let loadTitle: LocalizedStringKey
    let height: CGFloat
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.rxCode)
                        .foregroundStyle(.rxInkTertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.rxCode)
                    .scrollContentBackground(.hidden)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .frame(height: height)
            .rxFieldBackground()
            HStack(spacing: RX.Space.s2) {
                Button(loadTitle) { load() }
                    .buttonStyle(.rx(size: .small))
                extra()
                if !text.isEmpty {
                    Button("Clear") { text = "" }
                        .buttonStyle(.rx(.plain, size: .small))
                }
            }
        }
    }

    func load() {
        Mac.openPanel(
            message: nil,
            prompt: nil,
            directory: URL(fileURLWithPath: "\(NSHomeDirectory())/.ssh/"),
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: false,
            canCreateDirectories: false,
            showsHiddenFiles: true
        ) { urls in
            guard let url = urls.first else { return }
            guard let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) else {
                Dialogs.presentError(with: String(localized: "The file could not be read as text."))
                return
            }
            text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension KeyEditor where Extra == EmptyView {
    init(text: Binding<String>, placeholder: LocalizedStringKey, loadTitle: LocalizedStringKey, height: CGFloat) {
        self.init(text: text, placeholder: placeholder, loadTitle: loadTitle, height: height) { EmptyView() }
    }
}

/// New Identity as a sheet (from Identities and the identity picker). Existing
/// identities are edited in place on the Identities page.
struct IdentityEditorSheet: View {
    let onComplete: (RDIdentity.ID?) -> Void

    @EnvironmentObject var store: TamioStore
    @State private var draft = IdentityDraft()

    var body: some View {
        SheetScaffold("New SSH Key") {
            IdentityForm(draft: $draft)
        } footer: {
            Spacer()
            Button("Cancel") { onComplete(nil) }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Button("Add Key") {
                var base = RDIdentity(lastRecentUsed: .init(timeIntervalSince1970: 0))
                base = draft.apply(to: base)
                store.identityGroup.insert(base)
                onComplete(base.id)
            }
            .buttonStyle(.rxPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid)
        }
        .frame(width: 520)
    }
}
