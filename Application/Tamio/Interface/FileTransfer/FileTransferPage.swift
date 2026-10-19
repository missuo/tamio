//
//  FileTransferPage.swift
//  Tamio (macOS)
//
//  SFTP, as two panes side by side: this Mac on the left and the server on
//  the right to begin with, each able to show this Mac or any server. Drag
//  files from one pane to the other (or from Finder) to copy them; the
//  transfers run in a queue at the bottom with their progress, and browsing
//  goes on meanwhile.
//

import SwiftUI
import TamioDesign
import TamioModule
import UniformTypeIdentifiers
import UserNotifications

struct FileTransferPage: View {
    @ObservedObject var context: FileTransferContext
    /// False while another page is shown in its place.
    var active = true
    @StateObject private var left: PaneModel
    @StateObject private var right: PaneModel
    @ObservedObject private var directories = TerminalDirectories.shared
    /// The terminal's report Files last went to: a folder the terminal has
    /// not left since is not gone to again, so browsing elsewhere stays put.
    @State private var followed: Int?

    init(context: FileTransferContext, active: Bool = true) {
        self.context = context
        self.active = active
        _left = StateObject(wrappedValue: PaneModel(browser: LocalBrowser()))
        _right = StateObject(wrappedValue: PaneModel(browser: RemoteBrowser(machine: context.machine)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FilePane(model: left, peer: right, context: context)
                Rectangle().fill(Color.rxHairline).frame(width: 1)
                FilePane(model: right, peer: left, context: context)
            }
            TransferBar()
        }
        .background(Color.rxSurface.opacity(0.4))
        .pageChrome()
        // The toolbar carries the Terminal · Files · Monitor switcher.
        .pageToolbar(leading: { EmptyView() }, trailing: { EmptyView() })
        .serverToolSwitcher(machine: context.machine.id, current: .files)
        .onAppear { arrive() }
        .onChange(of: active) { _, shown in
            if shown { arrive() }
        }
        .onChange(of: directories.latest[context.machine.id]) {
            if active { follow() }
        }
    }

    /// The server's pane takes the keyboard, so ⌘V lands there and not in a
    /// terminal kept behind this page, and goes to the terminal's folder.
    private func arrive() {
        guard active else { return }
        serverPane?.focusRequest += 1
        follow()
    }

    private func follow() {
        guard let report = directories.latest[context.machine.id], report.serial != followed else { return }
        followed = report.serial
        serverPane?.browser?.open(report.path)
    }

    private var serverPane: PaneModel? {
        [right, left].first { $0.browser?.machine?.id == context.machine.id }
    }
}

// MARK: - Model

/// One pane: what it shows (this Mac, a server, or nothing yet), its filter,
/// sort and selection.
@MainActor
final class PaneModel: ObservableObject {
    @Published var browser: FileBrowser?
    @Published var filter = ""
    @Published var selection: Set<String> = []
    @Published var sort: SortColumn = .name
    @Published var ascending = true
    /// Drag hovering the pane (not a folder in it).
    @Published var dropTargeted = false
    /// Counts the times the page asked this pane to take the keyboard.
    @Published var focusRequest = 0

    enum SortColumn { case name, modified, size, kind }

    init(browser: FileBrowser?) {
        self.browser = browser
        browser?.reload()
    }

    func show(_ browser: FileBrowser?) {
        selection = []
        filter = ""
        self.browser = browser
        browser?.reload()
    }

    func entries(_ all: [FileEntry], showsHidden: Bool) -> [FileEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = showsHidden ? all : all.filter { !$0.name.hasPrefix(".") }
        let shown = needle.isEmpty ? visible : visible.filter { $0.name.lowercased().contains(needle) }
        return shown.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let ordered: Bool
            switch sort {
            case .name: ordered = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modified: ordered = (lhs.modified ?? .distantPast) < (rhs.modified ?? .distantPast)
            case .size: ordered = (lhs.size ?? 0) < (rhs.size ?? 0)
            case .kind: ordered = lhs.kind.localizedStandardCompare(rhs.kind) == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
    }
}

/// Whether Files lists files whose names start with a dot: off unless the
/// user turns it on, in Settings or a pane's Actions menu.
enum FilesPreference {
    static let showsHiddenKey = "sb.moe.tamio.files.showsHidden"
}

/// What a drag between panes carries: where the files are, and which.
struct FileDragPayload: Codable {
    /// nil for this Mac, else the server's id.
    var machine: String?
    var paths: [String]

