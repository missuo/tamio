//
//  ServerEditorDialog.swift
//  Tamio (macOS)
//
//  New / Edit Server, a dialog over the window: Address; General (Label,
//  Group, Tags); SSH user and port; Credentials: a password for this server,
//  or an SSH key from Identities (or a new one, added there); Advanced (SFTP
//  start folder, startup snippet, comment, last banner). A password is kept
//  as the server's private identity, never listed in Identities.
//

import NSRemoteShell
import SwiftUI
import TamioDesign
import TamioModule

/// Everything the dialog edits, compared with what was loaded to tell whether
/// closing would lose changes.
struct ServerDraft: Equatable {
    enum Credential: Hashable {
        case password
        case key
    }

    var address = ""
    var label = ""
    var group = ""
    var tags = ""
    var port = "22"
    var username = ""
    var credential: Credential = .password
    var password = ""
    /// The SSH key, an identity from Identities.
    var key: RDIdentity.ID?
    var startFolder = ""
    var startupSnippet: RDSnippet.ID?
    var comment = ""
    /// A command the connection goes through, as in ssh_config's ProxyCommand.
    var proxyCommand = ""
    var shellIntegration = false
}

struct ServerEditorDialog: View {
    let target: ServerEditorTarget

    @EnvironmentObject var store: TamioStore
    @ObservedObject private var router = AppRouter.shared

    @State private var draft = ServerDraft()
    @State private var loaded = ServerDraft()
    @State private var banner = ""
    @State private var showsPassword = false
    @State private var showsAdvanced = false
    @State private var connecting = false
    @State private var addsKey = false
    @State private var addressError: String?
    @State private var credentialsError: String?
    @FocusState private var addressFocused: Bool

    static let width: CGFloat = 540

    var machine: RDMachine.ID? { target.machine }
    var isNew: Bool { machine == nil }
    var portIsValid: Bool { UInt16(draft.port).map { $0 > 0 } ?? false }
    var canSave: Bool { !trimmedAddress.isEmpty && portIsValid }
    var trimmedAddress: String { draft.address.trimmingCharacters(in: .whitespaces) }
    /// The user to sign in as; root when left empty.
    var trimmedUsername: String {
        let typed = draft.username.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? RDMachine.defaultUsername : typed
    }
    var isDirty: Bool { draft != loaded }

