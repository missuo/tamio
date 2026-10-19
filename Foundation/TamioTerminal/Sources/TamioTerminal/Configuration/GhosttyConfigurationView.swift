import TamioDesign
import SwiftUI

/// Rows the app supplies for a group in `ConfigLayout` (General, Connection,
/// About), so its preferences share Settings without coupling this package to
/// TamioStore. The content is the group's rows, usually an `RXDividedStack`.
public struct ConfigHostSettingsSection: Identifiable {
    public let id: String
    let keywords: String
    let content: AnyView

    @MainActor public init<Content: View>(id: String, keywords: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.keywords = keywords
        self.content = AnyView(content())
    }
}

/// All of Settings: a category column, then the selected category's groups as
/// cards. The categories, their order and their groups come from `ConfigLayout`;
/// Ghostty settings are drawn from the catalog, app rows from `hostSections`.
public struct GhosttyConfigurationView: View {
    /// Not observed here: the parts that show the document or the selected
    /// category observe them, so an edit or another category leaves the rest
    /// of Settings as it is.
    private let model: ConfigEditorModel
    @State private var ownNavigation: ConfigNavigation
    private let externalNavigation: ConfigNavigation?
    private var navigation: ConfigNavigation { externalNavigation ?? ownNavigation }
    @State private var search = ""
    @StateObject private var pageState = ConfigPageState()
    @State private var showPreview = true
    @State private var resetConfirm = false
    /// Width beside the category column; the preview sits beside the settings
    /// only when both fit, and above them otherwise.
    @State private var detailWidth: CGFloat = 1200
    private var previewBeside: Bool { detailWidth >= 1000 }
    private let onApplied: ((Double?) -> Void)?
    private let embedded: Bool
    /// False while the app keeps Settings out of sight: it then adds nothing
    /// to the window toolbar.
    private let active: Bool
    private let hostSections: [String: ConfigHostSettingsSection]

    /// Categories with something to show: app categories need their host rows.
    private var categories: [ConfigLayout.Category] {
        ConfigLayout.categories.filter { category in
            category.groups.contains { group in
                group.items.contains { item in
                    switch item {
                    case let .setting(key): return ConfigCatalog.shared.setting(key: key) != nil
                    case let .host(id): return hostSections[id] != nil
                    }
                }
            }
        }
    }

