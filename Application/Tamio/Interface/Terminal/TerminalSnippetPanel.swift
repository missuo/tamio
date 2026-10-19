//
//  TerminalSnippetPanel.swift
//  Tamio (macOS)
//
//  The panel beside a terminal that lists the saved snippets, to run one in
//  that terminal with a click: the command is typed at the prompt as if by
//  hand and sent with Return. Insert types it without Return, to finish by
//  hand. The toolbar's Snippets button folds the panel away and back.
//

import TamioDesign
import TamioModule
import SwiftUI

struct TerminalSnippetPanel: View {
    @ObservedObject var context: TerminalManager.Context
    let close: () -> Void

    @EnvironmentObject var store: TamioStore
    @State private var search = ""
    @State private var creating = false
    @State private var editing: RDSnippet.ID?

    static let width: CGFloat = 280
    /// Whether the panel is shown, kept across sessions and launches.
    static let shownKey = "sb.moe.tamio.terminal.snippetsShown"

    var snippets: [RDSnippet] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let all = store.snippetGroup.snippets
        let shown = needle.isEmpty ? all : all.filter { $0.isQualifiedForSearch(text: needle) }
        return shown.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The snippets by group: the ungrouped first, then the groups by name.
    var sections: [(group: String, snippets: [RDSnippet])] {
        let grouped = Dictionary(grouping: snippets, by: \.group)
        let names = grouped.keys.sorted { lhs, rhs in
            if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.snippetGroup.snippets.isEmpty {
                EmptyStateView(
                    "No snippets yet",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    message: "Save a command you run often; it runs in this terminal with one click.",
                    actionTitle: "New Snippet"
                ) {
                    creating = true
                }
                .frame(maxHeight: .infinity)
            } else if snippets.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                list
            }
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                .fill(Color.rxSurface.opacity(0.6))
        )
        .sheet(isPresented: $creating) {
            SnippetEditorSheet(snippet: nil) { creating = false }
                .environmentObject(store)
        }
        .sheet(item: Binding(get: { editing.map(EditingID.init) }, set: { editing = $0?.id })) { item in
            SnippetEditorSheet(snippet: item.id) { editing = nil }
                .environmentObject(store)
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: RX.Space.s2) {
                Text("Snippets")
                    .textCase(.uppercase)
                    .font(.system(size: 13, weight: .bold))
                Spacer(minLength: RX.Space.s2)
                Button(action: close) {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
                .help(String(localized: "Hide Snippets (⌥⌘S)"))
            }
            if !store.snippetGroup.snippets.isEmpty {
                TextField("Search snippets", text: $search)
                    .textFieldStyle(.rx)
            }
        }
        .padding(.horizontal, RX.Space.s4)
        .padding(.top, RX.Space.s3)
        .padding(.bottom, RX.Space.s2)
    }

    var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.group) { section in
                    if !section.group.isEmpty {
                        Text(section.group.uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.4)
                            .foregroundStyle(.rxInkSecondary)
                            .padding(.horizontal, RX.Space.s2)
                            .padding(.top, RX.Space.s2)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(section.snippets) { snippet in
                        SnippetRow(snippet: snippet, enabled: !context.closed) {
                            send(snippet, run: true)
                        } insert: {
                            send(snippet, run: false)
                        } edit: {
                            editing = snippet.id
                        }
                    }
                }
            }
            .padding(.horizontal, RX.Space.s2)
            .padding(.bottom, RX.Space.s2)
            .animation(.rxMove, value: snippets.map(\.id))
        }
    }

    var footer: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .center, spacing: RX.Space.s2) {
                // Whole, on two lines if need be: never cut short.
                Text(context.closed ? String(localized: "Reconnect to run snippets.") : String(localized: "\(store.snippetGroup.snippets.count) saved"))
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: RX.Space.s2)
                Button("New Snippet…") { creating = true }
                    .buttonStyle(.rx(size: .small))
            }
            .padding(.horizontal, RX.Space.s4)
            .padding(.vertical, RX.Space.s2)
        }
    }

    /// Types the snippet at the prompt; with `run`, sends it with Return.
    func send(_ snippet: RDSnippet, run: Bool) {
        guard !context.closed else { return }
        var typed = snippet.code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        guard !typed.isEmpty else { return }
        if run { typed += "\r" }
        context.insertBuffer(typed)
        // The keyboard goes back to the terminal, where the output appears.
        context.termInterface.setActive(true)
    }

    private struct EditingID: Identifiable {
        let id: RDSnippet.ID
    }
}

/// Symbol, name and the command's first line; a play symbol on hover. A click
/// runs the snippet; the menu also inserts, copies and edits it.
private struct SnippetRow: View {
    let snippet: RDSnippet
    let enabled: Bool
    let run: () -> Void
    let insert: () -> Void
    let edit: () -> Void
    @State private var hovered = false

    var command: String {
        snippet.code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var firstLine: String {
        command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            SymbolTile(snippet.getSFAvatar(), size: 24, tinted: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.name.isEmpty ? String(localized: "Untitled") : snippet.name)
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                Text(firstLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.rxAccent)
                .opacity(hovered && enabled ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, RX.Space.s2)
        .frame(height: 40)
        .rxRowBackground(selected: false, hovered: hovered && enabled)
        .contentShape(RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous))
        .opacity(enabled ? 1 : 0.6)
        .onHover { hovered = $0 }
        .onTapGesture { if enabled { run() } }
        .help(enabled ? command : String(localized: "Reconnect to run \(snippet.name)"))
        .contextMenu {
            Button("Run", action: run)
                .disabled(!enabled)
            Button("Insert Without Running", action: insert)
                .disabled(!enabled)
            Button("Copy Command") { Dialogs.sendPasteboard(str: snippet.code) }
            Divider()
            Button("Edit…", action: edit)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snippet.name.isEmpty ? String(localized: "Untitled") : snippet.name)
        .accessibilityValue(firstLine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { run() } }
    }
}