    static let type = UTType(exportedAs: "sb.moe.tamio.file-selection")
}

extension Notification.Name {
    /// A transfer ended; panes showing its destination reload.
    static let transferFinished = Notification.Name("sb.moe.tamio.transferFinished")
}

// MARK: - Pane

private struct FilePane: View {
    @ObservedObject var model: PaneModel
    @ObservedObject var peer: PaneModel
    let context: FileTransferContext

    var body: some View {
        VStack(spacing: 0) {
            if let browser = model.browser {
                BrowserPane(model: model, peer: peer, browser: browser, context: context)
                    .id(browser.id)
            } else {
                header(title: String(localized: "No server"), systemImage: "server.rack")
                Hairline()
                EmptyStateView(
                    "Connect to host",
                    systemImage: "folder.fill",
                    message: "Start by connecting to a saved host to manage your files with SFTP.",
                    actionTitle: "Select host"
                ) { selectHost() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    func header(title: String, systemImage: String) -> some View {
        HStack {
            sourceMenu(title: title, systemImage: systemImage)
            Spacer()
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 44)
    }

    func sourceMenu(title: String, systemImage: String) -> some View {
        SourceMenu(model: model, title: title, systemImage: systemImage)
    }

    func selectHost() {
        ServerPickerPanel.present(title: "Select Host", confirmTitle: "Connect", allowsMany: false) { picked in
            guard let id = picked.first else { return }
            model.show(RemoteBrowser(machine: TamioStore.shared.machineGroup[id]))
        }
    }
}

/// The pane's source: Local, a server, or nothing.
private struct SourceMenu: View {
    @ObservedObject var model: PaneModel
    let title: String
    let systemImage: String
    @EnvironmentObject var store: TamioStore

    var body: some View {
        Menu {
            Button {
                model.show(LocalBrowser())
            } label: {
                Label("Local", systemImage: "laptopcomputer")
            }
            if !store.machineGroup.machines.isEmpty {
                Divider()
                ForEach(store.machineGroup.machines) { machine in
                    Button {
                        model.show(RemoteBrowser(machine: machine))
                    } label: {
                        Label([machine.countryFlag, machine.name].compactMap { $0 }.joined(separator: " "), systemImage: "server.rack")
                    }
                }
            }
            if model.browser != nil {
                Divider()
                Button("Disconnect") { model.show(nil) }
            }
        } label: {
            HStack(spacing: RX.Space.s2) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.rxOnAccent)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.rxAccent))
                Text(verbatim: title)
                    .font(.rxBodyStrong)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.rxInkSecondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show this Mac or another server")
    }
}

private struct BrowserPane: View {
    @ObservedObject var model: PaneModel
    @ObservedObject var peer: PaneModel
    @ObservedObject var browser: FileBrowser
    let context: FileTransferContext

    @State private var prompt: Prompt?
    @State private var hoveredFolder: String?
    @AppStorage(FilesPreference.showsHiddenKey) private var showsHidden = false
    @State private var problem: String?
    /// Holds the keyboard for ⌘V.
    @FocusState private var focused: Bool
    @ObservedObject private var directories = TerminalDirectories.shared

    enum Prompt: Identifiable {
        case newFolder
        case goTo
        case rename(FileEntry)
        var id: String {
            switch self {
            case .newFolder: return "new"
            case .goTo: return "goto"
            case let .rename(entry): return "rename" + entry.path
            }
        }
    }

    var isLocal: Bool { browser.machine == nil }
    var shown: [FileEntry] { model.entries(browser.entries, showsHidden: showsHidden) }

    var body: some View {
        VStack(spacing: 0) {
            header
            navigation
            columns
            Hairline()
            list
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // Files copied in Finder (or anywhere) arrive as if dropped here.
        .onPasteCommand(of: [.fileURL]) { providers in
            _ = receive(providers, into: browser.path)
        }
        .onAppear { if model.focusRequest > 0 { focused = true } }
        .onChange(of: model.focusRequest) { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .transferFinished)) { note in
            guard let job = note.object as? TransferJob else { return }
            let machine = job.direction == .download ? nil : job.to
            if machine?.id == browser.machine?.id, job.destination == browser.path { browser.reload() }
            if job.direction == .download, isLocal, job.destination == browser.path { browser.reload() }
        }
        .alert(item: $prompt) { prompt in
            // Text input goes through the bridge's alert below; this only
            // keeps SwiftUI's alert machinery out of the way.
            Alert(title: Text(verbatim: prompt.id))
        }
        .overlay(alignment: .bottom) {
            if let problem {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.rxWarning)
                    Text(verbatim: problem).font(.rxBody).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("OK") { self.problem = nil }.buttonStyle(.rx(size: .small))
                }
                .padding(RX.Space.s3)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.rxSurface).shadow(radius: 8, y: 2))
                .padding(RX.Space.s3)
            }
        }
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: RX.Space.s3) {
            SourceMenu(model: model, title: browser.title, systemImage: isLocal ? "laptopcomputer" : "server.rack")
            if let remote = browser as? RemoteBrowser, remote.connecting {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: RX.Space.s2)
            RXSearchField("Filter", text: $model.filter, width: 140)
            actions
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 44)
    }

    var actions: some View {
        Menu {
            Button("New Folder…") { ask(String(localized: "New folder"), value: String(localized: "untitled folder")) { name in Task { report(await browser.makeFolder(named: name)) } } }
            if !isLocal {
                Button("Upload Files…") { uploadFromPanel() }
            }
            if !model.selection.isEmpty, let target = peer.browser {
                Button("Copy \(model.selection.count) to \(target.title)") { copy(selected, to: peer, folder: target.path) }
            }
            Divider()
            Button("Go to Folder…") { ask(String(localized: "Go to folder"), value: browser.path) { browser.open($0) } }
            if let machine = browser.machine, let folder = directories.latest[machine.id]?.path {
                Button("Go to Terminal's Folder") { browser.open(folder) }
                    .help(folder)
            }
            Button("Refresh") { browser.reload() }
            Toggle("Show Hidden Files", isOn: $showsHidden)
            Button("Copy Path") { Dialogs.sendPasteboard(str: browser.path) }
            if isLocal {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: browser.path)]) }
            } else if let machine = browser.machine {
                Button("Open Terminal Here") {
                    AppRouter.shared.openTerminal(machine: machine.id, initialCommand: "cd \(shellQuote(browser.path))")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Actions").font(.rxBody)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.rxInk)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Navigation

    var navigation: some View {
        HStack(spacing: RX.Space.s1) {
            navButton("Back", "chevron.left", disabled: browser.back.isEmpty) { browser.goBack() }
            navButton("Forward", "chevron.right", disabled: browser.forward.isEmpty) { browser.goForward() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.rxInkTertiary)
                        }
                        Button {
                            browser.open(crumb.path)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 0.42, green: 0.71, blue: 0.96))
                                Text(verbatim: crumb.name)
                                    .font(.rxBody)
                                    .foregroundStyle(.rxInk)
                                    .fixedSize()
                            }
                            .padding(.horizontal, 5)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(hoveredFolder == crumb.path ? Color.rxAccentFill : .clear))
                        }
                        .buttonStyle(.plain)
                        .onDrop(of: Self.dropTypes, isTargeted: Binding(get: { hoveredFolder == crumb.path }, set: { hoveredFolder = $0 ? crumb.path : nil })) { providers in
                            receive(providers, into: crumb.path)
                        }
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
        }
        .padding(.horizontal, RX.Space.s2)
        .frame(height: 34)
    }

    var crumbs: [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var path = ""
        for part in browser.path.split(separator: "/") {
            path += "/" + part
            result.append((String(part), path))
        }
        // This Mac's root reads better as its volume, like Finder.
        if isLocal, result.count > 1 { result.removeFirst() }
        return result
    }

    func navButton(_ title: LocalizedStringKey, _ systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: systemImage) }
            .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
            .disabled(disabled)
            .help(title)
    }

    // MARK: Columns

    static let dateWidth: CGFloat = 132
    static let sizeWidth: CGFloat = 70
    static let kindWidth: CGFloat = 64

    var columns: some View {
        HStack(spacing: 0) {
            column("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            column("Date Modified", .modified).frame(width: Self.dateWidth, alignment: .leading)
            column("Size", .size).frame(width: Self.sizeWidth, alignment: .leading)
            column("Kind", .kind).frame(width: Self.kindWidth, alignment: .leading)
        }
        .padding(.horizontal, RX.Space.s4)
        .frame(height: 30)
        .background(Color.rxSurfaceSunken.opacity(0.6))
    }

    func column(_ title: LocalizedStringKey, _ key: PaneModel.SortColumn) -> some View {
        Button {
            if model.sort == key { model.ascending.toggle() } else { model.sort = key; model.ascending = true }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                if model.sort == key {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.rxInkSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if browser.path != "/" {
                    row(parent: true, entry: nil)
                }
                ForEach(shown) { entry in
                    row(parent: false, entry: entry)
                }
                if let error = browser.error {
                    VStack(spacing: RX.Space.s2) {
                        Text(verbatim: error).font(.rxBody).foregroundStyle(.rxInkSecondary).multilineTextAlignment(.center)
                        Button("Try Again") { browser.reload() }.buttonStyle(.rx(size: .small))
                    }
                    .padding(RX.Space.s6)
                } else if browser.isLoading, browser.entries.isEmpty {
                    ProgressView().padding(RX.Space.s6)
                }
            }
            .padding(.bottom, RX.Space.s6)
        }
        .background(model.dropTargeted ? Color.rxAccentFill : Color.clear)
        // A click among the files gives the pane the keyboard, for ⌘V; the
        // filter field keeps its own.
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .onDrop(of: Self.dropTypes, isTargeted: $model.dropTargeted) { providers in
            receive(providers, into: browser.path)
        }
        .contextMenu {
            Button("New Folder…") { ask(String(localized: "New folder"), value: String(localized: "untitled folder")) { name in Task { report(await browser.makeFolder(named: name)) } } }
            Button("Refresh") { browser.reload() }
        }
    }

    func row(parent: Bool, entry: FileEntry?) -> some View {
        let path = parent ? (browser.path as NSString).deletingLastPathComponent : entry!.path
        let isFolder = parent || entry!.isDirectory
        let selected = entry.map { model.selection.contains($0.path) } ?? false
        let targeted = hoveredFolder == path && isFolder
        return HStack(spacing: 0) {
            HStack(spacing: RX.Space.s2) {
                Image(systemName: isFolder ? "folder.fill" : FileIcon.symbol(for: entry!))
                    .font(.system(size: 16))
                    .foregroundStyle(isFolder ? Color(red: 0.42, green: 0.71, blue: 0.96) : Color.rxInkSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 0) {
                    // Whole, on more lines when it is long, never cut short.
                    Text(verbatim: parent ? ".." : entry!.name)
                        .font(.rxBody)
                        .foregroundStyle(.rxInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if let entry, !entry.permissions.isEmpty {
                        Text(verbatim: entry.permissions)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.rxInkSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: entry?.modified.map(Self.date) ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
                .frame(width: Self.dateWidth, alignment: .leading)
            Text(verbatim: entry.map { $0.isDirectory ? "- -" : RXFormat.bytesString(Double($0.size ?? 0)) } ?? "")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
                .frame(width: Self.sizeWidth, alignment: .leading)
            Text(LocalizedStringKey(entry?.kind ?? ""))
                .font(.system(size: 12))
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
                .frame(width: Self.kindWidth, alignment: .leading)
        }
        .padding(.horizontal, RX.Space.s4)
        .padding(.vertical, 4)
        .frame(minHeight: 38)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(targeted ? Color.rxAccent.opacity(0.22) : selected ? Color.rxRowSelected : Color.clear)
                .padding(.horizontal, RX.Space.s1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { activate(parent: parent, entry: entry, path: path) }
        .onTapGesture { select(entry) }
        .onDrag {
            guard let entry else { return NSItemProvider() }
            if !model.selection.contains(entry.path) { model.selection = [entry.path] }
            return provider(for: model.selection.sorted())
        }
        .modifier(FolderDrop(enabled: isFolder, path: path, hovered: $hoveredFolder) { providers in receive(providers, into: path) })
        .contextMenu {
            if let entry { menu(for: entry) }
        }
    }

    @ViewBuilder func menu(for entry: FileEntry) -> some View {
        let targets = model.selection.contains(entry.path) ? selected : [entry]
        if entry.isDirectory {
            Button("Open") { browser.open(entry.path) }
        } else if isLocal {
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
        }
        if let target = peer.browser {
            Button("Copy to \(target.title)") { copy(targets, to: peer, folder: target.path) }
        }
        Divider()
        Button("Rename…") {
            ask(String(localized: "Rename"), value: entry.name) { name in Task { report(await browser.rename(entry, to: name)) } }
        }
        Button("Copy Path") { Dialogs.sendPasteboard(str: entry.path) }
        Divider()
        Button("Delete…", role: .destructive) {
            Dialogs.requiresConfirmation(
                message: targets.count == 1 ? String(localized: "Delete \(entry.name)?") : String(localized: "Delete \(targets.count) items?"),
                informative: isLocal ? String(localized: "They go to the Trash.") : String(localized: "Deleting on \(browser.title) cannot be undone."),
                confirmTitle: String(localized: "Delete"),
                destructive: true
            ) { confirmed in
                guard confirmed else { return }
                Task { report(await browser.delete(targets)) }
            }
        }
    }

    var selected: [FileEntry] {
        browser.entries.filter { model.selection.contains($0.path) }
    }

    /// A click selects the row; with Command it adds or takes it away, with
    /// Shift it selects up to it.
    func select(_ entry: FileEntry?) {
        guard let entry else { return model.selection = [] }
        if Mac.commandHeld {
            if model.selection.contains(entry.path) { model.selection.remove(entry.path) } else { model.selection.insert(entry.path) }
        } else if Mac.shiftHeld {
            extendSelection(to: entry)
        } else {
            model.selection = [entry.path]
        }
    }

    func extendSelection(to entry: FileEntry) {
        let list = shown
        guard let anchor = list.firstIndex(where: { model.selection.contains($0.path) }),
              let end = list.firstIndex(where: { $0.path == entry.path })
        else { model.selection = [entry.path]; return }
        model.selection = Set(list[min(anchor, end) ... max(anchor, end)].map(\.path))
    }

    func activate(parent: Bool, entry: FileEntry?, path: String) {
        if parent || entry?.isDirectory == true { return browser.open(path) }
        guard let entry else { return }
        if isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
        }
    }

    func report(_ error: FileBrowserError?) {
        if let error { problem = error.message }
    }

    func ask(_ title: String, value: String, completion: @escaping (String) -> Void) {
        Mac.alert(message: title, informative: nil, buttons: [String(localized: "OK"), String(localized: "Cancel")], destructiveFirstButton: false, textField: value) { index, text in
            guard index == 0, let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return }
            completion(text)
        }
    }

    func uploadFromPanel() {
        Mac.openPanel(
            message: String(localized: "Choose files or folders to upload to \(browser.path)"),
            prompt: String(localized: "Upload"),
            directory: nil,
            canChooseFiles: true,
            canChooseDirectories: true,
            allowsMultipleSelection: true,
            canCreateDirectories: false,
            showsHiddenFiles: false
        ) { urls in
            guard !urls.isEmpty, let machine = browser.machine else { return }
            TransferQueue.shared.enqueue(TransferJob(direction: .upload, sources: urls.map(\.path), from: nil, to: machine, destination: browser.path))
        }
    }

    // MARK: Drag and drop

    static let dropTypes: [UTType] = [FileDragPayload.type, .fileURL]

    func provider(for paths: [String]) -> NSItemProvider {
        let payload = FileDragPayload(machine: browser.machine?.id.uuidString, paths: paths)
        let provider: NSItemProvider
        if isLocal, paths.count == 1 {
            // Finder and other apps take a file from this Mac as it is.
            provider = NSItemProvider(contentsOf: URL(fileURLWithPath: paths[0])) ?? NSItemProvider()
        } else {
            provider = NSItemProvider()
        }
        // From a server, Finder is offered the file (the first, for several):
        // it is downloaded once dropped, into a folder of its own that Finder
        // copies from.
        if let machine = browser.machine, let path = paths.first {
            let entry = browser.entries.first { $0.path == path }
            let type: UTType = entry?.isDirectory == true ? .folder : (UTType(filenameExtension: (path as NSString).pathExtension) ?? .data)
            provider.suggestedName = (path as NSString).lastPathComponent
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tamio-drag-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return RemoteFetch.download(path, from: machine, into: folder) { url in
                    completion(url, false, url == nil ? CocoaError(.fileReadUnknown) : nil)
                }
            }
        }
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(forTypeIdentifier: FileDragPayload.type.identifier, visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    func receive(_ providers: [NSItemProvider], into folder: String) -> Bool {
        let model = model
        if let tamio = providers.first(where: { $0.hasItemConformingToTypeIdentifier(FileDragPayload.type.identifier) }) {
            tamio.loadDataRepresentation(forTypeIdentifier: FileDragPayload.type.identifier) { data, _ in
                guard let data, let payload = try? JSONDecoder().decode(FileDragPayload.self, from: data) else { return }
                Task { @MainActor in arrive(payload, into: folder, model: model) }
            }
            return true
        }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let collected = URLCollector(count: files.count) { urls in
            Task { @MainActor in arrive(FileDragPayload(machine: nil, paths: urls.map(\.path)), into: folder, model: model) }
        }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in collected.add(url) }
        }
        return true
    }

    /// Files dropped on this pane, from either pane or from Finder.
    @MainActor
    func arrive(_ payload: FileDragPayload, into folder: String, model: PaneModel) {
        let from = payload.machine.flatMap(UUID.init(uuidString:)).map { TamioStore.shared.machineGroup[$0] }
        let to = browser.machine
        let paths = payload.paths.filter { ($0 as NSString).deletingLastPathComponent != folder || from?.id != to?.id }
        guard !paths.isEmpty else { return }
        switch (from, to) {
        case (nil, nil):
            // This Mac to this Mac: a copy, as in Finder between folders.
            Task {
                for path in paths {
                    let target = (folder as NSString).appendingPathComponent((path as NSString).lastPathComponent)
                    do { try FileManager.default.copyItem(atPath: path, toPath: target) } catch { problem = error.localizedDescription }
                }
                browser.reload()
            }
        case let (nil, server?):
            TransferQueue.shared.enqueue(TransferJob(direction: .upload, sources: paths, from: nil, to: server, destination: folder))
        case let (server?, nil):
            TransferQueue.shared.enqueue(TransferJob(direction: .download, sources: paths, from: server, to: nil, destination: folder))
        case let (source?, target?) where source.id == target.id:
            // Within one server: a move, by rename.
            Task {
                for path in paths {
                    let name = (path as NSString).lastPathComponent
                    report(await browser.move(path, to: (folder as NSString).appendingPathComponent(name)))
                }
            }
        case let (source?, target?):
            TransferQueue.shared.enqueue(TransferJob(direction: .relay, sources: paths, from: source, to: target, destination: folder))
        }
    }

    func copy(_ entries: [FileEntry], to peer: PaneModel, folder: String) {
        guard let target = peer.browser else { return }
        let payload = FileDragPayload(machine: browser.machine?.id.uuidString, paths: entries.map(\.path))
        let from = browser.machine
        switch (from, target.machine) {
        case (nil, nil):
            for entry in entries {
                try? FileManager.default.copyItem(atPath: entry.path, toPath: (folder as NSString).appendingPathComponent(entry.name))
            }
            target.reload()
        case let (nil, server?):
            TransferQueue.shared.enqueue(TransferJob(direction: .upload, sources: payload.paths, from: nil, to: server, destination: folder))
        case let (server?, nil):
            TransferQueue.shared.enqueue(TransferJob(direction: .download, sources: payload.paths, from: server, to: nil, destination: folder))
        case let (source?, other?):
            TransferQueue.shared.enqueue(TransferJob(direction: .relay, sources: payload.paths, from: source, to: other, destination: folder))
        }
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }

    func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A folder row (or crumb) takes drops into itself.
private struct FolderDrop: ViewModifier {
    let enabled: Bool
    let path: String
    @Binding var hovered: String?
    let perform: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [FileDragPayload.type, .fileURL], isTargeted: Binding(
                get: { hovered == path },
                set: { hovered = $0 ? path : (hovered == path ? nil : hovered) }
            ), perform: perform)
        } else {
            content
        }
    }
}

