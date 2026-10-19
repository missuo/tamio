//
//  SettingsView.swift
//  Tamio (macOS)
//
//  Settings is a sidebar destination. Its categories and their order come from
//  TamioTerminal's ConfigLayout; this file supplies the rows for Tamio's own
//  preferences (General, Connection, About).
//

import TamioModule
import TamioTerminal
import MachineStatusView
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject var router = AppRouter.shared
    /// False while Settings is kept out of sight.
    var active = true

    var body: some View {
        GhosttyConfigurationView(
            embedded: true,
            // Each category's page is hosted on its own, so the rows carry the
            // store with them.
            hostSections: [
                ConfigHostSettingsSection(id: "general.appearance", keywords: "appearance dark light mode theme system") {
                    AppearanceSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "general.sessions", keywords: "open sessions automatically ask before closing confirmation quit") {
                    SessionSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "general.files", keywords: "files sftp hidden dot files show") {
                    FilesSettings()
                },
                ConfigHostSettingsSection(id: "general.sync", keywords: "icloud sync cloud encrypted passphrase servers identities credentials devices") {
                    CloudSyncSettings()
                },
                ConfigHostSettingsSection(id: "connection.ssh", keywords: "ssh timeout connect wait host key known hosts fingerprint") {
                    SSHSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "connection.monitor", keywords: "monitor refresh interval status") {
                    MonitorSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "mcp.server", keywords: "mcp agent ai claude codex server model context protocol") {
                    AgentServerSettings()
                },
                ConfigHostSettingsSection(id: "mcp.setup", keywords: "mcp agent skill install prompt claude codex command") {
                    AgentSetupSettings()
                },
                ConfigHostSettingsSection(id: "mcp.activity", keywords: "mcp agent activity log history") {
                    AgentActivitySettings()
                },
                ConfigHostSettingsSection(id: "about.tamio", keywords: "version build license source github agreement") {
                    AboutSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "about.updates", keywords: "update updates sparkle new version check automatically download") {
                    UpdateSettings()
                },
                ConfigHostSettingsSection(id: "about.acknowledgements", keywords: "acknowledgements credits libraries ghostty") {
                    AcknowledgementSettings().environmentObject(store)
                },
            ],
            navigation: router.settingsNavigation,
            active: active,
            onApplied: { size in
                // One font size: the terminal's Font Size setting also sets the
                // size ⌘+ and ⌘− start from.
                if let size { store.terminalFontSize = Int(size.rounded()) }
            }
        )
    }
}

/// Appearance follows the system unless the user picks Light or Dark.
enum AppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    static let key = "sb.moe.tamio.appearance"

    @MainActor
    func apply(crossFade: Bool = false) {
        // Every window draws itself again in the new appearance, which takes
        // a moment; meanwhile each shows a picture of what it was, which then
        // fades into the new one, so nothing is seen half done.
        var covers: [NSView] = []
        if crossFade {
            for window in Mac.ordinaryWindows where window.isVisible {
                guard let content = window.contentView,
                      let picture = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                else { continue }
                content.cacheDisplay(in: content.bounds, to: picture)
                let image = NSImage(size: content.bounds.size)
                image.addRepresentation(picture)
                let cover = NSImageView(frame: content.bounds)
                cover.image = image
                cover.imageScaling = .scaleAxesIndependently
                cover.autoresizingMask = [.width, .height]
                content.addSubview(cover, positioned: .above, relativeTo: nil)
                covers.append(cover)
            }
        }
        Mac.setAppearance(self == .system ? nil : rawValue)
        guard !covers.isEmpty else { return }
        // On the next turn, once the windows have drawn themselves again.
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                covers.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: {
                covers.forEach { $0.removeFromSuperview() }
            }
        }
    }

    @MainActor
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: key) ?? AppearancePreference.system.rawValue
        (AppearancePreference(rawValue: raw) ?? .system).apply()
    }
}

private struct AppearanceSettings: View {
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system.rawValue

    var body: some View {
        RXFormRow("Light or dark", description: "Terminal colors are set under Colors.") {
            RXSegmented(selection: $appearance, options: [
                .init(AppearancePreference.system.rawValue, "System"),
                .init(AppearancePreference.light.rawValue, "Light"),
                .init(AppearancePreference.dark.rawValue, "Dark"),
            ], caps: false)
        }
        .onChange(of: appearance) { raw in
            // Once the selection has slid over: the whole app draws itself
            // again in the new appearance, which would stop it halfway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                guard raw == appearance else { return }
                (AppearancePreference(rawValue: raw) ?? .system).apply(crossFade: true)
            }
        }
    }
}

