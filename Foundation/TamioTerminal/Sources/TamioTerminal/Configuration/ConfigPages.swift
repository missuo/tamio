import Combine
import TamioDesign
import SwiftUI

/// Which category Settings shows, and the ones it showed before. The app can
/// hold one to open Settings at a category. Used on the main thread only.
public final class ConfigNavigation: ObservableObject, @unchecked Sendable {
    @Published public private(set) var selection: String
    private var history: [String]
    private var index = 0
    /// What the window toolbar shows of this.
    let chrome = Chrome()
    private var pendingChrome = Chrome.State()

    /// The toolbar's share of the selection. It changes far less often than
    /// the selection does, and a toolbar item that is told of a change is
    /// handed to AppKit again whether or not it looks different.
    final class Chrome: ObservableObject {
        struct State: Equatable {
            var canGoBack = false
            var canGoForward = false
            var terminal = false
            var previews = false
        }

        @Published fileprivate(set) var state = State()
    }

    public init(_ selection: String = "general") {
        self.selection = selection
        history = [selection]
        updateChrome(now: true)
    }

    public func go(_ id: String) {
        guard id != selection else { return }
        history = Array(history.prefix(index + 1)) + [id]
        index = history.count - 1
        selection = id
        updateChrome()
    }

    func step(_ delta: Int) {
        let next = index + delta
        guard history.indices.contains(next) else { return }
        index = next
        selection = history[next]
        updateChrome()
    }

    /// The toolbar follows a moment after the page: handing its items to
    /// AppKit again costs more than showing the page, and need not delay it.
    private func updateChrome(now: Bool = false) {
        let category = ConfigLayout.categories.first { $0.id == selection }
        let state = Chrome.State(
            canGoBack: index > 0,
            canGoForward: index + 1 < history.count,
            terminal: category?.section == .terminal,
            previews: category?.previews == true
        )
        pendingChrome = state
        if now {
            chrome.state = state
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, pendingChrome == state, chrome.state != state else { return }
                chrome.state = state
            }
        }
    }
}

/// What the pages of Settings share with the view that holds them.
@MainActor
final class ConfigPageState: ObservableObject {
    struct Jump: Equatable {
        let category: String
        let key: String
        /// Asking for the same setting again is a new request.
        let id = UUID()
    }

    /// The live preview goes above the settings when there is no room beside them.
    @Published var previewAbove = false
    /// A setting to scroll to, in the category it belongs to.
    @Published var jump: Jump?
}

/// A group: its caption, then its rows on one card.
struct ConfigGroupCard: View {
    let group: ConfigLayout.Group
    var keys: [String]?
    let hostSections: [String: ConfigHostSettingsSection]
    let model: ConfigEditorModel
    var query = ""

    var body: some View {
        let hosts = group.items.compactMap { item -> ConfigHostSettingsSection? in
            if case let .host(id) = item { return hostSections[id] }
            return nil
        }
        let settings = (keys ?? group.items.compactMap { item -> String? in
            if case let .setting(key) = item { return key }
            return nil
        }).compactMap { ConfigCatalog.shared.setting(key: $0) }
        if !hosts.isEmpty || !settings.isEmpty {
            VStack(alignment: .leading, spacing: RX.Space.s2) {
                CapsLabel(group.title)
                    .padding(.leading, RX.Space.s4)
                VStack(spacing: 0) {
                    ForEach(hosts) { $0.content }
                    if !settings.isEmpty {
                        RXDividedStack {
                            ForEach(settings) { setting in
                                ConfigSettingRow(model: model, setting: setting, query: query).id(setting.key)
                            }
                        }
                    }
                }
                .padding(.horizontal, RX.Space.s4)
                .background(Color.clear.rxCard(padding: 0))
            }
        }
    }
}