    var existingGroups: [String] {
        Set(store.machineGroup.machines.map(\.group)).filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: RX.Space.s5) {
                    addressSection
                    generalSection
                    sshSection
                    credentialsSection
                    advancedSection
                }
                .padding(RX.Space.s5)
            }
            Hairline()
            footer
        }
        .frame(width: Self.width)
        .frame(maxHeight: 760)
        .background(Color.rxSurface)
        .clipShape(RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                .strokeBorder(Color.rxHairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 40, y: 16)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .serverEditorWantsClose)) { _ in requestClose() }
        // Esc closes the dialog even from inside a text field, which keeps
        // the key otherwise.
        .onKeyPress(.escape) {
            requestClose()
            return .handled
        }
    }

    // MARK: - Sections

    var header: some View {
        HStack {
            Text(isNew ? String(localized: "New Server") : String(localized: "Edit Server"))
                .font(.rxSheetTitle)
            Spacer()
            Button(action: requestClose) {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.rx(.plain, iconOnly: true))
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "Close (Esc)"))
        }
        .padding(.horizontal, RX.Space.s5)
        .frame(height: 52)
    }

    var addressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: RX.Space.s3) {
                TextField("IP or hostname", text: $draft.address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .disableAutocorrection(true)
                    .focused($addressFocused)
                    .onSubmit(connect)
                    .accessibilityLabel("Address")
            }
            .padding(.horizontal, RX.Space.s3)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.rxSurfaceSunken))
            if let addressError {
                HelpText(addressError, isError: true)
            }
        }
    }

    var generalSection: some View {
        section("General") {
            row("Label") {
                TextField(trimmedAddress.isEmpty ? "prod-web-01" : trimmedAddress, text: $draft.label)
                    .textFieldStyle(.rx)
            }
            row("Group") {
                HStack(spacing: RX.Space.s1) {
                    TextField("None", text: $draft.group)
                        .textFieldStyle(.rx)
                    if !existingGroups.isEmpty {
                        Menu {
                            ForEach(existingGroups, id: \.self) { item in
                                Button(item) { draft.group = item }
                            }
                        } label: {
                            Label("Existing Groups", systemImage: "chevron.down")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.rx(iconOnly: true))
                        .fixedSize()
                        .help(String(localized: "Choose an existing group"))
                    }
                }
            }
            row("Tags") {
                TextField("prod, tokyo", text: $draft.tags)
                    .textFieldStyle(.rx)
                    .disableAutocorrection(true)
            }
        }
    }

    var sshSection: some View {
        section("SSH") {
            row("Username") {
                TextField(RDMachine.defaultUsername, text: $draft.username)
                    .textFieldStyle(.rxMono)
                    .disableAutocorrection(true)
            }
            row("Port") {
                HStack(spacing: RX.Space.s2) {
                    TextField("22", text: $draft.port)
                        .textFieldStyle(.rxMono)
                        .frame(width: 80)
                    if !portIsValid {
                        HelpText("1–65535", isError: true)
                    }
                    Spacer()
                }
            }
        }
    }

    /// The identities that are SSH keys, for the key picker.
    var keys: [RDIdentity] {
        store.identityGroup.shared.filter { !$0.privateKey.isEmpty }
    }

    var credentialsSection: some View {
        section("Credentials") {
            RXSegmented(selection: $draft.credential, options: [
                .init(.password, "Password"),
                .init(.key, "SSH key"),
            ], caps: false, fullWidth: true)
            switch draft.credential {
            case .password:
                row("Password") {
                    secretField(placeholder: "Required")
                }
                HelpText("Kept with this server only.")
            case .key:
                row("Key") {
                    HStack(spacing: RX.Space.s2) {
                        RXPicker(
                            selection: $draft.key,
                            options: keys.map { item in
                                .init(item.id, [item.displayName, item.keyAlgorithm?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                            },
                            placeholder: keys.isEmpty ? String(localized: "No keys yet") : String(localized: "Choose a key")
                        )
                        Button("New Key…") { addsKey = true }
                            .buttonStyle(.rx)
                            .help(String(localized: "Add a key to Identities: paste it, load it or generate one"))
                    }
                }
                if let id = draft.key {
                    let key = store.identityGroup[id]
                    HStack(alignment: .top, spacing: RX.Space.s2) {
                        HelpText("Signs in as \(trimmedUsername). The key is kept in Identities, for other servers too.")
                        Spacer(minLength: 0)
                        if !key.publicKey.isEmpty {
                            Button("Copy Public Key") { Dialogs.sendPasteboard(str: key.publicKey) }
                                .buttonStyle(.rx(size: .small))
                                .help(String(localized: "For the server's ~/.ssh/authorized_keys"))
                        }
                    }
                }
            }
            if let credentialsError {
                HelpText(credentialsError, isError: true)
            }
        }
        .sheet(isPresented: $addsKey) {
            IdentityEditorSheet { created in
                addsKey = false
                if let created { draft.key = created }
            }
            .environmentObject(TamioStore.shared)
        }
    }

    var advancedSection: some View {
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showsAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                    CapsLabel("Advanced")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsAdvanced {
                VStack(alignment: .leading, spacing: RX.Space.s3) {
                    row("SFTP start folder") {
                        TextField("Home folder", text: $draft.startFolder)
                            .textFieldStyle(.rxMono)
                            .disableAutocorrection(true)
                    }
                    row("Startup snippet") {
                        RXPicker(
                            selection: $draft.startupSnippet,
                            options: [.init(nil, "None")] + store.snippetGroup.snippets.map { .init($0.id, $0.name) }
                        )
                    }
                    row("Comment") {
                        TextField("Optional", text: $draft.comment)
                            .textFieldStyle(.rx)
                    }
                    row("Proxy command") {
                        TextField("cloudflared access ssh --hostname %h", text: $draft.proxyCommand)
                            .textFieldStyle(.rxMono)
                            .disableAutocorrection(true)
                    }
                    HelpText("The connection goes through this command instead of directly to the address. %h is the address and %p the port. Leave empty to connect directly.")
                    row("Shell integration") {
                        Toggle("Shell integration", isOn: $draft.shellIntegration)
                            .labelsHidden()
                            .rxSwitchToggle()
                            .tint(.rxAccent)
                            .controlSize(.small)
                    }
                    HelpText("Files follows the terminal's folder. Each new terminal types a line that has bash, zsh or fish tell Tamio its folder at every prompt; nothing is changed on the server.")
                    if !isNew {
                        row("Last banner") {
                            RXValueField(banner, placeholder: "None", monospaced: true)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    var footer: some View {
        HStack(spacing: RX.Space.s2) {
            if connecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
            }
            Spacer()
            Button("Save", action: saveAndClose)
                .buttonStyle(.rx)
                .disabled(!canSave || connecting)
                .keyboardShortcut("s", modifiers: .command)
                .help(String(localized: "Save without connecting (⌘S)"))
            Button("Connect", action: connect)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || connecting)
                .help(String(localized: "Check the connection, save, and open a terminal (↩)"))
        }
        .padding(.horizontal, RX.Space.s5)
        .frame(height: 56)
    }

    func secretField(placeholder: LocalizedStringKey) -> some View {
        HStack(spacing: RX.Space.s1) {
            Group {
                if showsPassword {
                    TextField(placeholder, text: $draft.password)
                } else {
                    SecureField(placeholder, text: $draft.password)
                }
            }
            .textFieldStyle(.rxMono)
            Button {
                showsPassword.toggle()
            } label: {
                Label(showsPassword ? "Hide" : "Show", systemImage: showsPassword ? "eye.slash" : "eye")
            }
            .buttonStyle(.rx(.plain, iconOnly: true))
            .help(showsPassword ? String(localized: "Hide") : String(localized: "Show"))
        }
    }

    func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            CapsLabel(title)
            content()
        }
    }

    func row(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: RX.Space.s3) {
            Text(title)
                .font(.rxBody)
                .foregroundStyle(.rxInkSecondary)
                .frame(width: 110, alignment: .leading)
            content()
        }
    }

    // MARK: - Loading and saving

    func load() {
        defer {
            loaded = draft
            if isNew { addressFocused = true }
        }
        guard let machine else {
            // A new server signs in with a key when there is one to choose:
            // the first the picker lists.
            if let first = keys.first {
                draft.credential = .key
                draft.key = first.id
            }
            return
        }
        let read = store.machineGroup[machine]
        draft.address = read.remoteAddress
        draft.label = read.name == read.remoteAddress ? "" : read.name
        draft.port = read.remotePort.isEmpty ? "22" : read.remotePort
        draft.group = read.group
        draft.tags = read.tags.joined(separator: ", ")
        draft.comment = read.comment
        draft.startFolder = read.startsInHomeFolder ? "" : read.fileTransferLoginPath
        draft.startupSnippet = read.startupSnippet
        draft.proxyCommand = read.proxyCommand
        draft.shellIntegration = read.shellIntegration
        banner = read.lastBanner
        showsAdvanced = read.startupSnippet != nil || !read.comment.isEmpty || !read.startsInHomeFolder || !read.proxyCommand.isEmpty || read.shellIntegration
        let identity = read.associatedIdentity.flatMap(UUID.init(uuidString:)).map { store.identityGroup[$0] }
        let user = read.loginUsername(with: identity)
        draft.username = user == RDMachine.defaultUsername && read.username.isEmpty ? "" : user
        guard let identity, identity.hasCredentials else { return }
        if identity.privateKey.isEmpty {
            // A password: the server's own, or a password identity from
            // before identities were keys only.
            draft.password = identity.password
            draft.credential = .password
        } else {
            draft.key = identity.id
            draft.credential = .key
        }
    }

    /// The private identity this server already has, if any.
    var existingPrivateIdentity: RDIdentity? {
        guard let machine,
              let raw = store.machineGroup[machine].associatedIdentity,
              let id = UUID(uuidString: raw)
        else { return nil }
        let identity = store.identityGroup[id]
        return identity.isPrivate ? identity : nil
    }

    /// What the server signs in with: its own password, kept as a private
    /// identity, or a key from Identities.
    func credentialsToUse() -> RDIdentity? {
        switch draft.credential {
        case .key:
            return draft.key.map { store.identityGroup[$0] }
        case .password:
            guard !draft.password.isEmpty else { return nil }
            var identity = existingPrivateIdentity ?? RDIdentity(authenticAutomatically: false)
            identity.username = ""
            identity.password = draft.password
            identity.privateKey = ""
            identity.publicKey = ""
            identity.authenticAutomatically = false
            identity.isPrivate = true
            return identity
        }
    }

    /// Why the server cannot sign in yet, or nil.
    func credentialsProblem() -> String? {
        switch draft.credential {
        case .password where draft.password.isEmpty:
            return String(localized: "Type the password.")
        case .key where draft.key == nil:
            return keys.isEmpty
                ? String(localized: "Add a key with New Key…")
                : String(localized: "Choose a key, or add one with New Key…")
        default:
            return nil
        }
    }

    @discardableResult
    func save(banner capturedBanner: String? = nil) -> RDMachine {
        // A new server has never been connected to; RXFormat shows the epoch as "Never".
        var target = machine.map { store.machineGroup[$0] } ?? RDMachine(lastConnection: Date(timeIntervalSince1970: 0))
        target.remoteAddress = trimmedAddress
        target.remotePort = draft.port
        target.username = trimmedUsername
        target.name = draft.label.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedAddress : draft.label
        target.group = draft.group.trimmingCharacters(in: .whitespaces)
        target.tags = draft.tags.split(separator: ",").map(String.init)
        target.comment = draft.comment
        target.fileTransferLoginPath = draft.startFolder.trimmingCharacters(in: .whitespaces)
        target.startupSnippet = draft.startupSnippet
        target.proxyCommand = draft.proxyCommand
        target.shellIntegration = draft.shellIntegration

        let previousPrivate = existingPrivateIdentity
        let identity = credentialsToUse()
        if let identity, identity.isPrivate {
            store.identityGroup.insert(identity)
        }
        if let previousPrivate, previousPrivate.id != identity?.id {
            store.identityGroup.delete(previousPrivate.id)
        }
        target.associatedIdentity = identity?.id.uuidString

        if let capturedBanner {
            target.lastBanner = capturedBanner
            target.lastConnection = Date()
        }
        store.machineGroup.insert(target)
        loaded = draft
        return target
    }

    func saveAndClose() {
        guard canSave else { return }
        save()
        close()
    }

    func requestClose() {
        guard isDirty else { return close() }
        Dialogs.requiresConfirmation(
            message: isNew ? String(localized: "Discard this new server?") : String(localized: "Discard your changes?"),
            confirmTitle: String(localized: "Discard"),
            destructive: true,
            always: true
        ) { confirmed in
            if confirmed { close() }
        }
    }

    func close() {
        withAnimation(.easeOut(duration: 0.2)) { router.serverEditor = nil }
    }

    // MARK: - Connecting

    /// Connects first; saves and opens a terminal once a login works.
    func connect() {
        guard canSave, !connecting else { return }
        addressError = nil
        credentialsError = credentialsProblem()
        guard credentialsError == nil else { return }
        connecting = true
        let host = trimmedAddress
        let port = draft.port
        let username = trimmedUsername
        let proxyCommand = draft.proxyCommand
        guard let chosen = credentialsToUse() else { return }
        let timeout = store.timeoutNumber
        DispatchQueue.global().async {
            let shell = NSRemoteShell.configured(host: host, port: port, timeout: timeout)
                .setupProxyCommand(proxyCommand)
            shell.requestConnectAndWait()
            guard shell.isConnected else {
                let refusal = shell.hostKeyRefusal
                let proxyFailure = shell.getLastError()
                onMainThread {
                    connecting = false
                    addressError = refusal ?? proxyFailure ?? String(localized: "Could not reach \(host) on port \(port).")
                }
                return
            }
            chosen.callAuthenticationWith(remote: shell, username: username)
            let authenticated = shell.isAuthenticated
            let banner = shell.remoteBanner ?? ""
            shell.requestDisconnectAndWait()
            onMainThread {
                connecting = false
                if authenticated {
                    let created = save(banner: banner)
                    close()
                    onMainThread(delay: 0.2) {
                        AppRouter.shared.openTerminal(machine: created.id)
                    }
                } else {
                    credentialsError = chosen.privateKey.isEmpty
                        ? String(localized: "\(username) could not sign in to \(host) with this password.")
                        : String(localized: "\(host) did not accept this key for \(username). Add its public key to ~/.ssh/authorized_keys there.")
                }
            }
        }
    }
}

extension Notification.Name {
    /// A click on the dimmed window around the server editor.
    static let serverEditorWantsClose = Notification.Name("sb.moe.tamio.serverEditorWantsClose")
}
