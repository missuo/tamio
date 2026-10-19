import CoreText
import TamioDesign
import SwiftUI

/// The fonts installed on this device, read once through CoreText so the same
/// code serves macOS and iOS.
@MainActor
enum FontLibrary {
    struct Face {
        let family: String
        let style: String
        let postScriptName: String
        let monospaced: Bool
    }

    struct Family: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let monospaced: Bool
    }

    static let faces: [Face] = {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        return descriptors.compactMap { descriptor in
            guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !family.hasPrefix("."),
                  let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
            else { return nil }
            let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String ?? "Regular"
            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
            let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let monospaced = symbolic & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0
            return Face(family: family, style: style, postScriptName: name, monospaced: monospaced)
        }
    }()

    static let families: [Family] = {
        var monospaced: [String: Bool] = [:]
        for face in faces { monospaced[face.family] = (monospaced[face.family] ?? false) || face.monospaced }
        return monospaced
            .map { Family(name: $0.key, monospaced: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func isMonospaced(_ family: String) -> Bool {
        families.first { $0.name == family }?.monospaced ?? false
    }

    static func members(of family: String) -> [Face] {
        faces.filter { $0.family == family }
    }

    /// Style/feature/axis lookups are cached per family: editors ask for
    /// them on every render, and each miss creates a CTFont and copies its
    /// tables out of CoreText.
    private static var stylesCache: [String: [String]] = [:]
    private static var featuresCache: [String: [Feature]] = [:]
    private static var axesCache: [String: [Axis]] = [:]

    /// Style names offered when the family is Ghostty's built-in font.
    static let builtInStyles = ["Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold"]

    static func styles(of family: String) -> [String] {
        guard !family.isEmpty else { return builtInStyles }
        if let cached = stylesCache[family] { return cached }
        var seen = Set<String>()
        let result = members(of: family).map(\.style).filter { seen.insert($0).inserted }
        stylesCache[family] = result
        return result
    }

    /// The family's regular face, else its first.
    static func font(of family: String) -> CTFont? {
        let members = members(of: family)
        guard let face = members.first(where: { $0.style == "Regular" }) ?? members.first else { return nil }
        return CTFontCreateWithName(face.postScriptName as CFString, 12, nil)
    }

    struct Axis: Identifiable {
        var id: String { tag }
        let tag: String
        let name: String
        let minimum: Double
        let maximum: Double
        let defaultValue: Double
    }

    /// Variable-font axes (weight, width, slant…).
    static func axes(of family: String) -> [Axis] {
        if let cached = axesCache[family] { return cached }
        var result: [Axis] = []
        if let font = font(of: family),
           let raw = CTFontCopyVariationAxes(font) as? [[CFString: Any]]
        {
            result = raw.compactMap { axis in
                guard let identifier = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber else { return nil }
                let value = identifier.uint32Value
                let tag = String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .ascii) ?? "\(value)"
                return Axis(
                    tag: tag,
                    name: axis[kCTFontVariationAxisNameKey] as? String ?? tag,
                    minimum: (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue ?? 0,
                    maximum: (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue ?? 0,
                    defaultValue: (axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue ?? 0
                )
            }
        }
        axesCache[family] = result
        return result
    }

    struct Feature: Identifiable, Hashable {
        var id: String { tag }
        let tag: String
        let name: String
        let group: String
        let defaultOn: Bool
    }

    /// OpenType features the family's font actually has, named by the font.
    static func features(of family: String) -> [Feature] {
        guard !family.isEmpty else { return builtInFeatures }
        if let cached = featuresCache[family] { return cached }
        var result: [String: Feature] = [:]
        var order: [String] = []
        if let font = font(of: family), let types = CTFontCopyFeatures(font) as? [[CFString: Any]] {
            for type in types {
                let typeName = type[kCTFontFeatureTypeNameKey] as? String ?? "Other"
                for selector in type[kCTFontFeatureTypeSelectorsKey] as? [[CFString: Any]] ?? [] {
                    guard let tag = selector[kCTFontOpenTypeFeatureTag] as? String else { continue }
                    let value = (selector[kCTFontOpenTypeFeatureValue] as? NSNumber)?.intValue ?? 1
                    let isDefault = (selector[kCTFontFeatureSelectorDefaultKey] as? NSNumber)?.boolValue ?? false
                    let selectorName = selector[kCTFontFeatureSelectorNameKey] as? String ?? tag
                    // Character variants and stylistic sets arrive one feature type
                    // each, with selectors named just "On"/"Off": gather them into one
                    // group and name each by its type.
                    let generic = ["on", "off", "enabled", "disabled"].contains(selectorName.lowercased())
                    let name = generic ? typeName : selectorName
                    let group = featureGroup(tag: tag, fallback: typeName)
                    let existing = result[tag]
                    if existing == nil { order.append(tag) }
                    result[tag] = Feature(
                        tag: tag,
                        name: value != 0 ? name : existing?.name ?? name,
                        group: group,
                        defaultOn: isDefault ? value != 0 : existing?.defaultOn ?? false
                    )
                }
            }
        }
        let features = order.compactMap { result[$0] }
        featuresCache[family] = features
        return features
    }

    /// "cv01"–"cv99" and "ss01"–"ss99" get their own groups.
    private static func featureGroup(tag: String, fallback: String) -> String {
        guard tag.count == 4, tag.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { return fallback }
        if tag.hasPrefix("cv") { return "Character Variants" }
        if tag.hasPrefix("ss") { return "Stylistic Sets" }
        return fallback
    }

    /// Ghostty's built-in JetBrains Mono is not installed, so its features are listed here.
    static let builtInFeatures: [Feature] = [
        Feature(tag: "calt", name: "Ligatures (contextual alternates)", group: "Ligatures", defaultOn: true),
        Feature(tag: "zero", name: "Slashed zero", group: "Characters", defaultOn: false),
    ] + (1 ... 20).map { index in
        Feature(tag: String(format: "ss%02d", index), name: "Stylistic set \(index)", group: "Stylistic Sets", defaultOn: false)
    } + (1 ... 20).map { index in
        Feature(tag: String(format: "cv%02d", index), name: "Character variant \(index)", group: "Character Variants", defaultOn: false)
    }
}

/// The family a per-style setting applies to: its own family key, else the main font.
@MainActor
func configFamily(for key: String, prefix: String, in document: ConfigDocument) -> String {
    let own = key.replacingOccurrences(of: prefix, with: "font-family")
    return document.overrides[own]?.first ?? document.overrides["font-family"]?.first ?? ""
}

/// A button showing the chosen family in its own typeface; opens the font list.
struct ConfigFontPicker: View {
    /// Outer width shared by the font and style pickers so they line up.
    static let width: CGFloat = 224

    /// macOS opens the list above the button; iPad below it, where the screen
    /// has room for the list.
    #if os(macOS) || targetEnvironment(macCatalyst)
        private static let arrowEdge: Edge = .bottom
    #else
        private static let arrowEdge: Edge = .top
    #endif

    @Binding var family: String
    /// Shown when no family is set.
    let placeholder: String
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: RX.Space.s2) {
                Text(family.isEmpty ? placeholder : family)
                    .font(family.isEmpty ? .rxBody : .custom(family, size: 13))
                    .foregroundStyle(family.isEmpty ? Color.rxInkSecondary : Color.rxInk)
                    .lineLimit(1)
                Spacer(minLength: RX.Space.s2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.rxInkSecondary)
            }
            .frame(width: Self.width - 28)
        }
        .buttonStyle(.rx)
        .help("Choose a font installed on this Mac")
        .popover(isPresented: $open, arrowEdge: Self.arrowEdge) {
            FontFamilyList(selection: $family, placeholder: placeholder) { open = false }
        }
    }
}

/// Installed families, each drawn in its own typeface, with search and a
/// monospaced-only filter (on by default: terminals need fixed-width glyphs).
private struct FontFamilyList: View {
    @Binding var selection: String
    let placeholder: String
    let done: () -> Void
    @State private var search = ""
    @State private var monospacedOnly: Bool

    init(selection: Binding<String>, placeholder: String, done: @escaping () -> Void) {
        _selection = selection
        self.placeholder = placeholder
        self.done = done
        let current = selection.wrappedValue
        _monospacedOnly = State(initialValue: current.isEmpty || FontLibrary.isMonospaced(current))
    }

    private var families: [FontLibrary.Family] {
        FontLibrary.families.filter { family in
            (!monospacedOnly || family.monospaced)
                && (search.isEmpty || family.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            RXSearchField("Search fonts", text: $search, width: nil)
            Toggle(ConfigLayout.tr("font.monospaced_only", default: "Monospaced fonts only"), isOn: $monospacedOnly)
                .rxCheckboxToggle()
                .font(.rxHelp)
            ScrollViewReader { proxy in
                List {
                    row(name: "", title: placeholder, font: .rxBody)
                    ForEach(families) { family in
                        row(name: family.name, title: family.name, font: .custom(family.name, size: 14))
                            .id(family.name)
                    }
                }
                .listStyle(.plain)
                .onAppear { if !selection.isEmpty { proxy.scrollTo(selection, anchor: .center) } }
            }
            if families.isEmpty {
                HelpText(ConfigLayout.tr("font.no_matching_fonts", default: "No installed font matches."))
            }
        }
        .padding(RX.Space.s3)
        #if os(macOS) || targetEnvironment(macCatalyst)
        .frame(width: 320, height: 420)
        #else
        // A List has no height of its own; give the iPad popover one (on iPhone
        // this is a sheet, which ignores the ideal size).
        .frame(minWidth: 320, idealWidth: 360, minHeight: 420, idealHeight: 560)
        #endif
    }

    private func row(name: String, title: String, font: Font) -> some View {
        Button {
            selection = name
            done()
        } label: {
            HStack {
                Text(title).font(font).lineLimit(1)
                Spacer()
                if selection == name {
                    Image(systemName: "checkmark").foregroundStyle(.rxAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `font-family`: the main font, then fallbacks tried in order for missing glyphs.
struct ConfigFontFamilyEditor: View {
    let model: ConfigEditorModel
    /// Its row says when to draw again (see `ConfigEditorModel.Scope`).
    @Environment(\.configRevision) private var revision
    let key: String
    /// Bold / italic families may be left unset to follow the main font.
    let placeholder: String
    /// A fallback row being chosen; it reaches the document once a font is picked.
    @State private var addingFallback = false

    private var families: [String] { model.document.overrides[key] ?? [] }

    private func write(_ values: [String]) {
        model.setOrRemove(key, values.filter { !$0.isEmpty })
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: RX.Space.s2) {
            ConfigFontPicker(
                family: Binding(get: { families.first ?? "" }, set: { name in
                    var next = families
                    if next.isEmpty { next = [name] } else { next[0] = name }
                    write(next)
                }),
                placeholder: placeholder
            )
            ForEach(Array(families.enumerated().dropFirst()), id: \.offset) { index, _ in
                HStack(spacing: RX.Space.s1) {
                    Text(ConfigLayout.tr("font.fallback", default: "Fallback"))
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                    ConfigFontPicker(
                        family: Binding(get: { families.indices.contains(index) ? families[index] : "" }, set: { name in
                            var next = families
                            guard next.indices.contains(index) else { return }
                            next[index] = name
                            write(next)
                        }),
                        placeholder: ConfigLayout.tr("font.choose_placeholder", default: "Choose…")
                    )
                    RXIconButton(ConfigLayout.tr("font.remove_fallback", default: "Remove Fallback"), systemImage: "minus.circle", kind: .plain, size: .small) {
                        var next = families
                        guard next.indices.contains(index) else { return }
                        next.remove(at: index)
                        write(next)
                    }
                }
            }
            if addingFallback {
                HStack(spacing: RX.Space.s1) {
                    Text(ConfigLayout.tr("font.fallback", default: "Fallback"))
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                    ConfigFontPicker(
                        family: Binding(get: { "" }, set: { name in
                            addingFallback = false
                            if !name.isEmpty { write(families + [name]) }
                        }),
                        placeholder: ConfigLayout.tr("font.choose_placeholder", default: "Choose…")
                    )
                    RXIconButton(ConfigLayout.tr("action.cancel", default: "Cancel"), systemImage: "minus.circle", kind: .plain, size: .small) {
                        addingFallback = false
                    }
                }
            } else if !families.isEmpty {
                Button {
                    addingFallback = true
                } label: {
                    Label(ConfigLayout.tr("font.add_fallback", default: "Add Fallback"), systemImage: "plus")
                }
                .buttonStyle(.rx(.plain, size: .small))
                .fixedSize()
                .help(ConfigLayout.tr("font.fallback_help", default: "Used for characters the main font does not have"))
            }
        }
    }
}

/// `font-style…`: the styles the chosen family actually has.
struct ConfigFontStylePicker: View {
    let model: ConfigEditorModel
    /// Its row says when to draw again (see `ConfigEditorModel.Scope`).
    @Environment(\.configRevision) private var revision
    let key: String

    /// The family this style applies to: its own family key, else the main font.
    private var family: String { configFamily(for: key, prefix: "font-style", in: model.document) }

    private func name(_ value: String) -> String {
        switch value {
        case "default", "": return ConfigLayout.tr("option.default", default: "Default")
        case "false": return ConfigLayout.tr("font.style_disabled", default: "Disabled (use regular)")
        default: return value
        }
    }

    var body: some View {
        let value = model.binding(key)
        let styles = FontLibrary.styles(of: family)
        Menu {
            Picker(ConfigLayout.tr("font.picker_style", default: "Style"), selection: value) {
                Text(ConfigLayout.tr("option.default", default: "Default")).tag("default")
                if key != "font-style" {
                    Text(ConfigLayout.tr("font.style_disabled", default: "Disabled (use regular)")).tag("false")
                }
                Divider()
                ForEach(styles, id: \.self) { Text($0).tag($0) }
                if !["default", "false", ""].contains(value.wrappedValue), !styles.contains(value.wrappedValue) {
                    Text(value.wrappedValue).tag(value.wrappedValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: RX.Space.s2) {
                Text(name(value.wrappedValue))
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                Spacer(minLength: RX.Space.s2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.rxInkSecondary)
            }
            .frame(width: ConfigFontPicker.width - 28)
        }
        .rxButtonMenu(indicator: false)
        .buttonStyle(.rx)
        .fixedSize()
        .help(family.isEmpty ? ConfigLayout.tr("font.styles_builtin_help", default: "Styles of the built-in font") : String(format: ConfigLayout.tr("font.styles_installed_help", default: "Styles installed for %@"), family))
    }
}

/// `font-feature`: the chosen font's OpenType features as switches, grouped as
/// the font groups them. A switch left at the font's default writes nothing.
struct ConfigFontFeatureEditor: View {
    let model: ConfigEditorModel
    /// Its row says when to draw again (see `ConfigEditorModel.Scope`).
    @Environment(\.configRevision) private var revision
    @State private var custom = ""

    private var family: String { model.document.overrides["font-family"]?.first ?? "" }
    private var entries: [String] { model.document.overrides["font-feature"] ?? [] }

    /// `tag`, `+tag`, `tag=1`, `tag=on` turn a feature on; `-tag`, `tag=0`, `tag=off` turn it off.
    private func parse(_ entry: String) -> (tag: String, on: Bool) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("-") { return (String(trimmed.dropFirst()), false) }
        if trimmed.hasPrefix("+") { return (String(trimmed.dropFirst()), true) }
        if let eq = trimmed.firstIndex(of: "=") {
            let value = trimmed[trimmed.index(after: eq)...].lowercased()
            return (String(trimmed[..<eq]), !["0", "off", "false"].contains(value))
        }
        return (trimmed, true)
    }

    private func isOn(_ feature: FontLibrary.Feature) -> Bool {
        entries.last { parse($0).tag == feature.tag }.map { parse($0).on } ?? feature.defaultOn
    }

    private func set(_ feature: FontLibrary.Feature, on: Bool) {
        var next = entries.filter { parse($0).tag != feature.tag }
        if on != feature.defaultOn { next.append(on ? feature.tag : "-" + feature.tag) }
        write(next)
    }

    private func write(_ values: [String]) {
        model.setOrRemove("font-feature", values)
    }

    var body: some View {
        let features = FontLibrary.features(of: family)
        let known = Set(features.map(\.tag))
        let groups = Dictionary(grouping: features, by: \.group)
        let groupOrder = features.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            if features.isEmpty {
                HelpText(String(format: ConfigLayout.tr("font.no_features_help", default: "%@ has no OpenType features to switch."), family))
            }
            ForEach(groupOrder, id: \.self) { group in
                VStack(alignment: .leading, spacing: 6) {
                    CapsLabel(group)
                    RXFlowLayout(spacing: 6) {
                        ForEach(groups[group] ?? []) { feature in
                            RXChip(feature.name, isOn: isOn(feature)) { set(feature, on: !isOn(feature)) }
                                .help("\(feature.tag)\(feature.defaultOn ? " · on by default" : "")")
                        }
                    }
                }
            }
            let others = entries.filter { !known.contains(parse($0).tag) }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    CapsLabel(ConfigLayout.tr("font.other_features", default: "Other"))
                    RXFlowLayout(spacing: 6) {
                        ForEach(others, id: \.self) { entry in
                            RXChip(entry, isOn: true) { write(entries.filter { $0 != entry }) }
                                .help(String(format: ConfigLayout.tr("font.remove_feature", default: "Remove %@"), entry))
                        }
                    }
                }
            }
            HStack(spacing: RX.Space.s2) {
                TextField(ConfigLayout.tr("font.other_feature_placeholder", default: "Other feature, e.g. ss07 or -liga"), text: $custom)
                    .textFieldStyle(.rxMono)
                    .frame(width: 240)
                    .onSubmit(addCustom)
                Button(ConfigLayout.tr("action.add", default: "Add"), action: addCustom)
                    .buttonStyle(.rx(size: .small))
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if family.isEmpty {
                HelpText(ConfigLayout.tr("font.features_builtin_note", default: "Showing the features of the built-in font; choose a font under Font to see its own."))
            }
        }
    }

    private func addCustom() {
        let value = custom.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        write(entries.filter { parse($0).tag != parse(value).tag } + [value])
        custom = ""
    }
}

/// `font-variation…`: a slider and field per axis of the chosen variable font.
/// An axis left at its default writes nothing.
struct ConfigFontVariationEditor: View {
    let model: ConfigEditorModel
    /// Its row says when to draw again (see `ConfigEditorModel.Scope`).
    @Environment(\.configRevision) private var revision
    let key: String

    private var family: String { configFamily(for: key, prefix: "font-variation", in: model.document) }
    private var entries: [String] { model.document.overrides[key] ?? [] }

    private func value(_ axis: FontLibrary.Axis) -> Double {
        for entry in entries.reversed() {
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == axis.tag, let number = Double(parts[1]) { return number }
        }
        return axis.defaultValue
    }

    private func set(_ axis: FontLibrary.Axis, _ number: Double) {
        var next = entries.filter { !$0.hasPrefix(axis.tag + "=") }
        if abs(number - axis.defaultValue) > 0.0001 { next.append("\(axis.tag)=\(number.formatted(.number.grouping(.never)))") }
        model.setOrRemove(key, next)
    }

    var body: some View {
        let axes = FontLibrary.axes(of: family)
        VStack(alignment: .trailing, spacing: RX.Space.s2) {
            if family.isEmpty {
                HelpText(ConfigLayout.tr("font.variation_choose_note", default: "Choose a variable font under Font to adjust its axes."))
            } else if axes.isEmpty {
                HelpText(String(format: ConfigLayout.tr("font.not_variable_font", default: "%@ is not a variable font."), family))
            }
            ForEach(axes) { axis in
                HStack(spacing: RX.Space.s2) {
                    Text(axis.name)
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                        .frame(width: 80, alignment: .trailing)
                        .help(axis.tag)
                    RXSlider(
                        value: Binding(get: { value(axis) }, set: { set(axis, $0) }),
                        in: axis.minimum ... max(axis.maximum, axis.minimum + 0.01),
                        step: axis.maximum - axis.minimum > 10 ? 1 : 0.01
                    )
                }
            }
        }
    }
}

/// A byte count edited in megabytes.
struct ConfigByteInput: View {
    @Binding var value: String
    let fallback: String

    /// Inputs are clamped far below Int.max so the Int conversion can never trap.
    private static let maxMegabytes: Double = 1e12

    private var megabytes: Double { (Double(value.isEmpty ? fallback : value) ?? 0) / 1_000_000 }

    private func set(megabytes: Double) {
        let clamped = min(max(0, megabytes), Self.maxMegabytes)
        value = String(Int(clamped * 1_000_000))
    }

    var body: some View {
        HStack(spacing: RX.Space.s1) {
            TextField(ConfigLayout.tr("byte.mb", default: "MB"), value: Binding(get: { megabytes }, set: { set(megabytes: $0) }), format: .number.precision(.fractionLength(0 ... 1)))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.rx)
                .frame(width: 96)
            Stepper(ConfigLayout.tr("byte.megabytes", default: "Megabytes"), onIncrement: { set(megabytes: megabytes + 1) },
                    onDecrement: { set(megabytes: megabytes - 1) })
                .labelsHidden()
            Text(ConfigLayout.tr("byte.mb", default: "MB"))
                .font(.rxBody)
                .foregroundStyle(.rxInkSecondary)
        }
    }
}
