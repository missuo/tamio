import Foundation
import SwiftUI
import GhosttyTerminal

/// Passed down a setting's row: it changes when the row has to be drawn again.
private struct ConfigRevisionKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var configRevision: Int {
        get { self[ConfigRevisionKey.self] }
        set { self[ConfigRevisionKey.self] = newValue }
    }
}

@MainActor
final class ConfigEditorModel: ObservableObject {
    static let shared = ConfigEditorModel()
    @Published private(set) var document: ConfigDocument {
        didSet { touchScopes(since: oldValue) }
    }

    /// What a setting's row watches, so a change to one setting draws that
    /// row again and not every row of every category.
    final class Scope: ObservableObject {
        @Published fileprivate(set) var revision = 0
    }

    private var scopes: [String: Scope] = [:]
    /// Settings other rows read as well: colours follow the theme and the
    /// palette, and those left unset follow the foreground or background;
    /// font styles, features and variations follow the families.
    private static let sharedKeys: Set<String> = [
        "theme", "palette", "foreground", "background", "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic",
    ]

    func scope(_ key: String) -> Scope {
        if let scope = scopes[key] { return scope }
        let scope = Scope()
        scopes[key] = scope
        return scope
    }

    private func touchScopes(since old: ConfigDocument) {
        let keys = Set(old.overrides.keys).union(document.overrides.keys)
            .filter { old.overrides[$0] != document.overrides[$0] }
        if keys.contains(where: Self.sharedKeys.contains) {
            for scope in scopes.values { scope.revision += 1 }
        } else {
            for key in keys { scopes[key]?.revision += 1 }
        }
    }
    @Published private(set) var saved: ConfigDocument
    @Published var message = ""
    private(set) var undoStack: [ConfigDocument] = [] {
        didSet { if history.canUndo == undoStack.isEmpty { history.canUndo = !undoStack.isEmpty } }
    }

    private(set) var redoStack: [ConfigDocument] = [] {
        didSet { if history.canRedo == redoStack.isEmpty { history.canRedo = !redoStack.isEmpty } }
    }

    /// Whether there is something to undo and to redo: what the toolbar
    /// watches, which changes far less often than the document.
    final class History: ObservableObject {
        @Published fileprivate(set) var canUndo = false
        @Published fileprivate(set) var canRedo = false
    }

    let history = History()
    /// Called after a change is applied, with the new font size when it changed.
    var onApplied: ((Double?) -> Void)?
    private var pendingSave: Task<Void, Never>?
    private let defaults: UserDefaults
    /// What was saved could not be read: the empty configuration in its
    /// place is not one the user chose.
    private(set) var unreadable = false
    private struct Storage: Codable { let version: Int; let document: ConfigDocument }
    private static let snapshotKey = "sb.moe.tamio.ghosttyConfiguration.v1"
    private static let storageKey = "sb.moe.tamio.ghosttyConfiguration"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var document = ConfigDocument()
        var issue = ""
        do {
            if let data = defaults.data(forKey: Self.snapshotKey) {
                let storage = try JSONDecoder().decode(Storage.self, from: data)
                guard storage.version == 1 else { throw ConfigError.message("Unsupported configuration storage version") }
                document = storage.document
            } else if let source = defaults.string(forKey: Self.storageKey) { try document.merge(source) }
        } catch {
            issue = "Saved configuration could not be read: \(error.localizedDescription). The original is retained until you explicitly save."
            unreadable = true
        }
        self.document = document
        saved = document
        message = issue
    }
    var isDirty: Bool { document != saved }
    func edit(_ mutation: (inout ConfigDocument) -> Void) {
        var next = document
        mutation(&next)
        guard next != document else { return }
        undoStack.append(document)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        document = next
        scheduleSave()
    }
    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.document.text(key) }, set: { value in self.edit { $0.set(key, [value]) } })
    }
    func undo() { guard let previous = undoStack.popLast() else { return }; redoStack.append(document); document = previous; scheduleSave() }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(document); document = next; scheduleSave() }

    /// Settings save themselves: a short pause after the last change, then apply.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, self.isDirty else { return }
            let fontChanged = self.document.overrides["font-size"] != self.saved.overrides["font-size"]
            if self.save(), fontChanged {
                self.onApplied?(self.document.overrides["font-size"]?.first.flatMap(Double.init) ?? 14)
            }
        }
    }
    func reset(_ key: String) { edit { $0.overrides.removeValue(forKey: key) } }
    /// Writes the values, or removes the key when there is nothing to write.
    func setOrRemove(_ key: String, _ values: [String]) {
        edit { document in
            if values.isEmpty { document.overrides.removeValue(forKey: key) } else { document.set(key, values) }
        }
    }
    func importConfig(_ source: String) throws {
        var next = document
        try next.merge(source)
        edit { $0 = next }
    }
    func save() -> Bool {
        do {
            try TamioTerminalConfiguration.apply(document)
            defaults.set(try JSONEncoder().encode(Storage(version: 1, document: document)), forKey: Self.snapshotKey)
            saved = document
            message = ""
            unreadable = false
            return true
        } catch { message = error.localizedDescription; return false }
    }
    static func storedDocument() -> ConfigDocument { ConfigEditorModel().document }

    /// Puts in place the configuration another device saved. Undo does not
    /// reach back across it: the change was not made here.
    func adoptSynced(_ next: ConfigDocument) {
        pendingSave?.cancel()
        undoStack.removeAll()
        redoStack.removeAll()
        document = next
        _ = save()
    }
}