private struct SessionSettings: View {
    @EnvironmentObject var store: TamioStore

    var body: some View {
        RXDividedStack {
            SwitchRow(
                "Show a session when it connects",
                description: "Switch to a terminal as soon as it opens.",
                isOn: $store.openInterfaceAutomatically
            )
            SwitchRow(
                "Ask before closing a session",
                description: "Confirm before closing a connected terminal or quitting.",
                isOn: Binding(get: { !store.disableConformation }, set: { store.disableConformation = !$0 })
            )
        }
    }
}

private struct FilesSettings: View {
    @AppStorage(FilesPreference.showsHiddenKey) private var showsHidden = false

    var body: some View {
        RXDividedStack {
            SwitchRow(
                "Show hidden files",
                description: "Files whose names start with a dot, on this Mac and on servers. Each pane's Actions menu turns them on and off too.",
                isOn: $showsHidden
            )
        }
    }
}

private struct SSHSettings: View {
    @EnvironmentObject var store: TamioStore

    var body: some View {
        RXDividedStack {
            NumberFieldRow(
                "Connection timeout",
                description: "How long to wait for a server before giving up.",
                value: $store.timeout,
                in: 2 ... 30,
                unit: "s"
            )
            HostKeysRow()
        }
    }
}

/// How many host keys are saved, and a way to start over.
private struct HostKeysRow: View {
    @State private var count = KnownHosts.shared.count

    var body: some View {
        RXFormRow(
            "Saved host keys",
            description: "A server's key is saved the first time you connect; a server that later presents another key is refused. \(count) saved."
        ) {
            Button("Forget All…") {
                Dialogs.requiresConfirmation(
                    message: String(localized: "Forget all saved host keys?"),
                    informative: String(localized: "The key each server presents on its next connection is saved as its key."),
                    confirmTitle: String(localized: "Forget All")
                ) { confirmed in
                    guard confirmed else { return }
                    KnownHosts.shared.forgetAll()
                    count = KnownHosts.shared.count
                }
            }
            .buttonStyle(.rx)
            .disabled(count == 0)
        }
        .onAppear { count = KnownHosts.shared.count }
    }
}

