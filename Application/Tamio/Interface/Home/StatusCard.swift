//
//  StatusCard.swift
//  Tamio (macOS)
//
//  A server's live status card on Home: small, three readings that matter
//  most (CPU, memory, disk) side by side, no rotation. A click opens the
//  inspector with everything else.
//

import MachineStatus
import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

struct StatusCard: View {
    let machine: RDMachine.ID
    var selected = false
    var select: () -> Void = {}

    @EnvironmentObject var store: TamioStore
    @ObservedObject private var live = LiveStatusCenter.shared
    @ObservedObject private var monitors = MonitorCenter.shared
    @State private var hovered = false

    /// Small: three or four across a usual window.
    static let minimumWidth: CGFloat = 240
    static let maximumWidth: CGFloat = 320

    var body: some View {
        let read = store.machineGroup[machine]
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            header(read)
            if let session = live.session(for: machine) {
                StatusSlots(session: session, machine: machine)
            } else {
                unfollowed(read)
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .padding(.top, RX.Space.s3)
        .padding(.bottom, RX.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rxCard(padding: 0)
        .overlay(
            RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                .strokeBorder(Color.rxAccent.opacity(selected ? 0.7 : hovered ? 0.3 : 0), lineWidth: selected ? 1.5 : 1)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .animation(.easeOut(duration: 0.15), value: selected)
        )
        .contentShape(RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous))
        .onHover { hovered = $0 }
        // The click selects at once; a double click also opens a terminal.
        // (A count-2 gesture in front of a count-1 one holds every click
        // back until the double-click time has passed.)
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded { ServerTool.terminal.show(machine) })
        .contextMenu { ServerContextMenu(machine: machine) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(read.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    func header(_ read: RDMachine) -> some View {
        HStack(spacing: RX.Space.s2) {
            StatusPhaseDot(session: live.session(for: machine))
            if let flag = read.countryFlag {
                Text(flag)
                    .font(.system(size: 15))
                    .accessibilityHidden(true)
            }
            RedactableText(read.name.uppercased(), redacted: store.machineRedacted == .all)
                .font(.system(size: 13, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(.rxInk)
                .lineLimit(1)
                .layoutPriority(1)
            if let session = live.session(for: machine) {
                SystemLine(session: session)
            }
            Spacer(minLength: RX.Space.s2)
            HStack(spacing: 2) {
                cardButton("Terminal", systemImage: "terminal") { ServerTool.terminal.show(machine) }
                Menu {
                    ServerContextMenu(machine: machine, includesTools: false)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
                .fixedSize()
                .help(String(localized: "More actions"))
            }
        }
    }

    func cardButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
        .foregroundStyle(.rxAccent)
        .help(title)
    }

    func unfollowed(_ read: RDMachine) -> some View {
        HStack(spacing: RX.Space.s3) {
            Image(systemName: "key")
                .foregroundStyle(.rxInkSecondary)
            Text(live.isEnabled ? "Add a password or key to see live status." : "Live status is off in Settings.")
                .font(.rxBody)
                .foregroundStyle(.rxInkSecondary)
            Spacer()
            if live.isEnabled {
                Button("Edit Server") { ServerActions.edit(machine) }
                    .buttonStyle(.rx(size: .small))
            }
        }
        .frame(height: StatusSlots.height)
    }
}

/// The server's OS logo (Simple Icons, CC0), read from the release name it reports.
struct OSLogo: View {
    @ObservedObject var session: MonitorSession
    var size: CGFloat = 13

    var body: some View {
        let release = session.status.system.releaseName
        if let asset = Self.asset(for: release) {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.rxInkSecondary)
                .help(release)
                .accessibilityLabel(release)
        }
    }

    /// "Ubuntu 24.04.1 LTS" → os-ubuntu, "macOS 26.6" → os-apple, any other
    /// Linux → the penguin.
    static func asset(for release: String) -> String? {
        let name = release.lowercased()
        guard !name.isEmpty else { return nil }
        let marks: [(String, String)] = [
            ("macos", "os-apple"), ("mac os", "os-apple"), ("darwin", "os-apple"),
            ("ubuntu", "os-ubuntu"), ("debian", "os-debian"), ("fedora", "os-fedora"),
            ("arch", "os-archlinux"), ("alpine", "os-alpinelinux"), ("nixos", "os-nixos"),
            ("rocky", "os-rockylinux"), ("centos", "os-centos"), ("freebsd", "os-freebsd"),
            ("windows", "os-windows"),
        ]
        for (mark, asset) in marks where name.contains(mark) { return asset }
        return "os-linux"
    }
}

/// Live / connecting / offline, as a dot before the name.
private struct StatusPhaseDot: View {
    let session: MonitorSession?

    var body: some View {
        if let session {
            Observed(session: session)
        } else {
            Circle().fill(Color.rxInkTertiary).frame(width: 7, height: 7)
        }
    }

    private struct Observed: View {
        @ObservedObject var session: MonitorSession

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .help(help)
        }

        var color: Color {
            switch session.phase {
            case .connected: return session.status.hasData ? .rxSuccess : .rxWarning
            case .connecting: return .rxWarning
            case .failed, .closed: return .rxDanger
            }
        }

        var help: String {
            switch session.phase {
            case .connected: return String(localized: "Live")
            case .connecting: return String(localized: "Connecting…")
            case let .failed(message): return String(localized: "Offline: \(message)")
            case .closed: return String(localized: "Closed")
            }
        }
    }
}

/// The OS logo, then as much of "macOS 26.6.2 · up 25d 5h" as fits whole:
/// all of it, the OS name alone, or the logo alone. Nothing is cut short;
/// what does not fit is in the inspector.
private struct SystemLine: View {
    @ObservedObject var session: MonitorSession
    var showsText = true

    var body: some View {
        let system = session.status.system
        let release = system.releaseName
        let uptime = system.uptimeSec > 0 ? String(localized: "up \(RXFormat.duration(system.uptimeSec))") : ""
        ViewThatFits(in: .horizontal) {
            if showsText, !release.isEmpty, !uptime.isEmpty { line(release + " · " + uptime) }
            if showsText, !release.isEmpty { line(release) }
            OSLogo(session: session, size: 12)
        }
    }

    func line(_ text: String) -> some View {
        HStack(spacing: 4) {
            OSLogo(session: session, size: 12)
            Text(text)
                .font(.rxHelp)
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Slots

struct StatusSlots: View {
    @ObservedObject var session: MonitorSession
    let machine: RDMachine.ID

    static let height: CGFloat = 60

    var body: some View {
        Group {
            switch session.phase {
            case let .failed(message) where !session.status.hasData:
                HStack(spacing: RX.Space.s2) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.rxDanger)
                    // The card's height is fixed: the whole message when
                    // it fits, else the word, with the message on hover.
                    ViewThatFits(in: .vertical) {
                        Text("Offline · \(message)")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Offline")
                    }
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
                    .help(message)
                    Spacer()
                }
            default:
                if session.status.hasData {
                    slots
                } else {
                    HStack(spacing: RX.Space.s2) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                            .font(.rxBody)
                            .foregroundStyle(.rxInkSecondary)
                        Spacer()
                    }
                }
            }
        }
        .frame(height: Self.height)
    }

    /// CPU, memory and the root disk, each a ring with its percentage.
    var slots: some View {
        let status = session.status
        let root = status.fileSystem.elements.first { $0.mountPoint == "/" }
            ?? status.fileSystem.elements.max { $0.percent < $1.percent }
        return HStack(spacing: 0) {
            reading("CPU", help: status.cores == 1 ? String(localized: "1 core") : String(localized: "\(status.cores) cores")) {
                RingGauge(fraction: Double(status.processor.summary.sumUsed) / 100)
            }
            reading("MEM", help: String(localized: "\(ShortBytes.string(status.memoryUsedKB * 1000)) of \(ShortBytes.string(status.memory.memTotal * 1000))")) {
                RingGauge(
                    fraction: status.memoryUsedPercent / 100,
                    cache: status.memory.memTotal > 0 ? status.memoryCacheKB / status.memory.memTotal : 0
                )
            }
            reading("DISK", help: root.map { String(localized: "\($0.used) of \($0.size)") } ?? "") {
                RingGauge(fraction: Double(root?.percent ?? 0) / 100, empty: root == nil)
            }
        }
    }

    func reading(_ caption: LocalizedStringKey, help: String, @ViewBuilder gauge: () -> some View) -> some View {
        VStack(spacing: 4) {
            gauge()
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .help(help)
        .accessibilityElement(children: .combine)
    }

}

enum NetworkFilter {
    /// Loopback, containers, bridges and tunnels: not the server's own traffic.
    static func isVirtual(_ device: String) -> Bool {
        let prefixes = ["lo", "docker", "veth", "br-", "virbr", "vmnet", "tun", "tap", "wg", "utun", "gif", "stf", "anpi", "awdl", "llw", "bridge", "cni", "flannel", "cali", "kube"]
        return prefixes.contains { device.hasPrefix($0) }
    }
}

// MARK: - Gauges

/// "50 K", "2.6 M", "356 G": ServerCat's short byte counts.
enum ShortBytes {
    static func pair(_ bytes: Double) -> (value: String, unit: String) {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = max(0, bytes.isFinite ? bytes : 0)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let text = index == 0 || value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return (text, units[index])
    }

    static func string(_ bytes: Double) -> String {
        let pair = pair(bytes)
        return "\(pair.value) \(pair.unit)"
    }
}

/// A bold number with a small grey unit; green when not zero.
struct ValueText: View {
    let value: String
    let unit: String
    let active: Bool

    init(_ value: String, unit: String, active: Bool) {
        self.value = value
        self.unit = unit
        self.active = active
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(active ? Color.rxSuccess : Color.rxInkSecondary)
                .contentTransition(.numericText())
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.rxInkSecondary)
            }
        }
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

struct BytesText: View {
    let bytes: Double
    init(_ bytes: Double) { self.bytes = bytes }

    var body: some View {
        let pair = RXFormat.bytes(bytes)
        ValueText(pair.value, unit: pair.unit, active: bytes > 0)
    }
}

/// A ring with the percentage inside: used in the threshold colour, an
/// optional grey arc after it (memory cache), the rest light.
struct RingGauge: View {
    let fraction: Double
    var cache: Double = 0
    var empty = false

    var body: some View {
        let used = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        let cached = min(max(cache.isFinite ? cache : 0, 0), 1 - used)
        ZStack {
            Circle()
                .stroke(Color.rxHairline, lineWidth: 4)
            Circle()
                .trim(from: used, to: used + cached)
                .stroke(Color.rxInkTertiary, style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: used)
                .stroke(rxUsageColor(used * 100, base: .rxSuccess), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(empty ? "—" : "\(RXFormat.percent(used * 100))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
                .contentTransition(.numericText())
        }
        .frame(width: 40, height: 40)
        .animation(.easeOut(duration: 0.5), value: used)
    }
}

/// Load as three concentric rings, 1, 5 and 15 minutes from the outside in,
/// each full at one task per core.
struct LoadRings: View {
    let load: (Double, Double, Double)
    let cores: Int

    var body: some View {
        let values = [load.0, load.1, load.2].map { min(max($0 / Double(cores), 0), 1) }
        ZStack {
            ForEach(0 ..< 3, id: \.self) { ring in
                let size = 40 - CGFloat(ring) * 11
                Circle()
                    .stroke(Color.rxHairline, lineWidth: 4)
                    .frame(width: size, height: size)
                Circle()
                    .trim(from: 0, to: max(values[ring], 0.015))
                    .stroke(rxUsageColor(values[ring] * 100, base: .rxSuccess), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: 40, height: 40)
        .animation(.easeOut(duration: 0.5), value: values)
        .help(String(localized: "Load \(String(format: "%.2f", load.0)) · \(String(format: "%.2f", load.1)) · \(String(format: "%.2f", load.2)) on \(cores) cores"))
    }
}