/// The terminal's configuration as iCloud sync carries it.
@MainActor
public enum TerminalConfigurationSync {
    /// The saved configuration; nil when what was saved could not be read,
    /// so an empty one is not sent over the other devices' own.
    public static var value: Data? {
        let model = ConfigEditorModel.shared
        guard !model.unreadable else { return nil }
        let encoder = JSONEncoder()
        // The same configuration is the same bytes on every device.
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(model.saved)
    }

    public static func adopt(_ data: Data) {
        guard let document = try? JSONDecoder().decode(ConfigDocument.self, from: data),
              document != ConfigEditorModel.shared.saved
        else { return }
        ConfigEditorModel.shared.adoptSynced(document)
    }
}

/// Shared by existing and future SSH surfaces. Updating this controller preserves the backend and scrollback.
@MainActor
enum TamioTerminalConfiguration {
    static let didApply = Notification.Name("TamioTerminalConfigurationDidApply")
    static var appliedFontSize: Double? = ConfigEditorModel.storedDocument().overrides["font-size"]?.first.flatMap(Double.init)
    static let controller: TerminalController = {
        let result = TerminalController(configuration: baseConfiguration
            .custom("clipboard-read", "ask").custom("clipboard-write", "ask"))
        let document = ConfigEditorModel.storedDocument()
        if !document.overrides.isEmpty { try? apply(document, to: result) }
        return result
    }()

    /// Values Tamio's terminal starts from where they differ from Ghostty's own
    /// defaults (font size 14, thickened text, blinking block cursor). The editor
    /// shows these as the defaults, because they are what the terminal uses.
    /// What every terminal starts from: the renderer's defaults, and room
    /// between the text and the edges of the rounded box the terminal sits
    /// in, which Ghostty's two points leave too tight to read.
    nonisolated static let baseConfiguration = TerminalConfiguration.default
        .windowPaddingX(12)
        .windowPaddingY(10)

    nonisolated static let runtimeDefaults: [String: [String]] = {
        var result: [String: [String]] = [:]
        for line in baseConfiguration.rendered.components(separatedBy: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            result[key, default: []].append(value)
        }
        return result
    }()