    public init(
        embedded: Bool = false,
        hostSections: [ConfigHostSettingsSection] = [],
        navigation: ConfigNavigation? = nil,
        active: Bool = true,
        onApplied: ((Double?) -> Void)? = nil
    ) {
        model = .shared
        self.hostSections = Dictionary(hostSections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        externalNavigation = navigation
        _ownNavigation = State(initialValue: navigation ?? ConfigNavigation(hostSections.isEmpty ? "text" : "general"))
        self.embedded = embedded
        self.active = active
        self.onApplied = onApplied
        _showPreview = State(initialValue: !embedded)
    }

    private func installApplyHandler() {
        model.onApplied = onApplied
    }

    public var body: some View {
        #if os(macOS) || targetEnvironment(macCatalyst)
            columns
        #else
            CompactSettings(
                categories: categories,
                hostSections: hostSections,
                model: model,
                categoryPage: { category in categoryPage(category) },
                searchContent: { searchContent },
                search: $search,
                resetConfirm: $resetConfirm
            )
            .onAppear(perform: installApplyHandler)
            .confirmationDialog(ConfigLayout.tr("dialog.reset_terminal.title", default: "Reset every terminal setting to its default?"), isPresented: $resetConfirm) {
                Button(ConfigLayout.tr("action.reset", default: "Reset"), role: .destructive) { model.edit { $0 = ConfigDocument() } }
            } message: {
                Text(ConfigLayout.tr("dialog.reset_terminal.message", default: "Tamio's General and Connection preferences are kept."))
            }
        #endif
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    /// macOS: a category column beside the selected category, with the live
    /// preview beside or above it.
    private var columns: some View {
        HStack(spacing: 0) {
            ConfigCategoryColumn(categories: categories, navigation: navigation, model: model, search: $search)
                .frame(width: 216)
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    content
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                    ConfigPreviewBeside(
                        categories: categories, navigation: navigation, model: model,
                        visible: showPreview && previewBeside && search.isEmpty
                    )
                }
                ConfigErrorBar(model: model)
            }
            .readWidth($detailWidth)
        }
        // Embedded in Tamio, the window material is drawn behind every page.
        .background {
            if !embedded { RXWindowBackground().ignoresSafeArea() }
        }
        .rxClearToolbar()
        .modifier(ConfigToolbar(active: active, leading: {
            ConfigHistoryButtons(navigation: navigation, chrome: navigation.chrome)
        }, trailing: {
            ConfigToolbarTools(
                chrome: navigation.chrome, model: model, history: model.history,
                searching: !search.isEmpty, showPreview: $showPreview, resetConfirm: $resetConfirm
            )
        }))
        .configSearch(text: $search, active: active)
        .onAppear {
            installApplyHandler()
            #if DEBUG
                if let text = ProcessInfo.processInfo.environment["TAMIO_PREVIEW_SEARCH"] { search = text }
                if ProcessInfo.processInfo.environment["TAMIO_PREVIEW_PREVIEW"] != nil { showPreview = true }
            #endif
            if !categories.contains(where: { $0.id == navigation.selection }) {
                navigation.go(categories.first?.id ?? "text")
            }
            pageState.previewAbove = showPreview && !previewBeside
        }
        .onChange(of: showPreview && !previewBeside) { pageState.previewAbove = $0 }
        // Settings stays in the window; a search left behind would cover the
        // category it is next opened at.
        .onChange(of: active) { if !$0 { search = "" } }
        .animation(.easeOut(duration: 0.18), value: search.isEmpty)
        .confirmationDialog(ConfigLayout.tr("dialog.reset_terminal.title", default: "Reset every terminal setting to its default?"), isPresented: $resetConfirm) {
            Button(ConfigLayout.tr("action.reset", default: "Reset"), role: .destructive) { model.edit { $0 = ConfigDocument() } }
        } message: {
            Text(ConfigLayout.tr("dialog.reset_terminal.message", default: "Tamio's General and Connection preferences are kept."))
        }
        .frame(minWidth: embedded ? 700 : 960, minHeight: 560)
    }
    #endif

