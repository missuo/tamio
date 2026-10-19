//
//  StatusItem.swift
//  Tamio (macOS)
//
//  Created by Lakr Aream on 2022/3/1.
//
//  The menu bar extra per server: the run cat (frame rate follows CPU load, crash
//  frame when unreachable) and a popover with CPU / Memory / RX / TX, Graphics and
//  Disks, then Terminal, Monitor and Open Tamio.
//

import AppKit
import Combine
import MachineStatus
import MachineStatusView
import SwiftUI
import TamioModule

/// One server's menu bar item: its model, and the owner of the popover's content.
@MainActor
class MenubarStatusItem: NSObject, Identifiable {
    nonisolated let id: UUID = .init()
    nonisolated var key: String { id.uuidString }

    let machine: RDMachine
    let identity: RDIdentity
    let session: MonitorSession
    let item: MacStatusItem

    var cancellables = Set<AnyCancellable>()

    static let frames = (0 ... 4).map { "cat_frame_\($0)" }
    static let crashFrame = "cat_frame_crash"

    init(machine: RDMachine, identity: RDIdentity, session: MonitorSession? = nil) {
        self.machine = machine
        self.identity = identity
        self.session = session ?? MonitorSession(machine: machine, identity: identity)
        var toggle: (() -> Void)?
        item = MacStatusItem(
            toolTip: machine.name,
            frames: Self.frames.compactMap { NSImage(named: $0) },
            idleFrame: NSImage(named: Self.crashFrame)
        ) { toggle?() }
        super.init()
        toggle = { [weak self] in self?.togglePopover() }
        item.onOpenApp = { Mac.openApp?() }
        observeSession()
    }

    deinit {
        debugPrint("\(self) \(#function)")
    }

    /// How often the cat changes frame: the busier the server, the faster.
    enum CatSpeed: TimeInterval {
        case light = 0.05
        case fast = 0.1
        case run = 0.25
        case walk = 0.5
        case hang = 1
        case broken = -1
    }

    /// The popover's content is made on the first click.
    func togglePopover() {
        if item.popover == nil {
            item.setContent(popoverContent, width: MenubarPopoverView.width)
        }
        item.toggle()
    }

    var popoverContent: some View {
        MenubarPopoverView(session: session) { [weak self] in
            self?.closeThisItem()
        } dismiss: { [weak self] in
            self?.item.close()
        }
        .environmentObject(TamioStore.shared)
        .environment(\.rxControlsAtRest, true)
    }

    func closeThisItem() {
        item.remove()
        session.shutdown()
        cancellables.removeAll()
        MenubarTool.shared.remove(menubarItem: id)
    }
}

/// The popover for one server: the same cards as its Monitor page, in one column.
struct MenubarPopoverView: View {
    @ObservedObject var session: MonitorSession
    @EnvironmentObject var store: TamioStore
    let remove: () -> Void
    let dismiss: () -> Void

    static let width: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, RX.Space.s4)
                .padding(.vertical, RX.Space.s3)
            Hairline()
            ScrollView {
                VStack(spacing: RX.Space.s3) {
                    if session.phase == .connected, session.status.hasData {
                        SystemCard(session: session)
                        ProcessorCard(session: session)
                        MemoryCard(session: session)
                        HStack(spacing: RX.Space.s3) {
                            ThroughputCard(session: session, direction: .receive, height: 128)
                            ThroughputCard(session: session, direction: .transmit, height: 128)
                        }
                        NetworkCard(session: session)
                        DiskCard(session: session)
                        GraphicsCard(session: session)
                    } else {
                        MonitorPlaceholder(session: session)
                    }
                }
                .padding(RX.Space.s3)
            }
            .frame(height: 560)
        }
        .frame(width: Self.width)
        // The window's material, not the popover's, so the cards sit on the same
        // backdrop as in the main window.
        .background(RXWindowBackground().ignoresSafeArea())
    }

    /// Name and system facts on the left; the server's tools as symbols on the right.
    var header: some View {
        let system = session.status.system
        // The hostname only when it says something the name doesn't.
        let hostname = system.hostname == session.machine.name ? "" : system.hostname
        let facts = [hostname, system.releaseName, system.uptimeSec > 0 ? String(localized: "up \(RXFormat.duration(system.uptimeSec))") : ""]
            .filter { !$0.isEmpty }
        return HStack(alignment: .center, spacing: RX.Space.s2) {
            VStack(alignment: .leading, spacing: 2) {
                RedactableText(session.machine.name, redacted: store.machineRedacted == .all)
                    .font(.rxBodyStrong)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: RX.Space.s2)
            ForEach([ServerTool.terminal, .files, .monitor]) { tool in
                RXIconButton(tool.help, systemImage: tool.systemImage, kind: .plain) {
                    dismiss()
                    openMainWindow()
                    tool.show(session.machine.id)
                }
            }
            Hairline(vertical: true)
                .frame(height: 16)
            RXIconButton("Remove from Menu Bar", systemImage: "xmark", kind: .plain, action: remove)
        }
    }

    func openMainWindow() {
        MainWindow.show()
    }
}
