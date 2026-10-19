//
//  UpdateCenter.swift
//  Tamio (macOS)
//
//  The app's side of Sparkle (see Bridge+Updates.swift): starts the updater in
//  release builds, and when a check in the background finds a new version,
//  shows a small notice at the bottom of the sidebar, the window's bottom-left
//  corner. Clicking it opens Sparkle's window for that version, with its
//  release notes (CHANGELOG.md, through the appcast).
//

import SwiftUI
import TamioDesign

@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    /// The version a background check found, until it is dealt with.
    @Published private(set) var available: String?
    /// Whether this copy updates itself: the release build only, so a debug
    /// or test copy is never replaced by a release.
    let isSupported = Bundle.main.bundleIdentifier == "sb.moe.tamio" || UpdateCenter.debugFeed != nil

    /// Debug builds started with TAMIO_UPDATE_FEED=<url> update from that
    /// feed, whatever their bundle id: how the update window is looked at.
    static var debugFeed: String? {
        #if DEBUG
            return ProcessInfo.processInfo.environment["TAMIO_UPDATE_FEED"]
        #else
            return nil
        #endif
    }

    func start() {
        #if DEBUG
            // `-TamioPreviewUpdate 1.2.3` shows the notice, to look at it.
            available = UserDefaults.standard.string(forKey: "TamioPreviewUpdate")
        #endif
        guard isSupported else { return }
        Mac.startUpdater()
        Mac.setUpdateNotice { [weak self] version in
            Task { @MainActor in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self?.available = version }
            }
        }
    }

    /// This version's release notes, on its GitHub release page.
    static var releaseNotesURL: URL {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return URL(string: "https://github.com/missuo/tamio/releases/tag/v\(version)")!
    }

    func checkNow() {
        Mac.checkForUpdates()
    }
}

/// "New version available" above Settings.
struct UpdateNotice: View {
    @ObservedObject private var center = UpdateCenter.shared

    var body: some View {
        if let version = center.available {
            Button {
                center.checkNow()
            } label: {
                HStack(spacing: RX.Space.s2) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.rxAccent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("New version available")
                            .font(.rxBodyStrong)
                            .foregroundStyle(.rxInk)
                            .fixedSize()
                        Text("Tamio \(version)")
                            .font(.rxHelp)
                            .foregroundStyle(.rxInkSecondary)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, RX.Space.s3)
                .padding(.vertical, RX.Space.s2)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.rxAccentFill)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show what is new and update"))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
