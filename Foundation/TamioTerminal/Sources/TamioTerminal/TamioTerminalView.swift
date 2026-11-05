import GhosttyTerminal
import SwiftUI

#if os(macOS)
    import AppKit

    /// Ghostty's native terminal view on this platform.
    public typealias PlatformTerminalView = AppTerminalView
#else
    import UIKit

    public typealias PlatformTerminalView = UITerminalView
#endif

/// One native terminal per SSH context. Copies of this SwiftUI value share the
/// same view/session, preserving scrollback when a terminal moves between windows.
public struct TamioTerminalView {
    nonisolated let session: TamioTerminalSession

    nonisolated public init() { session = TamioTerminalSession() }

    /// A terminal running a shell on this Mac, Ghostty's own way, instead of
    /// showing an SSH session's output: the user's login shell in their home
    /// folder. Input and output never pass through Tamio.
    nonisolated public init(localShell: Bool) { session = TamioTerminalSession(localShell: localShell) }

    nonisolated public func write(_ string: String) { session.output.write(Data(string.utf8)) }

    nonisolated public func setTerminalFontSize(with size: Int, preferConfigured: Bool = false) {
        session.callbacks.setFontSize(size)
        let session = session
        DispatchQueue.main.async { session.applyFontSize(preferConfigured: preferConfigured) }
    }

    nonisolated public func requestTerminalSize() -> CGSize { session.callbacks.terminalSize }

    /// For a terminal kept mounted while another page is shown: a hidden
    /// terminal stops rendering and gives up keyboard focus (so typing never
    /// lands in a session you can't see); shown again, it takes focus back.
    @MainActor public func setActive(_ active: Bool) { session.setActive(active) }

    @discardableResult
    nonisolated public func setupBufferChain(callback: ((String) -> Void)?) -> Self {
        session.callbacks.setInput(callback)
        return self
    }

    @discardableResult
    nonisolated public func setupTitleChain(callback: ((String) -> Void)?) -> Self {
        session.callbacks.setTitle(callback)
        return self
    }

    @discardableResult
    nonisolated public func setupBellChain(callback: (() -> Void)?) -> Self {
        session.callbacks.setBell(callback)
        return self
    }

    @discardableResult
    nonisolated public func setupSizeChain(callback: ((CGSize) -> Void)?) -> Self {
        session.callbacks.setResize(callback)
        return self
    }

    /// Called when a local shell has exited.
    @discardableResult
    nonisolated public func setupCloseChain(callback: (() -> Void)?) -> Self {
        session.callbacks.setClose(callback)
        return self
    }
}

extension TamioTerminalView: View {
    public var body: some View {
        TerminalSurfaceHost(session: session)
            .overlay(alignment: .top) { RemoteClipboardNoticeBar(notice: session.clipboardNotice) }
    }
}

/// The platform view itself, under the notices `TamioTerminalView` lays over it.
private struct TerminalSurfaceHost {
    let session: TamioTerminalSession
}

#if os(macOS)
    extension TerminalSurfaceHost: NSViewRepresentable {
        func makeNSView(context _: Context) -> AppTerminalView { session.platformView() }
        func updateNSView(_: AppTerminalView, context _: Context) {}
    }
#else
    extension TerminalSurfaceHost: UIViewRepresentable {
        func makeUIView(context _: Context) -> UITerminalView { session.platformView() }
        func updateUIView(_: UITerminalView, context _: Context) {}
    }
#endif

/// Only the immutable/thread-safe transport objects cross queues. AppKit storage
/// and all Ghostty view operations are explicitly main-actor isolated.
final class TamioTerminalSession: @unchecked Sendable {
    let callbacks: TerminalCallbacks
    let backend: InMemoryTerminalSession
    let output: TerminalOutputBuffer
    let localShell: Bool
    let clipboardNotice = RemoteClipboardNotice()
    @MainActor private var presentation: TerminalPresentation?

    init(localShell: Bool = false) {
        self.localShell = localShell
        let callbacks = TerminalCallbacks()
        self.callbacks = callbacks
        let backend = InMemoryTerminalSession(
            write: { callbacks.receiveInput($0) },
            resize: { callbacks.receiveSize(columns: Int($0.columns), rows: Int($0.rows)) }
        )
        self.backend = backend
        output = TerminalOutputBuffer { backend.receive($0) }
    }

    @MainActor func platformView() -> PlatformTerminalView {
        if let presentation { return presentation.view }
        let presentation = TerminalPresentation(session: self)
        self.presentation = presentation
        return presentation.view
    }

    @MainActor func applyFontSize(preferConfigured: Bool) { presentation?.applyFontSize(preferConfigured: preferConfigured) }

    @MainActor func setActive(_ active: Bool) {
        let view = platformView()
        view.setSurfaceVisible(active)
        #if os(macOS)
            if active {
                // After SwiftUI has shown the page, so the view is in its window.
                DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            } else if view.window?.firstResponder === view {
                view.window?.makeFirstResponder(nil)
            }
        #elseif targetEnvironment(macCatalyst)
            if active {
                DispatchQueue.main.async { view.becomeFirstResponder() }
            } else if view.isFirstResponder {
                view.resignFirstResponder()
            }
        #else
            // Taking focus would raise the software keyboard; only let it go.
            if !active, view.isFirstResponder { view.resignFirstResponder() }
        #endif
    }
}

