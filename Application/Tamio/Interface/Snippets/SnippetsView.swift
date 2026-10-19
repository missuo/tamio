//
//  SnippetsView.swift
//  Tamio (macOS)
//
//  Snippet cards with their SF Symbol, group, comment, the command on `terminal-bg`,
//  and Run… (server picker, then the batch run sheet).
//

import TamioModule
import SwiftUI

struct SnippetsView: View {
    @EnvironmentObject var store: TamioStore

    @State private var searchText = ""
    @State private var groupFilter: String?
    @State private var creating = false
    @State private var editing: RDSnippet.ID?

    var groupNames: [String] {
        Set(store.snippetGroup.snippets.map(\.group)).filter { !$0.isEmpty }.sorted()
    }

    var filtered: [RDSnippet] {
        var result = store.snippetGroup.snippets
        if let groupFilter {
            result = result.filter { $0.group == groupFilter }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.isQualifiedForSearch(text: searchText) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        PageScaffold(
            search: $searchText,
            searchPrompt: "Search snippets",
            primary: ToolbarAction("New Snippet", systemImage: "plus", primary: true) { creating = true }
        ) {
            if !groupNames.isEmpty {
                Picker("Group", selection: $groupFilter) {
                    Text("All Groups").tag(String?.none)
                    Divider()
                    ForEach(groupNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .help(String(localized: "Filter by group"))
            }
        } trailing: {
        } header: {
            PageTitle("Snippets")
        } content: {
            if store.snippetGroup.snippets.isEmpty {
                EmptyStateView(
                    "No snippets yet",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    actionTitle: "New Snippet"
                ) {
                    creating = true
                }
                .rxCard()
            } else if filtered.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
                    .rxCard()
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: RX.Space.s4, alignment: .top)],
                    alignment: .leading,
                    spacing: RX.Space.s4
                ) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, snippet in
                        SnippetTile(snippet: snippet) { editing = snippet.id }
                            .rxRise(index)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .animation(.rxMove, value: filtered.map(\.id))
            }
        }
        .onChange(of: groupNames) { names in
            if let groupFilter, !names.contains(groupFilter) { self.groupFilter = nil }
        }
        .sheet(isPresented: $creating) {
            SnippetEditorSheet(snippet: nil) { creating = false }
                .environmentObject(TamioStore.shared)
        }
        .sheet(item: Binding(get: { editing.map(EditingID.init) }, set: { editing = $0?.id })) { item in
            SnippetEditorSheet(snippet: item.id) { editing = nil }
                .environmentObject(TamioStore.shared)
        }
    }

    private struct EditingID: Identifiable {
        let id: RDSnippet.ID
    }
}

private struct SnippetTile: View {
    let snippet: RDSnippet
    let edit: () -> Void
    @State private var hovered = false

    var detail: String {
        [snippet.group, snippet.comment].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            HStack(alignment: .top, spacing: RX.Space.s3) {
                SymbolTile(snippet.getSFAvatar())
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.name.isEmpty ? String(localized: "Untitled") : snippet.name)
                        .font(.rxBodyStrong)
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        HelpText(detail)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: RX.Space.s2)
                Button("Run…") { SnippetActions.run(snippet.id) }
                    .buttonStyle(.rx(size: .small))
            }
            CodeBlock(snippet.code.trimmingCharacters(in: .whitespacesAndNewlines), lineLimit: 4)
        }
        .rxCard()
        .scaleEffect(hovered ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .contentShape(RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous))
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: edit)
        .contextMenu {
            Button("Run…") { SnippetActions.run(snippet.id) }
            Button("Edit…", action: edit)
            Button("Duplicate") { SnippetActions.duplicate(snippet.id) }
            Button("Copy Command") { Dialogs.sendPasteboard(str: snippet.code) }
            Divider()
            Button("Delete…", role: .destructive) { SnippetActions.delete(snippet.id) }
        }
    }
}

enum SnippetActions {
    @MainActor
    static func run(_ id: RDSnippet.ID) {
        let snippet = TamioStore.shared.snippetGroup[id]
        guard !snippet.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Dialogs.presentError(with: String(localized: "This snippet has no command to run."))
            return
        }
        ServerPickerPanel.present(
            title: "Run \(snippet.name)",
            lead: "Servers need an identity set.",
            confirmTitle: "Run",
            allowsMany: true
        ) { machines in
            onMainThread(delay: 0.3) {
                SheetPresenter.present { dismiss in
                    BatchRunSheet(snippet: snippet, machines: machines, close: dismiss)
                }
            }
        }
    }

    static func duplicate(_ id: RDSnippet.ID) {
        var copy = TamioStore.shared.snippetGroup[id]
        copy.id = UUID()
        copy.name += " copy"
        TamioStore.shared.snippetGroup.insert(copy)
    }

    static func delete(_ id: RDSnippet.ID) {
        let snippet = TamioStore.shared.snippetGroup[id]
        Dialogs.requiresConfirmation(
            message: snippet.name.isEmpty ? String(localized: "Delete this snippet?") : String(localized: "Delete \(snippet.name)?"),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            if confirmed { TamioStore.shared.snippetGroup.delete(id) }
        }
    }
}
