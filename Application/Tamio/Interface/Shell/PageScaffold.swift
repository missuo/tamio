//
//  PageScaffold.swift
//  Tamio (macOS)
//
//  The content column over the translucent window: the page title, then the page body.
//  Page controls live in the native window toolbar, which carries Liquid Glass on
//  macOS 26: navigation on the left, actions on the right with the primary one last,
//  and search as a toolbar search field.
//

import TamioDesign
import TamioModule
import SwiftUI

struct PageScaffold<Leading: View, Trailing: View, Header: View, Content: View>: View {
    let scrolls: Bool
    let search: Binding<String>?
    let searchPrompt: LocalizedStringKey
    let primary: ToolbarAction?
    let trailingMetrics: ToolbarCapsuleMetrics
    let leading: Leading
    let trailing: Trailing
    let header: Header
    let content: Content

    init(
        scrolls: Bool = true,
        search: Binding<String>? = nil,
        searchPrompt: LocalizedStringKey = "Search",
        primary: ToolbarAction? = nil,
        trailingMetrics: ToolbarCapsuleMetrics = .group,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.scrolls = scrolls
        self.search = search
        self.searchPrompt = searchPrompt
        self.primary = primary
        self.trailingMetrics = trailingMetrics
        self.leading = leading()
        self.trailing = trailing()
        self.header = header()
        self.content = content()
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        content
                            .padding(.top, RX.Space.s6)
                    }
                    .padding(.horizontal, RX.Space.s6)
                    .padding(.top, RX.Space.s3)
                    .padding(.bottom, RX.Space.s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content
                        .padding(.top, RX.Space.s6)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, RX.Space.s6)
                .padding(.top, RX.Space.s3)
                .padding(.bottom, RX.Space.s6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .pageChrome()
        .pageToolbar(primary: primary, trailingMetrics: trailingMetrics, search: search.map { ($0, searchPrompt) }) { leading } trailing: { trailing }
    }
}

extension PageScaffold where Header == EmptyView {
    init(
        scrolls: Bool = true,
        search: Binding<String>? = nil,
        searchPrompt: LocalizedStringKey = "Search",
        primary: ToolbarAction? = nil,
        trailingMetrics: ToolbarCapsuleMetrics = .group,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(scrolls: scrolls, search: search, searchPrompt: searchPrompt, primary: primary, trailingMetrics: trailingMetrics, leading: leading, trailing: trailing, header: { EmptyView() }, content: content)
    }
}

extension View {
    /// Lets the toolbar float over the window material. The material itself is
    /// drawn once, behind every page, by MainView: a page that drew its own would
    /// fade with the page during a transition and flash the plain window colour.
    func pageChrome() -> some View {
        rxClearToolbar()
    }
}

/// Whether a page is the one on screen. Open session pages stay mounted so
/// switching between them is instant; the hidden ones must not add toolbar items,
/// search fields or keyboard shortcuts.
private struct ActivePageKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isActivePage: Bool {
        get { self[ActivePageKey.self] }
        set { self[ActivePageKey.self] = newValue }
    }
}

extension View {
    /// Navigation controls at the leading edge, actions at the trailing edge, and
    /// the page's one primary action after them, apart.
    func pageToolbar<Leading: View, Trailing: View>(
        primary: ToolbarAction? = nil,
        trailingMetrics: ToolbarCapsuleMetrics = .group,
        search: (text: Binding<String>, prompt: LocalizedStringKey)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(PageToolbar(leading: leading(), trailing: trailing(), primary: primary, trailingMetrics: trailingMetrics, search: search))
    }
}

private struct PageToolbar<Leading: View, Trailing: View>: ViewModifier {
    let leading: Leading
    let trailing: Trailing
    let primary: ToolbarAction?
    let trailingMetrics: ToolbarCapsuleMetrics
    /// Search at the trailing end of the toolbar.
    let search: (text: Binding<String>, prompt: LocalizedStringKey)?
    @Environment(\.isActivePage) private var isActive
    @Environment(\.serverToolSwitch) private var toolSwitch

    private var hasLeading: Bool { Leading.self != EmptyView.self }
    private var hasTrailing: Bool { Trailing.self != EmptyView.self || primary != nil }

    // The condition sits inside the toolbar builder: switching the page's own
    // identity would rebuild it (and its terminal view) on every switch.
    func body(content: Content) -> some View {
        content
            .toolbar {
                if isActive {
                    if hasLeading {
                        ToolbarItemGroup(placement: .navigation) { leading }
                    }
                    // Without a title the toolbar lays its items out from the
                    // leading edge; the spacer keeps the actions at the trailing
                    // one, with the switcher in the middle.
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible)
                    }
                    if let toolSwitch {
                        ToolbarItem(placement: .principal) {
                            ServerToolSwitcher(machine: toolSwitch.machine, current: toolSwitch.current)
                        }
                        if #available(macOS 26.0, *) {
                            ToolbarSpacer(.flexible)
                        }
                    }
                    if hasTrailing {
                        ToolbarItemGroup(placement: .primaryAction) {
                            trailing
                            if let primary { primary }
                        }
                    }
                }
            }
            .modifier(OptionalSearch(text: isActive ? search?.text : nil, prompt: search?.prompt ?? "Search"))
    }
}

/// How AppKit spaces the symbols of a toolbar group.
struct ToolbarCapsuleMetrics {
    var spacing: CGFloat = 0
    var minSlot: CGFloat = 35
    /// From the trailing edge of the window, past the toolbar's own margin.
    var inset: CGFloat = 4
    /// Buttons in a `ToolbarItemGroup`.
    static let group = ToolbarCapsuleMetrics()
    /// A lone button: no minimum width.
    static let single = ToolbarCapsuleMetrics(minSlot: 0)
    /// A `ControlGroup`.
    static let controlGroup = ToolbarCapsuleMetrics(spacing: 9, minSlot: 34.5, inset: 0)
}

/// Toolbar search for pages that are never kept hidden (session pages search
/// inside the page instead: a hidden page's search field would stay in the toolbar).
private struct OptionalSearch: ViewModifier {
    let text: Binding<String>?
    let prompt: LocalizedStringKey

    func body(content: Content) -> some View {
        if let text {
            content.searchable(text: text, placement: .toolbar, prompt: Text(prompt))
        } else {
            content
        }
    }
}

/// A toolbar action: a symbol, with its title as the tooltip and accessibility
/// label (HIG: prefer simple, recognizable symbols in toolbars). A page passes
/// its primary action to the scaffold, which draws it tinted and apart.
struct ToolbarAction: View {
    let title: LocalizedStringKey
    let systemImage: String
    var primary = false
    var isEnabled = true
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, primary: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.primary = primary
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        if primary {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .rxPrimaryAction()
            .disabled(!isEnabled)
            .help(Text(title))
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .disabled(!isEnabled)
            .help(Text(title))
        }
    }
}