@MainActor
private final class TerminalPresentation: NSObject, TerminalSurfaceTitleDelegate,
    TerminalSurfaceBellDelegate, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceCloseDelegate, TerminalSurfaceClipboardConfirmationDelegate
{
    let view: PlatformTerminalView
    private let callbacks: TerminalCallbacks
    private let output: TerminalOutputBuffer
    private let clipboardNotice: RemoteClipboardNotice
    private var initialFontPreferenceApplied = false
    private var didAttach = false

    // SSH workers may release the last session reference. Ghostty's coordinator
    // requires main-actor teardown, including destruction of this view's fields.
    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        clipboardNotice.cancel()
    }

    init(session: TamioTerminalSession) {
        callbacks = session.callbacks
        output = session.output
        clipboardNotice = session.clipboardNotice
        view = PlatformTerminalView(frame: .zero)
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(configurationDidApply), name: TamioTerminalConfiguration.didApply, object: nil)
        view.delegate = self
        view.controller = TamioTerminalConfiguration.controller
        let fontSize = Float(Self.surfaceFontSize(TamioTerminalConfiguration.appliedFontSize ?? Double(callbacks.fontSize)))
        if session.localShell {
            // Ghostty runs the user's shell itself, in a pty of its own, and
            // asks to close once it exits (no wait, so that is at once).
            view.configuration = TerminalSurfaceOptions(
                backend: .exec, fontSize: fontSize, workingDirectory: NSHomeDirectory(), waitAfterCommand: false
            )
        } else {
            // Never the .exec backend for a server: SSH remains owned by Tamio.
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session.backend), fontSize: fontSize)
        }
    }

    func applyFontSize(preferConfigured: Bool) {
        if preferConfigured && initialFontPreferenceApplied { return }
        initialFontPreferenceApplied = true
        if preferConfigured { applyConfiguredFontSize(); return }
        // Changing configuration.fontSize would recreate the surface and erase
        // scrollback. A binding action updates the existing surface in place.
        _ = view.performBindingAction("set_font_size:\(Self.surfaceFontSize(Double(callbacks.fontSize)))")
    }

    /// The size to give the surface for a font size in points. Ghostty's UIKit
    /// surface converts points at 96 dpi, as on iOS; on the Mac, Catalyst
    /// included, a point is 1/72 inch, as the AppKit surface takes it.
    static func surfaceFontSize(_ points: Double) -> Double {
        #if targetEnvironment(macCatalyst)
            points * 72 / 96
        #else
            points
        #endif
    }

    @objc private func configurationDidApply() {
        initialFontPreferenceApplied = true
        applyConfiguredFontSize()
    }

    private func applyConfiguredFontSize() {
        let size = TamioTerminalConfiguration.appliedFontSize ?? Double(callbacks.fontSize)
        _ = view.performBindingAction("set_font_size:\(Self.surfaceFontSize(size))")
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        if !didAttach { applyConfiguredFontSize(); didAttach = true }
        output.setAttached(true)
    }

    func terminalDidDetachSurface() { output.setAttached(false) }
    func terminalDidChangeTitle(_ title: String) { callbacks.receiveTitle(title) }
    func terminalDidRingBell() { callbacks.receiveBell() }
    func terminalDidClose(processAlive _: Bool) { callbacks.receiveClose() }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        switch request.kind {
        case .paste:
            break
        case .osc52Write:
            // A program copying (OSC 52) replaces what the user copied, so it
            // waits for the setting or for Allow Once on the notice.
            if RemoteClipboardPreference.allowsWrite {
                request.respond(allow: true)
            } else {
                clipboardNotice.hold(request)
            }
            return
        case .osc52Read:
            // Never: the clipboard may hold a password copied a moment ago.
            request.respond(allow: false)
            return
        }
        #if os(macOS)
            // Paste protection (Settings › Mouse & Clipboard) found line breaks
            // or control characters the shell would act on at once: ask first.
            let alert = NSAlert()
            alert.messageText = "Paste text that could run commands?"
            alert.informativeText = "It has line breaks or control characters, which a shell runs as soon as they are pasted. This warning is Paste protection under Settings › Mouse & Clipboard."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = Self.pastePreview(request.contents)
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                request.respond(allow: response == .alertFirstButtonReturn)
            }
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(alert.runModal())
            }
        #else
            request.respond(allow: true)
        #endif
    }

    #if os(macOS)
        /// The text about to be pasted, in a scrolling box, so what would run
        /// can be read before deciding.
        private static func pastePreview(_ contents: String) -> NSView {
            let frame = NSRect(x: 0, y: 0, width: 440, height: 110)
            let text = NSTextView(frame: frame)
            text.string = String(contents.prefix(4000))
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textContainerInset = NSSize(width: 4, height: 6)
            text.autoresizingMask = [.width]
            text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(frame: frame)
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            return scroll
        }
    #endif
}