/// Gathers the URLs of a Finder drop, which arrive one at a time.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let done: ([URL]) -> Void

    init(count: Int, done: @escaping ([URL]) -> Void) {
        remaining = count
        self.done = done
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let finished = remaining == 0
        let all = urls
        lock.unlock()
        if finished, !all.isEmpty { done(all) }
    }
}

enum FileIcon {
    static func symbol(for entry: FileEntry) -> String {
        switch entry.kind {
        case "image": return "photo"
        case "archive": return "doc.zipper"
        case "video": return "film"
        case "audio": return "waveform"
        case "pdf": return "doc.richtext"
        case "script": return "chevron.left.forwardslash.chevron.right"
        case "alias": return "arrowshape.turn.up.right"
        default: return "doc.text"
        }
    }
}

// MARK: - Transfers

/// The queue at the bottom of the page: the transfer going on, with its
/// progress, speed and time left; the list of all of them when opened.
private struct TransferBar: View {
    @ObservedObject private var queue = TransferQueue.shared
    @State private var expanded = false

    var body: some View {
        if !queue.jobs.isEmpty {
            VStack(spacing: 0) {
                Hairline()
                if expanded {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(queue.jobs.reversed()) { job in
                                TransferRow(job: job)
                                Hairline()
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                summary
            }
            .background(Color.rxSurface)
            .onAppear(perform: hookReloads)
        }
    }

    var summary: some View {
        HStack(spacing: RX.Space.s3) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .bold))
                    Text("Transfers (\(queue.jobs.count))").font(.rxBodyStrong)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let current = queue.jobs.first(where: { $0.state == .running }) {
                TransferProgressLine(job: current)
            } else {
                Text(queue.jobs.contains { $0.state == .failed } ? "Some transfers failed" : "All done")
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
                Spacer()
                Button("Clear") { queue.clearFinished() }
                    .buttonStyle(.rx(size: .small))
            }
        }
        .padding(.horizontal, RX.Space.s4)
        .frame(height: 44)
    }

    func hookReloads() {
        queue.onFinish = { job in
            NotificationCenter.default.post(name: .transferFinished, object: job)
            TransferNotifier.finished(job)
        }
    }
}

