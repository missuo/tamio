import GhosttyTerminal
import SwiftUI
import TamioDesign

/// Whether a program in the terminal may put text on the clipboard with
/// OSC 52, as tmux and Neovim do over SSH. Off unless the user turns it on:
/// whatever a server prints could otherwise replace what was copied here. A
/// program never gets to read the clipboard, whatever this says.
public enum RemoteClipboardPreference {
    public static let allowsWriteKey = "sb.moe.tamio.terminal.allowsRemoteClipboardWrite"

    static var allowsWrite: Bool { UserDefaults.standard.bool(forKey: allowsWriteKey) }
}

/// A copy a program asked for while that is off. OSC 52 has no reply, so
/// the program believes it copied; the notice says it did not, and lets the
/// user allow the latest one. The request waits, unanswered, while the
/// notice shows, and is denied when it goes.
final class RemoteClipboardNotice: ObservableObject, @unchecked Sendable {
    @MainActor @Published private(set) var shown = false
    @MainActor private var pending: TerminalClipboardConfirmationRequest?
    @MainActor private var dismissal: Task<Void, Never>?
    /// After the user closes the notice, further copies are denied without
    /// it for a while, so a program copying in a loop cannot keep it up.
    @MainActor private var quietUntil: ContinuousClock.Instant?

    static let visibleFor: Duration = .seconds(8)
    static let quietFor: Duration = .seconds(30)

    @MainActor func hold(_ request: TerminalClipboardConfirmationRequest) {
        if let quietUntil, ContinuousClock.now < quietUntil {
            request.respond(allow: false)
            return
        }
        // One notice for a burst of copies: only the latest can be allowed.
        pending?.respond(allow: false)
        pending = request
        if !shown { withAnimation(.easeOut(duration: 0.18)) { shown = true } }
        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            self?.finish(allow: false)
        }
    }

    @MainActor func allowOnce() { finish(allow: true) }

    @MainActor func close() {
        quietUntil = ContinuousClock.now + Self.quietFor
        finish(allow: false)
    }

    /// Denies what is waiting, for a terminal being torn down.
    @MainActor func cancel() {
        dismissal?.cancel()
        pending?.respond(allow: false)
        pending = nil
    }

    @MainActor private func finish(allow: Bool) {
        dismissal?.cancel()
        dismissal = nil
        pending?.respond(allow: allow)
        pending = nil
        withAnimation(.easeOut(duration: 0.18)) { shown = false }
    }
}

/// Floats over the top of the terminal rather than pushing it down, so the
/// terminal keeps its size and the program's screen does not reflow. The
/// copied text is never shown: it came from the server, and could be long or
/// made to mislead.
struct RemoteClipboardNoticeBar: View {
    @ObservedObject var notice: RemoteClipboardNotice

    var body: some View {
        if notice.shown {
            HStack(spacing: RX.Space.s3) {
                Image(rx: "doc.on.clipboard")
                    .foregroundStyle(.rxInkSecondary)
                Text(ConfigLayout.tr("terminal.clipboard.blocked", default: "Blocked a program from copying to the clipboard"))
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(ConfigLayout.tr("terminal.clipboard.allow_once", default: "Allow Once")) { notice.allowOnce() }
                    .buttonStyle(.rx(size: .small))
                RXIconButton(
                    ConfigLayout.tr("terminal.clipboard.close", default: "Close"),
                    systemImage: "xmark", kind: .plain, size: .small
                ) { notice.close() }
            }
            .padding(.leading, RX.Space.s3)
            .padding(.trailing, RX.Space.s2)
            .padding(.vertical, RX.Space.s2)
            .rxCardChrome(radius: RX.Radius.lg)
            .frame(maxWidth: 520)
            .padding(RX.Space.s2)
            .help(ConfigLayout.tr(
                "terminal.clipboard.help",
                default: "A program asked to copy text with OSC 52. Settings › Mouse & Clipboard can allow it every time."
            ))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The switch in Settings › Mouse & Clipboard, supplied by this package so
/// every app that shows the terminal's settings has it.
struct RemoteClipboardSettings: View {
    @AppStorage(RemoteClipboardPreference.allowsWriteKey) private var allowsWrite = false

    var body: some View {
        RXDividedStack {
            SwitchRow(
                ConfigLayout.tr("terminal.clipboard.setting.title", default: "Let programs copy to the clipboard"),
                description: LocalizedStringKey(ConfigLayout.tr(
                    "terminal.clipboard.setting.description",
                    default: "Programs in the terminal, such as tmux and Neovim on a server, can put text on the clipboard with OSC 52. When this is off, each copy is blocked and Tamio offers to allow it once. Programs can never read the clipboard."
                )),
                isOn: $allowsWrite
            )
        }
    }

    static var section: ConfigHostSettingsSection {
        ConfigHostSettingsSection(
            id: "input.programs",
            keywords: "osc 52 osc52 clipboard copy program remote server tmux neovim vim allow block"
        ) { RemoteClipboardSettings() }
    }
}
