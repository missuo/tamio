//
//  SnippetEditorSheet.swift
//  Tamio (macOS)
//
//  Name, Group, Icon (SF Symbol grid with a link to the full picker), Command on
//  `terminal-bg`, Comment; Delete on the left.
//

import TamioModule
import SwiftUI
import SymbolPicker

/// SF Symbols offered in the editor's icon grid.
let snippetSymbolChoices = [
    "terminal", "chevron.left.forwardslash.chevron.right", "arrow.clockwise", "power",
    "trash", "externaldrive", "cpu", "memorychip", "network", "globe", "lock", "key",
    "shippingbox", "hammer", "wrench.and.screwdriver", "doc.text", "folder", "clock",
    "bolt", "flame", "ladybug", "chart.bar", "server.rack", "magnifyingglass",
]

struct SnippetEditorSheet: View {
    let snippet: RDSnippet.ID?
    let onClose: () -> Void

    @EnvironmentObject var store: TamioStore

    @State private var name = ""
    @State private var group = ""
    @State private var code = ""
    @State private var comment = ""
    @State private var symbol = "terminal"
    @State private var showAllSymbols = false

    var isNew: Bool { snippet == nil }

    var body: some View {
        SheetScaffold(isNew ? String(localized: "New Snippet") : String(localized: "Edit Snippet")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    RXField("Name") {
                        TextField("Restart nginx", text: $name)
                            .textFieldStyle(.rx)
                    }
                    RXField("Group") {
                        TextField("Default", text: $group)
                            .textFieldStyle(.rx)
                    }
                }
                RXField("Icon") {
                    VStack(alignment: .leading, spacing: RX.Space.s2) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 12), spacing: 4) {
                            ForEach(symbolChoices, id: \.self) { item in
                                Button {
                                    symbol = item
                                } label: {
                                    Image(systemName: item)
                                        .font(.system(size: 13))
                                        .foregroundStyle(symbol == item ? Color.rxOnAccent : Color.rxInkSecondary)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 28)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(symbol == item ? Color.rxAccent : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(item)
                            }
                        }
                        .padding(RX.Space.s2)
                        .rxFieldBackground()
                        Button("More Symbols…") { showAllSymbols = true }
                            .buttonStyle(.rxPlain)
                    }
                }
                RXField("Command") {
                    TextEditor(text: $code)
                        .font(.rxCode)
                        .foregroundStyle(.rxTerminalForeground)
                        .scrollContentBackground(.hidden)
                        .disableAutocorrection(true)
                        .padding(RX.Space.s2)
                        .frame(height: 160)
                        .background(
                            RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                                .fill(Color.rxTerminalBackground)
                        )
                }
                RXField("Comment") {
                    TextField("Optional", text: $comment)
                        .textFieldStyle(.rx)
                }
            }
        } footer: {
            if let snippet {
                Button("Delete…") {
                    SnippetActions.delete(snippet)
                    onClose()
                }
                .buttonStyle(.rx)
            }
            Spacer()
            Button("Cancel", action: onClose)
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create" : "Save", action: save)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(width: 560)
        .sheet(isPresented: $showAllSymbols) {
            SymbolPicker(symbol: $symbol)
        }
        .onAppear(perform: load)
    }

    /// The grid always shows the current symbol.
    var symbolChoices: [String] {
        snippetSymbolChoices.contains(symbol) ? snippetSymbolChoices : [symbol] + snippetSymbolChoices.dropLast()
    }

    func load() {
        if let snippet {
            let read = store.snippetGroup[snippet]
            name = read.name
            group = read.group
            code = read.code
            comment = read.comment
            symbol = read.getSFAvatar()
        } else {
            code = "#!/bin/bash\n"
        }
    }

    func save() {
        var target = snippet.map { store.snippetGroup[$0] } ?? RDSnippet(name: "", group: "", code: "", comment: "")
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.group = group
        target.code = code
        target.comment = comment
        target.setSFAvatar(sfSymbol: symbol)
        store.snippetGroup.insert(target)
        onClose()
    }
}