/// Live status on the server cards and the Servers table.
private struct MonitorSettings: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject private var live = LiveStatusCenter.shared
    private let intervals = [3, 5, 10, 15, 30, 60]

    var body: some View {
        RXDividedStack {
            SwitchRow(
                "Live server status",
                description: "Every server with a password or key shows its load, CPU, memory, disk and traffic, over a connection of its own.",
                isOn: $live.isEnabled
            )
            RXFormRow("Refresh", description: "How often servers and open monitors are read.") {
                Picker("Refresh", selection: Binding(get: { max(3, store.monitorInterval) }, set: { store.monitorInterval = $0 })) {
                    ForEach(intervals, id: \.self) { seconds in
                        Text("Every \(seconds) s").tag(seconds)
                    }
                    if !intervals.contains(max(3, store.monitorInterval)) {
                        Text("Every \(store.monitorInterval) s").tag(store.monitorInterval)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

private struct AboutSettings: View {
    @State private var document: AboutDocument?

    var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        // The build number is the version itself unless a build sets its own.
        let version = build == short || build.isEmpty ? short : "\(short) (\(build))"
        #if DEBUG
            return "\(version) · Debug"
        #else
            return version
        #endif
    }

    var body: some View {
        RXDividedStack {
            RXFormRow("Version") {
                Text(version)
                    .font(.rxBody.monospacedDigit())
                    .foregroundStyle(.rxInkSecondary)
                    .textSelection(.enabled)
            }
            RXFormRow("What's new", description: "This version's release notes. New versions show theirs before they install.") {
                Link(destination: UpdateCenter.releaseNotesURL) {
                    Label("Release Notes", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.rx)
            }
            RXFormRow("Source code", description: "missuo/tamio on GitHub") {
                Link(destination: URL(string: "https://github.com/missuo/tamio")!) {
                    Label { Text("GitHub") } icon: { Image("github") }
                }
                .buttonStyle(.rx)
            }
            RXFormRow("Report a problem", description: "Bugs and ideas go to the project's issue tracker.") {
                Link(destination: URL(string: "https://github.com/missuo/tamio/issues")!) {
                    Label("Issues", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.rx)
            }
            RXFormRow("Legal") {
                HStack(spacing: RX.Space.s2) {
                    Button("License…") { document = .license }
                        .buttonStyle(.rx)
                    Button("Agreement…") { document = .agreement }
                        .buttonStyle(.rx)
                        .help("End user license agreement")
                }
            }
        }
        .sheet(item: $document) { item in
            LicenseSheet(document: item) { document = nil }
        }
    }
}

/// Sparkle's switches, read from and written to the updater itself.
private struct UpdateSettings: View {
    @ObservedObject private var center = UpdateCenter.shared
    @State private var checks = Mac.automaticallyChecksForUpdates ?? false
    @State private var downloads = Mac.automaticallyDownloadsUpdates ?? false
    @State private var lastCheck = Mac.lastUpdateCheck

    var body: some View {
        RXDividedStack {
            if center.isSupported {
                SwitchRow("Check for updates automatically", description: "Once a day. A new version shows at the bottom of the sidebar.", isOn: Binding(
                    get: { checks },
                    set: { checks = $0; Mac.automaticallyChecksForUpdates = $0 }
                ))
                SwitchRow("Download updates automatically", description: "Ready to install when you quit Tamio.", isOn: Binding(
                    get: { downloads },
                    set: { downloads = $0; Mac.automaticallyDownloadsUpdates = $0 }
                ))
                .disabled(!checks)
                RXFormRow("Check now", description: lastCheck.map { String(localized: "Last checked \(RXFormat.relative($0)).") } ?? String(localized: "Not checked yet.")) {
                    Button("Check for Updates…") {
                        center.checkNow()
                        lastCheck = Date()
                    }
                    .buttonStyle(.rx)
                }
            } else {
                RXFormRow("Updates", description: "This copy of Tamio does not update itself; the release from GitHub does.") {
                    EmptyView()
                }
            }
        }
    }
}

private struct AcknowledgementSettings: View {
    var body: some View {
        RXDividedStack {
            RXFormRow("Maintained by", description: "MOE AI LLC") {
                EmptyView()
            }
            RXFormRow("Based on", description: "mizorewww/catussh · Lakr233/Rayon") {
                EmptyView()
            }
            RXFormRow("Originally created by", description: "Lakr Aream (@Lakr233) with @__oquery, @zlind0, @unixzii, @82flex and @xnth97. This version is not affiliated with or endorsed by them.") {
                EmptyView()
            }
            RXFormRow("Terminal", description: "Ghostty, its configuration catalog and app icon presets (MIT, Ghostty contributors).") {
                EmptyView()
            }
            RXFormRow("Libraries", description: "libssh2 · NSRemoteShell · XMLCoder · SymbolPicker · Keychain") {
                EmptyView()
            }
        }
    }
}

enum AboutDocument: String, Identifiable {
    case license = "LICENSE"
    case agreement = "EULA"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .license: return String(localized: "License")
        case .agreement: return String(localized: "End User License Agreement")
        }
    }

    var text: String {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: nil),
              let string = try? String(contentsOf: url, encoding: .utf8)
        else { return String(localized: "The text could not be loaded.") }
        return string
    }
}

struct LicenseSheet: View {
    let document: AboutDocument
    let close: () -> Void

    var body: some View {
        SheetScaffold(document.title) {
            ScrollView {
                Text(document.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.rxInkSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(RX.Space.s4)
            }
            .frame(height: 320)
            .background(
                RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                    .strokeBorder(Color.rxHairline, lineWidth: 1)
            )
        } footer: {
            Spacer()
            Button("Done", action: close)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 600)
    }
}

/// First launch: the license in a scroll card, the agree checkbox, Quit and Continue.
struct AgreementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var agreed = false

    var body: some View {
        SheetScaffold("Welcome to Tamio") {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                ScrollView {
                    Text(AboutDocument.agreement.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.rxInkSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(RX.Space.s4)
                }
                .frame(height: 240)
                .background(
                    RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                        .strokeBorder(Color.rxHairline, lineWidth: 1)
                )
                Toggle("I have read and agree to the license", isOn: $agreed)
                    .rxCheckboxToggle()
                    .font(.rxBody)
            }
        } footer: {
            Button("Quit") { Mac.terminate() }
                .buttonStyle(.rx)
            Spacer()
            Button("Continue") {
                TamioStore.shared.licenseAgreed = true
                dismiss()
            }
            .buttonStyle(.rxPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!agreed)
        }
        .frame(width: 560)
        .interactiveDismissDisabled()
    }
}