/// One category: its title, then its groups as cards, scrolling.
struct ConfigCategoryContent: View {
    let category: ConfigLayout.Category
    let hostSections: [String: ConfigHostSettingsSection]
    let model: ConfigEditorModel
    @ObservedObject var state: ConfigPageState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RX.Space.s6) {
                    HStack(alignment: .center, spacing: RX.Space.s2) {
                        PageTitle(category.title)
                        Spacer(minLength: RX.Space.s2)
                        if category.section == .terminal {
                            ConfigPageActions(model: model)
                        }
                    }
                    if state.previewAbove, category.previews {
                        ConfigPreview(model: model)
                            .rxCard(padding: 0)
                            .transition(.opacity)
                    }
                    if category.id == "keyboard" {
                        ConfigKeybindingList(model: model)
                    } else {
                        ForEach(category.groups) { group in
                            ConfigGroupCard(group: group, hostSections: hostSections, model: model)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RX.Space.s6)
                .padding(.top, RX.Space.s3)
                .padding(.bottom, RX.Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: state.jump) {
                guard let jump = state.jump, jump.category == category.id else { return }
                await Task.yield()
                proxy.scrollTo(jump.key, anchor: .top)
            }
        }
    }
}

/// Undo, redo, and Reset in a menu, beside a terminal category's title: they
/// act on the terminal's settings, so they are on its pages, not in the
/// window toolbar. Plain symbols, no capsules.
struct ConfigPageActions: View {
    let model: ConfigEditorModel
    @ObservedObject private var history: ConfigEditorModel.History
    @State private var resetConfirm = false