    /// One category's groups as cards: the iOS page pushed from the category list.
    private func categoryPage(_ category: ConfigLayout.Category) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RX.Space.s6) {
                if category.previews {
                    DisclosureGroup("Preview") {
                        ConfigPreview(model: model)
                            .rxCard(padding: 0)
                            .padding(.top, RX.Space.s2)
                    }
                    .font(.rxBodyStrong)
                }
                if category.id == "keyboard" {
                    ConfigKeybindingList(model: model)
                } else {
                    ForEach(category.groups) { group in
                        ConfigGroupCard(group: group, hostSections: hostSections, model: model)
                    }
                }
            }
            .padding(RX.Space.s4)
        }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle(category.title)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        #if targetEnvironment(macCatalyst)
            ZStack {
                ConfigPageDeck(
                    categories: categories, navigation: navigation, hostSections: hostSections, model: model,
                    previewAbove: pageState.previewAbove, jump: pageState.jump, active: active
                )
                    .ignoresSafeArea(.container, edges: .vertical)
                    .opacity(search.isEmpty ? 1 : 0)
                    .allowsHitTesting(search.isEmpty)
                    .accessibilityHidden(!search.isEmpty)
                if !search.isEmpty {
                    searchContent
                }
            }
        #else
            if !search.isEmpty {
                searchContent
            } else {
                ConfigSelectedCategory(categories: categories, navigation: navigation, hostSections: hostSections, model: model, state: pageState)
            }
        #endif
    }

    // MARK: Search

    private var searchContent: some View {
        let settings = searchResults
        let hosts = hostSearchResults
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: RX.Space.s6) {
                PageTitle("Search Results", subtitle: searchSubtitle(settings.count + hosts.count))
                ForEach(categories) { category in
                    let groups = category.groups.compactMap { group -> (ConfigLayout.Group, [String])? in
                        let hostMatch = group.items.contains { item in
                            if case let .host(id) = item { return hosts.contains(id) }
                            return false
                        }
                        let keys = group.items.compactMap { item -> String? in
                            if case let .setting(key) = item, settings.contains(key) { return key }
                            return nil
                        }
                        return hostMatch || !keys.isEmpty ? (group, keys) : nil
                    }
                    if !groups.isEmpty {
                        VStack(alignment: .leading, spacing: RX.Space.s3) {
                            HStack {
                                Label(category.title, systemImage: category.icon)
                                    .font(.rxBodyStrong)
                                    .foregroundStyle(.rxInk)
                                Spacer()
                                Button(String(format: ConfigLayout.tr("search.show_in_category", default: "Show in %@"), category.title)) {
                                    pageState.jump = groups.first?.1.first.map { .init(category: category.id, key: $0) }
                                    navigation.go(category.id)
                                    search = ""
                                }
                                .rxLinkButton()
                                .font(.rxHelp)
                            }
                            ForEach(groups, id: \.0.id) { group, keys in
                                ConfigGroupCard(group: group, keys: keys, hostSections: hostSections, model: model, query: search)
                            }
                        }
                    }
                }
                if settings.isEmpty && hosts.isEmpty {
                    EmptyStateView(String(format: ConfigLayout.tr("search.no_match", default: "No settings match “%@”"), search), systemImage: "magnifyingglass")
                        .rxCard()
                }
            }
            .padding(.horizontal, RX.Space.s6)
            .padding(.top, RX.Space.s3)
            .padding(.bottom, RX.Space.s6)
        }
    }

    private func searchSubtitle(_ count: Int) -> String {
        if count == 0 {
            return ConfigLayout.tr("search.nothing_found", default: "Nothing found")
        } else if count == 1 {
            return String(format: ConfigLayout.tr("search.matches_single", default: "1 match for “%@”"), search)
        } else {
            return String(format: ConfigLayout.tr("search.matches_multiple", default: "%d matches for “%@”"), count, search)
        }
    }

    private var tokens: [Substring] { search.lowercased().split(whereSeparator: \.isWhitespace) }

    /// Host groups whose keywords, group or category title match.
    private var hostSearchResults: Set<String> {
        var result = Set<String>()
        for category in categories {
            for group in category.groups {
                for case let .host(id) in group.items {
                    guard let section = hostSections[id] else { continue }
                    let text = "\(category.englishTitle) \(category.title) \(group.englishTitle) \(group.title) \(section.keywords)".lowercased()
                    if tokens.allSatisfy({ text.contains($0) }) { result.insert(id) }
                }
            }
        }
        return result
    }

    /// Ghostty keys whose name, description, key, group or category match.
    private var searchResults: Set<String> {
        let tokens = tokens
        var result = Set<String>()
        for category in categories {
            for group in category.groups {
                for case let .setting(key) in group.items {
                    guard let setting = ConfigCatalog.shared.setting(key: key) else { continue }
                    let engTitle = ConfigLayout.englishTitle(setting)
                    let engSummary = ConfigLayout.englishSummary(setting)
                    let locTitle = ConfigLayout.title(setting)
                    let locSummary = ConfigLayout.summary(setting)
                    let haystack = [
                        setting.key, setting.name, setting.description,
                        engTitle, engSummary, locTitle, locSummary,
                        category.englishTitle, category.title,
                        group.englishTitle, group.title,
                    ].joined(separator: " ").lowercased()
                    if tokens.allSatisfy({ haystack.contains($0) }) { result.insert(key) }
                }
            }
        }
        return result
    }
}

