//
//  BatchRunSheet.swift
//  Tamio (macOS)
//
//  Running one snippet on several servers: per-server state and time on the left
//  (Done `success`, Running `accent`, Failed `danger`), that server's output on the
//  right, overall progress, Stop and Done.
//

import Combine
import TamioModule
import TamioTerminal
import SwiftUI

struct BatchRunSheet: View {
    let snippet: RDSnippet
    let machines: [RDMachine.ID]
    let close: () -> Void

    @StateObject private var context: BatchSnippetExecContext
    @State private var selection: RDMachine.ID?
    @State private var tick = Date()
    /// Set once the sheet has drawn every server as finished.
    @State private var settled = false

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(snippet: RDSnippet, machines: [RDMachine.ID], close: @escaping () -> Void) {
        self.snippet = snippet
        self.machines = machines
        self.close = close
        _context = StateObject(wrappedValue: BatchSnippetExecContext(snippet: snippet, machines: machines))
        _selection = State(initialValue: machines.first)
    }

    var completedCount: Int { context.safeAccessCompletedMachines.count }
    var finished: Bool { completedCount >= machines.count }

    var body: some View {
        SheetScaffold("Run \(snippet.name)") {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                HStack(alignment: .top, spacing: RX.Space.s3) {
                    serverList
                        .frame(width: 220)
                    output
                }
                .frame(height: 320)
                RXProgressBar(machines.isEmpty ? 1 : Double(completedCount) / Double(machines.count))
            }
        } footer: {
            Text(String(localized: "\(completedCount) of \(machines.count) finished"))
                .font(.rxBody.monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
            Spacer()
            if !finished {
                Button("Stop") { context.stopAll() }
                    .buttonStyle(.rx)
            }
            Button("Done") {
                if finished {
                    close()
                } else {
                    Dialogs.requiresConfirmation(
                        message: String(localized: "Stop running \(snippet.name)?"),
                        confirmTitle: String(localized: "Stop and Close"),
                        destructive: true
                    ) { confirmed in
                        guard confirmed else { return }
                        context.stopAll()
                        close()
                    }
                }
            }
            .buttonStyle(.rxPrimary)
            .keyboardShortcut(.defaultAction)
        }
        .frame(width: 820)
        .onAppear { context.start() }
        .onReceive(timer) { date in
            // The running times, and one last pass that draws every server as
            // done; after that nothing changes, and ticking would only redraw
            // the whole sheet twice a second until it is closed.
            guard !settled else { return }
            tick = date
            if finished { settled = true }
        }
    }

    var serverList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(machines, id: \.self) { machine in
                    let state = context.state(for: machine)
                    Button {
                        selection = machine
                    } label: {
                        HStack(spacing: RX.Space.s2) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(context.names[machine] ?? String(localized: "Unknown server"))
                                    .font(.rxBody)
                                    .foregroundStyle(.rxInk)
                                    .lineLimit(1)
                                stateLabel(state)
                            }
                            Spacer()
                            Text(duration(state))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.rxInkSecondary)
                        }
                        .padding(.horizontal, RX.Space.s2)
                        .frame(height: RX.tableRowHeight)
                        .rxRowBackground(selected: selection == machine)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(RX.Space.s2)
        }
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                .strokeBorder(Color.rxHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    func stateLabel(_ state: BatchSnippetExecContext.MachineState) -> some View {
        switch state {
        case .waiting: EmptyView()
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark").foregroundStyle(.rxSuccess).accessibilityLabel("Done")
        case .failed: Image(systemName: "xmark").foregroundStyle(.rxDanger).accessibilityLabel("Failed")
        }
    }

    func duration(_ state: BatchSnippetExecContext.MachineState) -> String {
        let seconds: TimeInterval
        switch state {
        case .waiting: return ""
        case let .running(since): seconds = tick.timeIntervalSince(since)
        case let .done(duration), let .failed(duration): seconds = duration
        }
        return String(format: "%.1f s", max(0, seconds))
    }

    @ViewBuilder var output: some View {
        ZStack {
            ForEach(machines, id: \.self) { machine in
                BatchOutputView(machine: machine)
                    .opacity(selection == machine ? 1 : 0)
                    .allowsHitTesting(selection == machine)
            }
        }
        // The terminal paints its own background, light or dark with the
        // theme; only the corners and the hairline are ours.
        .clipShape(RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                .strokeBorder(Color.rxHairline, lineWidth: 1)
        )
        .environmentObject(context)
    }
}

/// One server's output in a terminal surface.
private struct BatchOutputView: View {
    let machine: RDMachine.ID
    @EnvironmentObject var context: BatchSnippetExecContext

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    // State keeps one terminal per server across view updates.
    @State private var terminalId = UUID()
    @State private var terminalView = TamioTerminalView()

    var body: some View {
        terminalView
            .onReceive(timer) { _ in
                // A drained buffer returns nothing; writing it would only churn.
                let incoming = context.requestBuffer(for: terminalId, machine: machine)
                if !incoming.isEmpty {
                    terminalView.write(incoming)
                }
            }
    }
}