    init(model: ConfigEditorModel) {
        self.model = model
        history = model.history
    }

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            Button { model.undo() } label: {
                Label(ConfigLayout.tr("action.undo", default: "Undo"), rx: "arrow.uturn.backward")
            }
            .disabled(!history.canUndo)
            .help(ConfigLayout.tr("help.undo_change", default: "Undo the last terminal setting change"))
            Button { model.redo() } label: {
                Label(ConfigLayout.tr("action.redo", default: "Redo"), rx: "arrow.uturn.forward")
            }
            .disabled(!history.canRedo)
            .help(ConfigLayout.tr("help.redo_change", default: "Redo"))
            Menu {
                Button(role: .destructive) { resetConfirm = true } label: {
                    Text(ConfigLayout.tr("action.reset_terminal_settings", default: "Reset Terminal Settings…"))
                }
            } label: {
                Label(ConfigLayout.tr("action.more", default: "More"), rx: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 15))
        .foregroundStyle(.rxInkSecondary)
        .confirmationDialog(ConfigLayout.tr("dialog.reset_terminal.title", default: "Reset every terminal setting to its default?"), isPresented: $resetConfirm) {
            Button(ConfigLayout.tr("action.reset", default: "Reset"), role: .destructive) { model.edit { $0 = ConfigDocument() } }
        } message: {
            Text(ConfigLayout.tr("dialog.reset_terminal.message", default: "Tamio's General and Connection preferences are kept."))
        }
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)
    /// The categories, in their sections; the selected one is marked.
    struct ConfigCategoryColumn: View {
        let categories: [ConfigLayout.Category]
        @ObservedObject var navigation: ConfigNavigation
        @ObservedObject var model: ConfigEditorModel
        @Binding var search: String

        var body: some View {
            let counts = model.document.overrides.keys.reduce(into: [String: Int]()) { counts, key in
                if let id = ConfigLayout.categoryOfKey[key]?.id { counts[id, default: 0] += 1 }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([ConfigLayout.Category.Section.app, .terminal, .info], id: \.self) { section in
                        let members = categories.filter { $0.section == section }
                        if !members.isEmpty {
                            if section.rawValue.isEmpty {
                                Spacer().frame(height: RX.Space.s4)
                            } else {
                                Text(section.localizedTitle)
                                    .font(.rxSectionLabel)
                                    .foregroundStyle(.rxInkSecondary)
                                    .padding(.horizontal, RX.Space.s3)
                                    .padding(.top, RX.Space.s4)
                                    .padding(.bottom, RX.Space.s1)
                            }
                            ForEach(members) { category in
                                ConfigCategoryRow(
                                    category: category,
                                    selected: navigation.selection == category.id && search.isEmpty,
                                    count: counts[category.id] ?? 0
                                ) {
                                    search = ""
                                    navigation.go(category.id)
                                }
                                .equatable()
                            }
                        }
                    }
                }
                .padding(.horizontal, RX.Space.s2)
                .padding(.top, RX.Space.s3)
                .padding(.bottom, RX.Space.s4)
            }
        }
    }

    /// A category in the column. Equal rows are left alone, so another
    /// selection draws two of them.
    struct ConfigCategoryRow: View, Equatable {
        let category: ConfigLayout.Category
        let selected: Bool
        /// Settings of the category changed from their defaults.
        let count: Int
        let select: () -> Void

        nonisolated static func == (a: Self, b: Self) -> Bool {
            a.category.id == b.category.id && a.selected == b.selected && a.count == b.count
        }

        var body: some View {
            Button(action: select) {
                HStack(spacing: RX.Space.s2) {
                    Image(rx: category.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Color.rxAccent : Color.rxInkSecondary)
                        .frame(width: 18)
                    Text(category.title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.rxAccent)
                            .help("\(count) changed from the default")
                    }
                }
                .padding(.horizontal, RX.Space.s3)
                .frame(height: 30)
                .background(
                    // Only the mark fades; text that changes weight over
                    // several frames is drawn again on each of them.
                    Capsule()
                        .fill(selected ? Color.primary.opacity(0.09) : .clear)
                        .animation(.easeOut(duration: 0.18), value: selected)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The live preview beside the settings, for the categories it illustrates.
    struct ConfigPreviewBeside: View {
        let categories: [ConfigLayout.Category]
        @ObservedObject var navigation: ConfigNavigation
        let model: ConfigEditorModel
        let visible: Bool

        var body: some View {
            if visible, categories.first(where: { $0.id == navigation.selection })?.previews == true {
                ScrollView {
                    ConfigPreview(model: model)
                        .rxCard(padding: 0)
                        .padding(.bottom, RX.Space.s6)
                }
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
                .padding(.trailing, RX.Space.s6)
                .padding(.top, RX.Space.s3)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    /// Settings save automatically; only a failed save needs a word.
    struct ConfigErrorBar: View {
        @ObservedObject var model: ConfigEditorModel

        var body: some View {
            if !model.message.isEmpty {
                HStack(spacing: RX.Space.s2) {
                    Image(rx: "exclamationmark.triangle")
                        .foregroundStyle(.rxWarning)
                    Text(model.message)
                        .font(.rxBody)
                        .foregroundStyle(.rxInk)
                        .textSelection(.enabled)
                    Spacer()
                    Button { model.message = "" } label: { Image(rx: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(ConfigLayout.tr("action.dismiss", default: "Dismiss"))
                }
                .padding(.horizontal, RX.Space.s4)
                .padding(.vertical, RX.Space.s3)
                .background(Color.clear.rxCard(padding: 0))
                .padding(.horizontal, RX.Space.s6)
                .padding(.bottom, RX.Space.s4)
            }
        }
    }

#endif

#if !targetEnvironment(macCatalyst)
    /// The selected category's page, built when it is selected.
    struct ConfigSelectedCategory: View {
        let categories: [ConfigLayout.Category]
        @ObservedObject var navigation: ConfigNavigation
        let hostSections: [String: ConfigHostSettingsSection]
        let model: ConfigEditorModel
        let state: ConfigPageState

        var body: some View {
            if let category = categories.first(where: { $0.id == navigation.selection }) {
                ConfigCategoryContent(category: category, hostSections: hostSections, model: model, state: state)
                    .id(category.id)
            } else {
                EmptyStateView("Choose a category", systemImage: "slider.horizontal.3")
                    .frame(maxHeight: .infinity)
            }
        }
    }
#endif

#if targetEnvironment(macCatalyst)
    import UIKit

    /// The categories' pages, each built once and kept: going to a category
    /// shows its page instead of building it again, and the pages not yet
    /// visited are built one at a time while Settings sits idle.
    struct ConfigPageDeck: UIViewControllerRepresentable {
        let categories: [ConfigLayout.Category]
        let navigation: ConfigNavigation
        let hostSections: [String: ConfigHostSettingsSection]
        let model: ConfigEditorModel
        let previewAbove: Bool
        let jump: ConfigPageState.Jump?
        /// Whether Settings is the page in the window.
        let active: Bool

        func makeUIViewController(context _: Context) -> Deck { Deck() }

        func updateUIViewController(_ deck: Deck, context: Context) {
            let hostSections = hostSections, model = model, state = deck.state
            if state.previewAbove != previewAbove { state.previewAbove = previewAbove }
            if state.jump != jump { state.jump = jump }
            deck.categories = categories
            deck.make = { category in
                AnyView(ConfigCategoryContent(category: category, hostSections: hostSections, model: model, state: state))
            }
            deck.animated = !context.environment.accessibilityReduceMotion
            deck.follow(navigation)
            if deck.active != active { deck.active = active }
        }

        final class Deck: UIViewController {
            var categories: [ConfigLayout.Category] = []
            var make: ((ConfigLayout.Category) -> AnyView)?
            private var pages: [String: UIHostingController<AnyView>] = [:]
            private var shown: String?
            private var warming: DispatchWorkItem?
            /// What the pages share; they are made once, with this.
            let state = ConfigPageState()
            var animated = true
            /// Out of sight, Settings keeps no field being typed in and
            /// builds no more pages.
            var active = true {
                didSet {
                    guard active != oldValue else { return }
                    if active {
                        warm(after: 0.5)
                    } else {
                        warming?.cancel()
                        view.endEditing(true)
                    }
                }
            }
            private weak var navigation: ConfigNavigation?
            private var following: AnyCancellable?

            /// The page changes as the selection does, without waiting for
            /// SwiftUI to come round to it.
            func follow(_ navigation: ConfigNavigation) {
                guard navigation !== self.navigation else { return }
                self.navigation = navigation
                following = navigation.$selection.sink { [weak self] id in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.show(id, animated: self.animated)
                    }
                }
            }

            override func viewDidLoad() {
                super.viewDidLoad()
                view.backgroundColor = .clear
            }

            func show(_ id: String, animated: Bool) {
                guard id != shown, let page = page(id) else { return }
                let previous = shown.flatMap { pages[$0] }
                shown = id
                // Its size is settled with the deck's, which may be about to change.
                view.setNeedsLayout()
                // A field left with the caret in it would go on taking keys.
                previous?.view.endEditing(true)
                previous.map { set($0, visible: false) }
                set(page, visible: true)
                if animated, previous != nil {
                    page.view.alpha = 0
                    UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                        page.view.alpha = 1
                    }
                }
                warm(after: 0.5)
            }

            /// A page out of sight is transparent, not hidden: a hidden hosting
            /// view draws itself again from nothing when it comes back. It keeps
            /// the light or dark it had, too: every page drawing itself again
            /// at a change of appearance held the app up for a second. Shown,
            /// it follows the window again, and catches up alone.
            private func set(_ page: UIHostingController<AnyView>, visible: Bool) {
                page.overrideUserInterfaceStyle = visible ? .unspecified : view.traitCollection.userInterfaceStyle
                page.view.layer.removeAllAnimations()
                page.view.alpha = visible ? 1 : 0
                page.view.isUserInteractionEnabled = visible
                page.view.accessibilityElementsHidden = !visible
            }

            private func page(_ id: String) -> UIHostingController<AnyView>? {
                if let page = pages[id] { return page }
                guard let category = categories.first(where: { $0.id == id }), let make else { return nil }
                let page = UIHostingController(rootView: make(category))
                page.view.backgroundColor = .clear
                set(page, visible: false)
                addChild(page)
                page.view.frame = view.bounds
                view.addSubview(page.view)
                page.didMove(toParent: self)
                pages[id] = page
                return page
            }

            override func viewDidLayoutSubviews() {
                super.viewDidLayoutSubviews()
                // Only the page on screen follows the window; the others take
                // its size when they are shown.
                if let shown, let page = pages[shown], page.view.frame != view.bounds {
                    page.view.frame = view.bounds
                }
            }

            /// Builds the pages not yet visited, one at a time, while the
            /// selection rests: each takes about as long as a visit used to.
            private func warm(after delay: TimeInterval) {
                warming?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, active, view.window != nil,
                          let next = categories.first(where: { self.pages[$0.id] == nil })
                    else { return }
                    page(next.id)?.view.layoutIfNeeded()
                    warm(after: 0.15)
                }
                warming = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }
#endif
