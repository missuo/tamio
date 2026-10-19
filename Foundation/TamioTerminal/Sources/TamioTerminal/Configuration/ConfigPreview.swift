import TamioDesign
import SwiftUI

struct ConfigPreview: View {
    @ObservedObject var model: ConfigEditorModel
    @StateObject private var shell = ConfigSandbox()
    @State private var minimized = false
    @State private var dark = true
    private var document: ConfigDocument { model.document }
    private var foreground: Color { Color(configHex: document.effectiveColor("foreground", dark: dark)) }
    private var size: CGFloat { min(32, max(8, Double(document.text("font-size")) ?? 14)) }
    private var family: String { document.values("font-family").first ?? "Menlo" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHead(ConfigLayout.tr("preview.title", default: "Preview")) {
                RXSegmented(selection: $dark, options: [
                    .init(false, ConfigLayout.tr("preview.mode.light", default: "Light")),
                    .init(true, ConfigLayout.tr("preview.mode.dark", default: "Dark"))
                ], caps: false)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.rxTerminalMuted)
                    Text("Tamio — playground").font(.system(size: 11)).foregroundStyle(.rxTerminalMuted)
                    Spacer()
                    Button { minimized.toggle() } label: {
                        Image(systemName: minimized ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.rxTerminalMuted)
                    .accessibilityLabel(minimized ? ConfigLayout.tr("accessibility.expand", default: "Expand") : ConfigLayout.tr("accessibility.collapse", default: "Collapse"))
                }.padding(10).background(Color.rxTerminalBackground)
                if !minimized {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(shell.lines) { line in
                                    Text(line.text).foregroundStyle(line.palette.map { Color(configHex: document.effectivePalette($0, dark: dark)) } ?? foreground)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                HStack(spacing: 2) {
                                    Text(shell.prompt).foregroundStyle(Color(configHex: document.effectivePalette(2, dark: dark)))
                                    ConfigCommandInput(shell: shell, color: foreground, fontName: family, size: size).frame(minWidth: 70)
                                    }.id("input")
                            }.font(.custom(family, size: size)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 200, idealHeight: 280, maxHeight: 420)
                            .background(Color(configHex: document.effectiveColor("background", dark: dark)))
                            .onChange(of: shell.lines.count) { _ in proxy.scrollTo("input", anchor: .bottomLeading) }
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous).strokeBorder(Color.rxHairline))
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { i in
                    Rectangle().fill(Color(configHex: document.effectivePalette(i, dark: dark))).frame(height: 14)
                        .help(String(format: ConfigLayout.tr("preview.palette.format", default: "Palette %d"), i))
                }
            }.clipShape(RoundedRectangle(cornerRadius: 3))
            HStack {
                Text(ConfigLayout.tr("preview.selected_text", default: "Selected text")).padding(5).foregroundStyle(Color(configHex: document.effectiveColor("selection-foreground", dark: dark)))
                    .background(Color(configHex: document.effectiveColor("selection-background", dark: dark)))
                Spacer()
                Text(ConfigLayout.tr("preview.cursor", default: "Cursor"))
                ConfigCursorPreview(document: document, dark: dark)
            }.font(.system(.caption, design: .monospaced))
            Spacer(minLength: 0)
        }.padding(18)
    }
}
struct ConfigCursorPreview: View {
    let document: ConfigDocument
    let dark: Bool

    private var blink: Bool { document.text("cursor-style-blink") == "true" }

    private func cursor(visible: Bool) -> some View {
        let style = document.text("cursor-style")
        return ZStack(alignment: style == "underline" ? .bottom : .leading) {
            Text("A").foregroundStyle(Color(configHex: document.effectiveColor("foreground", dark: dark)))
            Rectangle().fill(Color(configHex: document.effectiveColor("cursor-color", dark: dark)))
                .frame(width: style == "bar" ? 2 : 11, height: style == "underline" ? 2 : 17)
                .opacity(visible ? Double(document.text("cursor-opacity")) ?? 1 : 0)
        }.frame(width: 15, height: 20)
    }

    var body: some View {
        // A still cursor needs no timeline at all: with blink off the ticker
        // would redraw the preview every 0.6s for nothing.
        if blink {
            TimelineView(.animation(minimumInterval: 0.6)) { context in
                cursor(visible: Int(context.date.timeIntervalSince1970 / 0.6) % 2 == 0)
            }
        } else {
            cursor(visible: true)
        }
    }
}
