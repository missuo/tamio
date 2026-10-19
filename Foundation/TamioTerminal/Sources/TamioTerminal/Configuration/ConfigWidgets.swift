#if os(macOS)
    import AppKit
#else
    import UIKit
#endif
import TamioDesign
import SwiftUI

/// A setting drawn with the settings-row vocabulary: name and the catalog's first
/// sentence on the left, the control right-aligned. Wide editors sit underneath.
struct ConfigSettingRow: View {
    let model: ConfigEditorModel
    let setting: ConfigSetting
    var query = ""
    /// The row is drawn again when its setting changes, not when any does.
    @ObservedObject private var scope: ConfigEditorModel.Scope
    @State private var help = false

    init(model: ConfigEditorModel, setting: ConfigSetting, query: String = "") {
        self.model = model
        self.setting = setting
        self.query = query
        scope = model.scope(setting.key)
    }

    private var highlightedName: AttributedString {
        var text = AttributedString(ConfigLayout.title(setting))
        for token in query.split(whereSeparator: \.isWhitespace) {
            if let range = text.range(of: String(token), options: .caseInsensitive) {
                text[range].foregroundColor = Color.rxAccent
                text[range].underlineStyle = .single
            }
        }
        return text
    }

    private var widgetType: String {
        setting.widget?.type ?? (setting.repeatable == true ? "repeatable-text" : "text")
    }

    /// Editors that need the full row width.
    private var stacked: Bool {
        if setting.key == "keybind" { return true }
        if setting.key.hasPrefix("font-family") { return false }
        if setting.key.hasPrefix("font-variation") || setting.key == "font-feature" || setting.key == "font-codepoint-map" { return true }
        return ["theme", "palette", "repeatable-text", "feature-list"].contains(widgetType)
    }

    private var isModified: Bool { model.document.overrides[setting.key] != nil }

    #if os(iOS) && !targetEnvironment(macCatalyst)
        @Environment(\.horizontalSizeClass) private var sizeClass
        /// On a narrow iPhone screen every control goes under its title.
        private var widgetBelow: Bool { stacked || sizeClass == .compact }
    #else
        private var widgetBelow: Bool { stacked }
    #endif