#if !(os(macOS) || targetEnvironment(macCatalyst))
    /// iPhone and iPad: the categories as a grouped list, each pushing its page;
    /// searching replaces the list with matching settings.
    private struct CompactSettings<Page: View, Results: View>: View {
        let categories: [ConfigLayout.Category]
        let hostSections: [String: ConfigHostSettingsSection]
        @ObservedObject var model: ConfigEditorModel
        let categoryPage: (ConfigLayout.Category) -> Page
        let searchContent: () -> Results
        @Binding var search: String
        @Binding var resetConfirm: Bool

        private func modifiedCount(_ category: ConfigLayout.Category) -> Int {
            model.document.overrides.keys.filter { ConfigLayout.categoryOfKey[$0]?.id == category.id }.count
        }

        var body: some View {
            Group {
                if search.isEmpty {
                    List {
                        ForEach([ConfigLayout.Category.Section.app, .terminal, .info], id: \.self) { section in
                            let members = categories.filter { $0.section == section }
                            if !members.isEmpty {
                                Section(section.localizedTitle) {
                                    ForEach(members) { category in
                                        NavigationLink {
                                            categoryPage(category)
                                        } label: {
                                            HStack {
                                                Label(category.title, systemImage: category.icon)
                                                Spacer()
                                                let count = modifiedCount(category)
                                                if count > 0 {
                                                    Text(String(format: ConfigLayout.tr("category.changed_count", default: "%d changed"), count))
                                                        .font(.rxHelp)
                                                        .foregroundStyle(.rxInkSecondary)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    searchContent()
                }
            }
            .searchable(text: $search, prompt: Text(ConfigLayout.tr("search.prompt", default: "Search settings")))
            .navigationTitle(ConfigLayout.tr("navigation.settings", default: "Settings"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { model.undo() } label: { Label(ConfigLayout.tr("action.undo", default: "Undo"), systemImage: "arrow.uturn.backward") }
                            .disabled(model.undoStack.isEmpty)
                        Button { model.redo() } label: { Label(ConfigLayout.tr("action.redo", default: "Redo"), systemImage: "arrow.uturn.forward") }
                            .disabled(model.redoStack.isEmpty)
                        Divider()
                        Button(role: .destructive) { resetConfirm = true } label: {
                            Label(ConfigLayout.tr("action.reset_terminal_settings", default: "Reset Terminal Settings…"), systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Label(ConfigLayout.tr("action.more", default: "More"), systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }
#endif

#if os(macOS)
private extension View {
    /// Search in the window toolbar, only while Settings is the page on
    /// screen: Settings stays mounted out of sight, and a second search
    /// field in the toolbar, the next page's, is an AppKit exception.
    @ViewBuilder
    func configSearch(text: Binding<String>, active: Bool) -> some View {
        if active {
            searchable(text: text, placement: .toolbar, prompt: Text(ConfigLayout.tr("search.prompt", default: "Search settings")))
        } else {
            self
        }
    }
}

/// Navigation at the leading edge, actions at the trailing edge of the window toolbar.
private struct ConfigToolbar<Leading: View, Trailing: View>: ViewModifier {
    let active: Bool
    let leading: Leading
    let trailing: Trailing

    init(active: Bool, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.active = active
        self.leading = leading()
        self.trailing = trailing()
    }

    // The condition sits inside the toolbar: outside it, Settings would be
    // built again each time it came into sight. Out of sight, it adds nothing
    // to the window toolbar.
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbar {
                if active {
                    ToolbarItemGroup(placement: .navigation) { leading }
                    ToolbarSpacer(.flexible)
                    ToolbarItemGroup(placement: .automatic) { trailing }
                }
            }
        } else {
            content.toolbar {
                if active {
                    ToolbarItemGroup(placement: .navigation) { leading }
                    ToolbarItemGroup(placement: .automatic) { trailing }
                }
            }
        }
    }
}
#endif