    nonisolated static let supportedKeys: Set<String> = [
        "background", "foreground", "background-opacity", "background-blur", "background-opacity-cells",
        "selection-background", "selection-foreground", "selection-clear-on-typing", "selection-clear-on-copy",
        "cursor-color", "cursor-text", "cursor-style", "cursor-style-blink", "cursor-opacity", "cursor-click-to-move",
        "palette", "bold-color", "minimum-contrast", "theme", "keybind", "font-size",
        "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic", "font-feature",
        "font-variation", "font-variation-bold", "font-variation-italic", "font-variation-bold-italic",
        "font-thicken", "font-thicken-strength", "font-style", "font-style-bold", "font-style-italic", "font-style-bold-italic",
        "font-codepoint-map", "font-synthetic-style", "freetype-load-flags", "grapheme-width-method",
        "adjust-cell-width", "adjust-cell-height", "adjust-font-baseline", "adjust-underline-position", "adjust-underline-thickness",
        "adjust-strikethrough-position", "adjust-strikethrough-thickness", "adjust-cursor-thickness", "adjust-cursor-height",
        "adjust-box-thickness", "adjust-overline-position", "adjust-overline-thickness",
        "mouse-hide-while-typing", "mouse-shift-capture", "mouse-scroll-multiplier", "scrollback-limit",
        "window-padding-x", "window-padding-y", "window-padding-balance", "window-padding-color",
        "copy-on-select", "clipboard-trim-trailing-spaces", "clipboard-paste-protection", "clipboard-paste-bracketed-safe",
        "link-url", "image-storage-limit", "title", "vt-kam-allowed", "enquiry-response"
    ]
    nonisolated static let supportedActions: Set<String> = [
        "ignore", "unbind", "csi", "esc", "text", "cursor_key", "reset", "copy_to_clipboard", "paste_from_clipboard",
        "paste_from_selection", "copy_url_to_clipboard", "copy_title_to_clipboard", "increase_font_size", "decrease_font_size",
        "reset_font_size", "set_font_size", "clear_screen", "select_all", "scroll_to_top", "scroll_to_bottom",
        "scroll_to_selection", "scroll_to_row", "scroll_page_up", "scroll_page_down", "scroll_page_fractional", "scroll_page_lines",
        "adjust_selection", "jump_to_prompt", "toggle_readonly", "toggle_mouse_reporting", "end_key_sequence"
    ]
    static func runtimeContents(_ document: ConfigDocument, dark: Bool) -> String {
        var lines = [baseConfiguration.rendered]
        if let theme = document.effectiveTheme(dark: dark) {
            lines += theme.entries.map { "\($0.0) = \($0.1)" }
        }
        for key in document.overrides.keys.sorted() where supportedKeys.contains(key) && key != "theme" {
            for value in document.overrides[key] ?? [] {
                if key == "keybind" {
                    let parsed = ConfigKeybinding(value)
                    guard parsed.errors.isEmpty, parsed.prefixes.allSatisfy({ $0 != "global" && $0 != "all" }),
                          supportedActions.contains(parsed.action) else { continue }
                }
                // Values are a single Ghostty line; multiline text is represented by escapes.
                guard !value.contains("\n"), !value.contains("\r") else { continue }
                lines.append("\(key) = \(value)")
            }
        }
        lines += ["clipboard-read = ask", "clipboard-write = ask"]
        return lines.joined(separator: "\n")
    }
    static func apply(_ document: ConfigDocument, to target: TerminalController? = nil) throws {
        for (key, values) in document.overrides where supportedKeys.contains(key) {
            if values.contains(where: { $0.contains("\n") || $0.contains("\r") }) {
                throw ConfigError.message("\(key): use escaped characters instead of literal newlines")
            }
        }
        let isShared = target == nil
        let target = target ?? controller
        // Themes are materialized from the bundled catalog, so all 633 work offline.
        // Two theme variants are generated with explicit overrides last.
        let light = runtimeContents(document, dark: false)
        let dark = runtimeContents(document, dark: true)
        // Validate both variants before changing the live controller.
        for contents in Set([light, dark]) {
            let validation = TerminalController(configSource: .generated(contents), theme: .init())
            if let issue = validation.lastConfigurationIssue { throw ConfigError.message(issue) }
        }
        func configuration(_ text: String) -> TerminalConfiguration {
            text.components(separatedBy: "\n").reduce(TerminalConfiguration()) { result, line in
                guard let eq = line.firstIndex(of: "=") else { return result }
                return result.custom(String(line[..<eq]).trimmingCharacters(in: .whitespaces),
                                     String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        let theme = TerminalTheme(light: configuration(light), dark: configuration(dark))
        if target.theme != theme, !target.setTheme(theme) {
            throw ConfigError.message(target.lastConfigurationIssue ?? "Unable to apply configuration")
        }
        if isShared {
            appliedFontSize = document.overrides["font-size"]?.first.flatMap(Double.init)
            NotificationCenter.default.post(name: didApply, object: nil)
        }
    }
}

#if DEBUG
    /// For the app's Settings benchmark: an edit as a control would make it.
    @MainActor
    public enum ConfigBenchmark {
        public static func edit(_ key: String, _ value: String?) {
            ConfigEditorModel.shared.edit { document in
                if let value { document.set(key, [value]) } else { document.overrides.removeValue(forKey: key) }
            }
        }

        public static func value(_ key: String) -> String? {
            ConfigEditorModel.shared.document.overrides[key]?.first
        }
    }
#endif