    /// Tamio's wording, else the catalog description's first sentence, without markdown.
    private var summary: String { ConfigLayout.summary(setting) }

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            RXRowLayout(alignTop: stacked) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(highlightedName)
                            .font(.rxBody)
                            .foregroundStyle(.rxInk)
                        if setting.deprecated != nil {
                            RXTag(ConfigLayout.tr("badge.deprecated", default: "Deprecated"), style: .warning)
                        }
                    }
                    if !summary.isEmpty {
                        HelpText(summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Ghostty setting: \(setting.key)")
                HStack(spacing: RX.Space.s2) {
                    if !widgetBelow {
                        ConfigWidgetView(model: model, setting: setting)
                            .disabled(setting.disabled == true)
                    }
                    Button { help.toggle() } label: {
                        Label(String(format: ConfigLayout.tr("action.about_setting", default: "About %@"), ConfigLayout.title(setting)), systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
                    .help(String(format: ConfigLayout.tr("action.about_setting", default: "About %@"), ConfigLayout.title(setting)))
                    .popover(isPresented: $help) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: RX.Space.s3) {
                                Text(ConfigLayout.title(setting)).font(.rxSheetTitle)
                                Text(setting.key)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.rxInkSecondary)
                                    .textSelection(.enabled)
                                Text(.init(setting.description)).font(.rxBody)
                                if let note = setting.note {
                                    HelpText(note.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                                }
                                Link(ConfigLayout.tr("link.ghostty_docs", default: "Ghostty documentation"), destination: URL(string: "https://ghostty.org/docs/config/reference#" + setting.key)!)
                            }
                            .padding(RX.Space.s4)
                            #if os(macOS) || targetEnvironment(macCatalyst)
                            .frame(width: 430, alignment: .leading)
                            #else
                            .frame(maxWidth: .infinity, alignment: .leading)
                            #endif
                        }
                        #if os(macOS) || targetEnvironment(macCatalyst)
                        .frame(maxHeight: 500)
                        #else
                        .frame(minWidth: 320, idealWidth: 430, minHeight: 240, idealHeight: 420)
                        #endif
                    }
                    // Only a changed setting can be reset; the slot stays so controls don't shift.
                    Button { model.reset(setting.key) } label: {
                        Label(ConfigLayout.tr("action.reset_default", default: "Reset to Default"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
                    .opacity(isModified ? 1 : 0)
                    .disabled(!isModified)
                    .help(String(format: ConfigLayout.tr("help.reset_setting_default", default: "Reset %@ to its default"), ConfigLayout.title(setting)))
                    .animation(.easeOut(duration: 0.15), value: isModified)
                }
            }
            if widgetBelow {
                ConfigWidgetView(model: model, setting: setting)
                    .disabled(setting.disabled == true)
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: RX.formRowMinHeight)
        .environment(\.configRevision, scope.revision)
    }
}

/// How every widget type in the catalog is drawn (see the design system's SettingControls).
struct ConfigWidgetView: View {
    let model: ConfigEditorModel
    /// Its row says when to draw again (see `ConfigEditorModel.Scope`).
    @Environment(\.configRevision) private var revision
    let setting: ConfigSetting
    @Environment(\.colorScheme) private var scheme
    private var value: Binding<String> { model.binding(setting.key) }
    private var widget: ConfigWidget? { setting.widget }
    private var effective: String {
        value.wrappedValue.isEmpty ? setting.defaultValue.values.first ?? "" : value.wrappedValue
    }

    @ViewBuilder var body: some View {
        switch setting.key {
        case "font-family":
            ConfigFontFamilyEditor(model: model, key: setting.key, placeholder: "Built-in (JetBrains Mono)")
        case "font-family-bold", "font-family-italic", "font-family-bold-italic":
            ConfigFontFamilyEditor(model: model, key: setting.key, placeholder: "Same as main font")
        case "font-style", "font-style-bold", "font-style-italic", "font-style-bold-italic":
            ConfigFontStylePicker(model: model, key: setting.key)
        case "scrollback-limit", "image-storage-limit":
            ConfigByteInput(value: value, fallback: setting.defaultValue.values.first ?? "0")
        case "font-feature":
            ConfigFontFeatureEditor(model: model)
        case "font-variation", "font-variation-bold", "font-variation-italic", "font-variation-bold-italic":
            ConfigFontVariationEditor(model: model, key: setting.key)
        case "font-codepoint-map":
            ConfigCodepointMapEditor(model: model)
        default:
            catalogWidget
        }
    }

    @ViewBuilder private var catalogWidget: some View {
            switch widget?.type ?? (setting.repeatable == true ? "repeatable-text" : "text") {
            case "switch":
                Toggle(setting.name, isOn: Binding(get: { effective.lowercased() == "true" }, set: { value.wrappedValue = String($0) }))
                    .labelsHidden()
                    .rxSwitchToggle()
                    .controlSize(.small)
                    .tint(.rxAccent)
            case "range":
                RXSlider(
                    value: Binding(get: { Double(effective) ?? widget?.min ?? 0 }, set: { value.wrappedValue = String(format: "%g", $0) }),
                    in: (widget?.min ?? 0) ... (widget?.max ?? 1),
                    step: widget?.step ?? 0.01
                )
            case "pill" where (widget?.options ?? []).count <= 4 && !(widget?.options ?? []).isEmpty:
                RXSegmented(
                    selection: Binding(get: { effective }, set: { value.wrappedValue = $0 }),
                    options: (widget?.options ?? []).map { .init($0.value, ConfigLayout.optionName(setting.key, value: $0.value, fallback: $0.name)) },
                    caps: false
                )
            case "dropdown", "pill":
                optionPicker
            case "color": colorInput
            case "custom-color", "custom-number":
                HStack(spacing: RX.Space.s2) {
                    Menu {
                        ForEach(widget?.presets ?? []) { option in Button(option.name) { value.wrappedValue = option.value } }
                    } label: {
                        Text(ConfigLayout.tr("menu.presets", default: "Presets"))
                    }
                    .rxButtonMenu()
                    .buttonStyle(.rx(size: .small))
                    .fixedSize()
                    .help(ConfigLayout.tr("help.choose_common_value", default: "Choose a common value"))
                    if widget?.type == "custom-color" { colorInput } else { numericInput }
                }
            case "number": numericInput
            case "theme": ConfigThemePicker(value: value)
            case "palette": ConfigPaletteEditor(model: model)
            case "repeatable-text": ConfigRepeatableEditor(model: model, key: setting.key)
            case "feature-list":
                RXFlowLayout(spacing: 6) {
                    ForEach(widget?.features ?? []) { feature in
                        RXChip(feature.label, isOn: featureValue(feature)) {
                            var state = Dictionary(uniqueKeysWithValues: (widget?.features ?? []).map { ($0.id, featureValue($0)) })
                            state[feature.id] = !featureValue(feature)
                            value.wrappedValue = (widget?.features ?? []).filter { state[$0.id] != $0.defaultValue }
                                .map { state[$0.id] == true ? $0.id : "no-" + $0.id }.joined(separator: ",")
                        }
                        .help(feature.description ?? "")
                    }
                }
            case "dual-number", "scroll-multiplier":
                ConfigPairInput(
                    value: value,
                    scroll: widget?.type == "scroll-multiplier",
                    labels: widget?.labels ?? ["First", "Second"],
                    scrollDefaults: ConfigPairCodec.parse(setting.defaultValue.text, scroll: true).values
                )
            case "duration": ConfigDurationInput(value: value, allowEmpty: widget?.allowEmpty == true)
            case "number-units": ConfigUnitInput(value: value, units: ["px", "%"])
            default:
                if setting.key == "keybind" {
                    ConfigKeybindingList(model: model)
                } else {
                    TextField(widget?.placeholder ?? ConfigLayout.tr("placeholder.not_set", default: "Not set"), text: value)
                        .textFieldStyle(.rx)
                        .frame(width: 240)
                }
            }
    }

    private var optionPicker: some View {
        Picker(setting.name, selection: value) {
            Text(ConfigLayout.tr("option.default", default: "Default")).tag("")
            Divider()
            ForEach(widget?.options ?? []) { option in
                Text(ConfigLayout.optionName(setting.key, value: option.value, fallback: option.name)).tag(option.value).disabled(option.disabled == true)
            }
            if !value.wrappedValue.isEmpty && !(widget?.options ?? []).contains(where: { $0.value == value.wrappedValue }) {
                Text(value.wrappedValue).tag(value.wrappedValue)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var numericInput: some View {
        HStack(spacing: RX.Space.s1) {
            TextField(widget?.placeholder ?? (setting.defaultValue.values.first ?? ConfigLayout.tr("option.default", default: "Default")), text: value)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.rx)
                .frame(width: 96)
            Stepper(setting.name, onIncrement: { step(1) }, onDecrement: { step(-1) })
                .labelsHidden()
                .help(rangeHelp)
        }
    }

    private var rangeHelp: String {
        switch (widget?.min, widget?.max) {
        case let (min?, max?): return "From \(min.formatted()) to \(max.formatted())"
        case let (min?, nil): return "At least \(min.formatted())"
        case let (nil, max?): return "At most \(max.formatted())"
        default: return "Adjust"
        }
    }

    private func step(_ sign: Double) {
        let next = min(widget?.max ?? .greatestFiniteMagnitude, max(widget?.min ?? -.greatestFiniteMagnitude,
            (Double(effective) ?? 0) + sign * (widget?.step ?? 1)))
        value.wrappedValue = String(format: "%g", next)
    }

    private var colorInput: some View {
        HStack(spacing: RX.Space.s2) {
            Text(model.document.overrides[setting.key] != nil ? "Custom" : model.document.effectiveTheme(dark: scheme == .dark) != nil ? "Theme" : "Default")
                .font(.rxHelp)
                .foregroundStyle(.rxInkSecondary)
                .fixedSize()
            ColorPicker(setting.name, selection: Binding(get: { Color(configHex: model.document.effectiveColor(setting.key, dark: scheme == .dark)) }, set: { value.wrappedValue = $0.configHex }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
            TextField("#RRGGBB", text: Binding(get: {
                widget?.type == "color" ? model.document.effectiveColor(setting.key, dark: scheme == .dark) : value.wrappedValue
            }, set: { value.wrappedValue = $0 }))
                .textFieldStyle(.rxMono)
                .frame(width: 96)
        }
    }

    private func featureValue(_ feature: ConfigFeature) -> Bool {
        let raw = value.wrappedValue
        if raw == "true" || raw == "false" { return raw == "true" }
        var result = feature.defaultValue
        for token in raw.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if token == feature.id { result = true }; if token == "no-" + feature.id { result = false }
        }
        return result
    }
}

extension Color {
    /// The basic CSS color names Ghostty also accepts in a configuration.
    private static let configNamedColors: [String: Color] = [
        "black": Color(red: 0, green: 0, blue: 0),
        "silver": Color(red: 0.75, green: 0.75, blue: 0.75),
        "gray": Color(red: 0.5, green: 0.5, blue: 0.5),
        "grey": Color(red: 0.5, green: 0.5, blue: 0.5),
        "white": Color(red: 1, green: 1, blue: 1),
        "maroon": Color(red: 0.5, green: 0, blue: 0),
        "red": Color(red: 1, green: 0, blue: 0),
        "purple": Color(red: 0.5, green: 0, blue: 0.5),
        "fuchsia": Color(red: 1, green: 0, blue: 1),
        "green": Color(red: 0, green: 0.5, blue: 0),
        "lime": Color(red: 0, green: 1, blue: 0),
        "olive": Color(red: 0.5, green: 0.5, blue: 0),
        "yellow": Color(red: 1, green: 1, blue: 0),
        "navy": Color(red: 0, green: 0, blue: 0.5),
        "blue": Color(red: 0, green: 0, blue: 1),
        "teal": Color(red: 0, green: 0.5, blue: 0.5),
        "aqua": Color(red: 0, green: 1, blue: 1),
        "cyan": Color(red: 0, green: 1, blue: 1),
        "magenta": Color(red: 1, green: 0, blue: 1),
        "orange": Color(red: 1, green: 0.65, blue: 0),
        "pink": Color(red: 1, green: 0.75, blue: 0.8),
        "brown": Color(red: 0.65, green: 0.16, blue: 0.16),
    ]

    init(configHex: String) {
        let raw = configHex.replacingOccurrences(of: "#", with: "")
        if raw.count == 6, let n = UInt64(raw, radix: 16) {
            self.init(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
        } else if let named = Self.configNamedColors[raw.lowercased()] {
            self = named
        } else {
            self = .black
        }
    }
    var configHex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if os(macOS)
            guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
            guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#000000" }
        #endif
        return String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

struct ConfigUnitInput: View {
    @Binding var value: String
    let units: [String]
    private var unit: String { units.first(where: { value.hasSuffix($0) }) ?? units[0] }
    private var number: String { units.first(where: { value.hasSuffix($0) }).map { String(value.dropLast($0.count)) } ?? value }
    var body: some View {
        HStack(spacing: RX.Space.s2) {
            TextField("Default", text: Binding(get: { number }, set: { value = $0.isEmpty ? "" : $0 + (unit == "px" ? "" : unit) }))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.rx)
                .frame(width: 96)
            Picker("Unit", selection: Binding(get: { unit }, set: { value = number.isEmpty ? "" : number + ($0 == "px" ? "" : $0) })) {
                ForEach(units, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().fixedSize()
        }
    }
}
struct ConfigPairInput: View {
    @Binding var value: String
    let scroll: Bool
    let labels: [String]
    /// The catalog's own scroll multipliers, so an upstream default change follows through.
    var scrollDefaults: [String] = ["1", "3"]
    private var parts: [String] { ConfigPairCodec.parse(value, scroll: scroll, fallback: scrollDefaults).values }
    private var linked: Bool { ConfigPairCodec.parse(value, scroll: scroll, fallback: scrollDefaults).linked }
    private var names: [String] { scroll ? ["Trackpad", "Wheel"] : labels }

    var body: some View {
        // Side by side when there is room; in a narrow window each caption
        // goes above its field instead of being squeezed a letter per line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: RX.Space.s2) {
                caption(names[0])
                firstField
                linkButton
                caption(names[1])
                secondField
            }
            HStack(alignment: .bottom, spacing: RX.Space.s2) {
                VStack(alignment: .leading, spacing: 3) { caption(names[0]); firstField }
                linkButton
                VStack(alignment: .leading, spacing: 3) { caption(names[1]); secondField }
            }
        }
    }

    private var firstField: some View {
        TextField(names[0], text: Binding(get: { parts[0] }, set: { write($0, linked ? $0 : parts[1], linked) }))
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.rx)
            .frame(width: 56)
    }

    private var secondField: some View {
        TextField(names[1], text: Binding(get: { parts[1] }, set: { write(linked ? $0 : parts[0], $0, linked) }))
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.rx)
            .frame(width: 56)
    }

    @ViewBuilder private var linkButton: some View {
        if !scroll {
            RXIconButton(linked ? "Unlink: set \(names[0]) and \(names[1]) separately" : "Link: use one value for both",
                         systemImage: linked ? "link" : "link.badge.plus", kind: .plain) {
                write(parts[0], parts[1], !linked)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.rxHelp)
            .foregroundStyle(.rxInkSecondary)
            .lineLimit(1)
            .fixedSize()
    }
    private func write(_ a: String, _ b: String, _ linked: Bool) { value = linked ? a : scroll ? "precision:\(a),discrete:\(b)" : "\(a),\(b)" }
}
struct ConfigRepeatableEditor: View {
    let model: ConfigEditorModel
    /// Its row says when to draw again (see `ConfigEditorModel.Scope`).
    @Environment(\.configRevision) private var revision
    let key: String
    var placeholder = "Value"
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.document.values(key).enumerated()), id: \.offset) { index, _ in
                HStack(spacing: RX.Space.s1) {
                    TextField(placeholder, text: Binding(get: { let a = model.document.values(key); return a.indices.contains(index) ? a[index] : "" }, set: { text in
                        model.edit { var a = $0.values(key); guard a.indices.contains(index) else { return }; a[index] = text; $0.set(key, a) }
                    }))
                    .textFieldStyle(.plain)
                    .font(.rxCode)
                    RXIconButton(ConfigLayout.tr("action.move_up", default: "Move Up"), systemImage: "arrow.up", kind: .plain, size: .small) {
                        model.edit { var a = $0.values(key); a.swapAt(index, index - 1); $0.set(key, a) }
                    }
                    .disabled(index == 0)
                    RXIconButton(ConfigLayout.tr("action.remove", default: "Remove"), systemImage: "minus.circle", kind: .plain, size: .small) {
                        model.edit { var a = $0.values(key); a.remove(at: index); $0.set(key, a) }
                    }
                }
                .padding(.horizontal, RX.Space.s2)
                .frame(height: RX.controlHeight)
                Hairline()
            }
            Button {
                model.edit { $0.set(key, $0.values(key) + [""]) }
            } label: {
                Label(ConfigLayout.tr("action.add_value", default: "Add Value"), systemImage: "plus")
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, RX.Space.s2)
                    .frame(height: RX.controlHeight)
                    .background(Color.rxSurfaceSunken)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 420)
        .clipShape(RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous))
        .rxFieldBackground()
    }
}

struct ConfigPairCodec {
    static func parse(_ raw: String, scroll: Bool, fallback: [String] = ["1", "3"]) -> (values: [String], linked: Bool) {
        if scroll && (raw.isEmpty || raw.contains(":")) {
            var values = fallback
            for item in raw.components(separatedBy: ",") {
                let pair = item.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, Double(pair[1]) != nil {
                    if pair[0] == "precision" { values[0] = pair[1] }
                    if pair[0] == "discrete" { values[1] = pair[1] }
                }
            }
            return (values, false)
        }
        let parts = raw.components(separatedBy: ",")
        let first = parts.first ?? "0"
        return ([first, parts.count > 1 ? parts[1] : first], parts.count < 2)
    }
}