private struct TransferProgressLine: View {
    @ObservedObject var job: TransferJob

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            Image(systemName: job.direction == .download ? "arrow.down" : "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.rxAccent)
            // The file's whole name, or none when there is no room for it.
            ViewThatFits(in: .horizontal) {
                Text(verbatim: job.currentFile.isEmpty ? job.title : job.currentFile)
                    .font(.rxBody)
                    .fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            .frame(maxWidth: 260, alignment: .leading)
            RXProgressBar(job.fraction)
                .frame(minWidth: 80)
            Text(verbatim: "\(Int(job.fraction * 100))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 38, alignment: .trailing)
            Text(verbatim: RXFormat.rateString(Double(job.bytesPerSecond)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
                .frame(width: 84, alignment: .trailing)
            if let left = job.secondsLeft {
                Text("\(RXFormat.duration(left)) left")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.rxInkSecondary)
                    .fixedSize()
            }
            Button {
                TransferQueue.shared.cancel(job)
            } label: {
                Label("Cancel", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
            .help("Cancel")
        }
    }
}

private struct TransferRow: View {
    @ObservedObject var job: TransferJob

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: job.title).font(.rxBody).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: job.error ?? subtitle)
                    .font(.rxHelp)
                    .foregroundStyle(job.error == nil ? Color.rxInkSecondary : Color.rxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if job.state == .running || job.state == .queued {
                RXProgressBar(job.fraction).frame(width: 120)
                Button("Cancel") { TransferQueue.shared.cancel(job) }.buttonStyle(.rx(size: .small))
            } else if job.state == .failed || job.state == .cancelled {
                Button("Retry") { TransferQueue.shared.retry(job) }.buttonStyle(.rx(size: .small))
            }
        }
        .padding(.horizontal, RX.Space.s4)
        .frame(height: 50)
    }

    var subtitle: String {
        switch job.state {
        case .queued: return String(localized: "Waiting")
        case .running: return String(localized: "\(RXFormat.bytesString(Double(job.doneBytes))) of \(RXFormat.bytesString(Double(job.totalBytes))) · \(RXFormat.rateString(Double(job.bytesPerSecond)))")
        case .done: return String(localized: "Done · \(RXFormat.bytesString(Double(job.totalBytes))) into \(job.destination)")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    var icon: String {
        switch job.state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        default: return job.direction == .download ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    var color: Color {
        switch job.state {
        case .done: return .rxSuccess
        case .failed: return .rxDanger
        default: return .rxAccent
        }
    }
}

enum FileTransferSessionActions {
    /// Closes a server's SFTP session.
    @MainActor
    static func close(_ context: FileTransferContext) {
        if context.isProgressRunning || !TransferQueue.shared.active.isEmpty {
            Dialogs.requiresConfirmation(
                message: String(localized: "Close the file transfer on \(context.machine.name)?"),
                informative: String(localized: "A transfer is still running and will be interrupted."),
                confirmTitle: String(localized: "Close"),
                destructive: true
            ) { confirmed in
                if confirmed { FileTransferManager.shared.end(for: context.id) }
            }
        } else {
            FileTransferManager.shared.end(for: context.id)
        }
    }
}

/// A transfer that ends while Tamio is in the background says so in a
/// notification; one in front of the user shows in the transfer bar.
@MainActor
enum TransferNotifier {
    private static var asked = false

    static func finished(_ job: TransferJob) {
        let inFront = Mac.isFrontmost
        guard !inFront, job.state != .cancelled else { return log("in front: no notification") }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        switch job.state {
        case .done:
            content.title = job.direction == .download ? String(localized: "Download finished") : String(localized: "Upload finished")
            content.body = job.title
        default:
            content.title = String(localized: "Transfer failed")
            content.body = [job.title, job.error].compactMap { $0 }.joined(separator: "\n")
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        let post = {
            center.add(request) { error in
                log("\(content.title): \(content.body) -> \(error.map { "\($0)" } ?? "posted")")
            }
        }
        if asked {
            post()
        } else {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                log("authorization: \(granted)\(error.map { " \($0)" } ?? "")")
                if granted { post() }
            }
        }
    }

    /// TAMIO_NOTIFY_LOG=<file>, in debug builds, records what happens to each
    /// notification, to check one was posted.
    private nonisolated static func log(_ line: String) {
        #if DEBUG
            guard let path = ProcessInfo.processInfo.environment["TAMIO_NOTIFY_LOG"],
                  let handle = FileHandle(forWritingAtPath: path)
            else { return }
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            handle.closeFile()
        #endif
    }
}
