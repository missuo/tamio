//
//  MonitorCards.swift
//  MachineStatusView
//
//  The cards of a server's monitor. Each card answers one question with one large
//  number and shows only what Tamio reads from the server's system tools.
//

import MachineStatus
import TamioModule
import SwiftUI

// MARK: - System

public struct SystemCard: View {
    @ObservedObject var session: MonitorSession

    public init(session: MonitorSession) {
        self.session = session
    }

    var system: ServerStatus.SystemInfo { session.status.system }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHead("Load")
            MetricView(String(format: "%.2f", system.load1), unit: "1 min")
                .padding(.top, RX.Space.s1)
            SubMetricRow([
                .init("5 min", value: String(format: "%.2f", system.load5)),
                .init("15 min", value: String(format: "%.2f", system.load15)),
                .init("Processes", value: "\(system.runningProcs)", unit: String(localized: "/ \(system.totalProcs) running")),
            ])
            .padding(.top, RX.Space.s5)
        }
        .rxCard()
    }
}

// MARK: - Processor

public struct ProcessorCard: View {
    @ObservedObject var session: MonitorSession
    @State private var showCores = false

    public init(session: MonitorSession) {
        self.session = session
    }

    var processor: ServerStatus.ProcessorInfo { session.status.processor }

    var title: String {
        let count = processor.cores.count
        guard count > 0 else { return String(localized: "Processor") }
        return count == 1 ? String(localized: "Processor · 1 core") : String(localized: "Processor · \(count) cores")
    }

    public var body: some View {
        let summary = processor.summary
        VStack(alignment: .leading, spacing: 0) {
            CardHead(title) {
                RXSegmented(selection: $showCores, options: [
                    .init(false, "Summary"),
                    .init(true, "Cores"),
                ], caps: false)
            }
            MetricView(RXFormat.oneDecimal(Double(summary.sumUsed)), unit: "%")
                .padding(.top, RX.Space.s1)
            if showCores {
                CoreGrid(cores: processor.cores)
                    .padding(.top, RX.Space.s4)
            } else {
                UsageBar([
                    .init("User", Double(summary.sumUser) / 100, .rxAccent),
                    .init("System", Double(summary.sumSystem) / 100, .rxSeries2),
                    .init("IO wait", Double(summary.sumIOWait) / 100, .rxWarning),
                    .init("Nice", Double(summary.sumNice) / 100, .rxControlBorder),
                ])
                .padding(.top, RX.Space.s3)
                SubMetricRow([
                    .init("User", value: RXFormat.oneDecimal(Double(summary.sumUser)), unit: "%", swatch: .rxAccent),
                    .init("System", value: RXFormat.oneDecimal(Double(summary.sumSystem)), unit: "%", swatch: .rxSeries2),
                    .init("IO wait", value: RXFormat.oneDecimal(Double(summary.sumIOWait)), unit: "%", swatch: .rxWarning),
                    .init("Nice", value: RXFormat.oneDecimal(Double(summary.sumNice)), unit: "%", swatch: .rxControlBorder),
                ])
                .padding(.top, RX.Space.s5)
            }
        }
        .rxCard()
    }
}

/// Per-core usage tiles; eight per row, shrinking for large core counts.
public struct CoreGrid: View {
    let cores: [ServerStatus.ProcessPercentInfo]

    public init(cores: [ServerStatus.ProcessPercentInfo]) {
        self.cores = cores
    }

    public var body: some View {
        if cores.isEmpty {
            HelpText("No data")
        } else {
            let perRow = cores.count > 64 ? 16 : 8
            let tileHeight: CGFloat = cores.count > 64 ? 28 : 44
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: perRow), spacing: 6) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, core in
                    CoreTile(index: index, percent: Double(core.sumUsed), height: tileHeight)
                }
            }
        }
    }
}

// MARK: - Memory

public struct MemoryCard: View {
    @ObservedObject var session: MonitorSession
    @State private var showSwap = false

    public init(session: MonitorSession) {
        self.session = session
    }

    var memory: ServerStatus.MemoryInfo { session.status.memory }

    public var body: some View {
        let status = session.status
        let total = Double(memory.memTotal)
        VStack(alignment: .leading, spacing: 0) {
            CardHead(total > 0 ? String(localized: "Memory · \(kB(total))") : String(localized: "Memory")) {
                RXSegmented(selection: $showSwap, options: [
                    .init(false, "RAM"),
                    .init(true, "Swap"),
                ], caps: false)
            }
            if showSwap {
                let swapTotal = Double(memory.swapTotal)
                let swapUsed = max(0, swapTotal - Double(memory.swapFree))
                MetricView(RXFormat.percent(swapTotal > 0 ? swapUsed / swapTotal * 100 : 0), unit: "%")
                    .padding(.top, RX.Space.s1)
                SplitBar([
                    (swapUsed, .rxAccent),
                    (max(0, swapTotal - swapUsed), .rxSurfaceSunken),
                ])
                .padding(.top, RX.Space.s3)
                HStack(spacing: RX.Space.s4) {
                    LegendItem("Used", value: kB(swapUsed), color: .rxAccent)
                    LegendItem("Free", value: kB(Double(memory.swapFree)), color: .rxSurfaceSunken, outlined: true)
                }
                .padding(.top, RX.Space.s3)
                if swapTotal <= 0 {
                    HelpText("No swap")
                        .padding(.top, RX.Space.s3)
                }
            } else {
                MetricView(RXFormat.oneDecimal(status.memoryUsedPercent), unit: "%")
                    .padding(.top, RX.Space.s1)
                SplitBar([
                    (status.memoryUsedKB, .rxAccent),
                    (status.memoryCacheKB, .rxSeries2),
                    (Double(memory.memFree), .rxSurfaceSunken),
                ])
                .padding(.top, RX.Space.s3)
                .accessibilityLabel(String(localized: "\(kB(status.memoryUsedKB)) used, \(kB(status.memoryCacheKB)) cache, \(kB(Double(memory.memFree))) free"))
                FlowRow {
                    LegendItem("Used", value: kB(status.memoryUsedKB), color: .rxAccent)
                    LegendItem("Cache", value: kB(status.memoryCacheKB), color: .rxSeries2)
                    LegendItem("Free", value: kB(Double(memory.memFree)), color: .rxSurfaceSunken, outlined: true)
                }
                .padding(.top, RX.Space.s3)
            }
        }
        .rxCard()
    }

    func kB(_ value: Double) -> String {
        RXFormat.bytesString(value * 1024)
    }
}

/// Wraps short items onto a second line when the card is narrow.
struct FlowRow<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: RX.Space.s4) { content }
            VStack(alignment: .leading, spacing: RX.Space.s2) { content }
        }
    }
}

// MARK: - Disks

public struct DiskCard: View {
    @ObservedObject var session: MonitorSession
    let limit: Int?

    public init(session: MonitorSession, limit: Int? = nil) {
        self.session = session
        self.limit = limit
    }

    public var body: some View {
        let elements = session.status.fileSystem.elements
        let shown = limit.map { Array(elements.prefix($0)) } ?? elements
        VStack(alignment: .leading, spacing: 0) {
            CardHead("Disks")
            if shown.isEmpty {
                HelpText("No data")
                    .padding(.top, RX.Space.s2)
            } else {
                VStack(spacing: RX.Space.s3) {
                    ForEach(shown) { element in
                        UsageListRow(
                            name: element.mountPoint,
                            value: "\(RXFormat.percent(Double(element.percent)))%",
                            detail: String(localized: "\(element.used) of \(element.size)")
                        ) {
                            UsageBar(fraction: Double(element.percent) / 100, thresholds: true)
                        }
                    }
                }
                .padding(.top, RX.Space.s2)
            }
        }
        .rxCard()
    }
}

/// A row of a usage list: monospaced name, bold value and detail, a bar underneath.
struct UsageListRow<Bar: View>: View {
    let name: String
    let value: String
    let detail: String
    let bar: Bar

    init(name: String, value: String, detail: String, @ViewBuilder bar: () -> Bar) {
        self.name = name
        self.value = value
        self.detail = detail
        self.bar = bar()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: RX.Space.s2) {
                Text(name)
                    .font(.rxCode)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: RX.Space.s2)
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.rxInk)
                if !detail.isEmpty {
                    Text("· \(detail)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                }
            }
            bar
        }
    }
}

// MARK: - Network

/// Receive or transmit rate with a sparkline of the samples collected in this session.
public struct ThroughputCard: View {
    public enum Direction {
        case receive
        case transmit
    }

    @ObservedObject var session: MonitorSession
    let direction: Direction
    let height: CGFloat

    public init(session: MonitorSession, direction: Direction, height: CGFloat = 200) {
        self.session = session
        self.direction = direction
        self.height = height
    }

    public var body: some View {
        let isReceive = direction == .receive
        let samples = isReceive ? session.history.receive : session.history.transmit
        let current = Double(isReceive ? session.status.totalReceivePerSecond : session.status.totalTransmitPerSecond)
        let peak = samples.max() ?? 0
        let rate = RXFormat.rate(current)
        VStack(alignment: .leading, spacing: 0) {
            CardHead(isReceive ? String(localized: "Receive") : String(localized: "Transmit")) {
                if peak > 0 {
                    HintText(String(localized: "peak \(RXFormat.rateString(peak))"))
                }
            }
            .padding(.horizontal, RX.Space.s4)
            .padding(.top, RX.Space.s4)
            MetricView(rate.value, unit: rate.unit)
                .padding(.horizontal, RX.Space.s4)
                .padding(.top, RX.Space.s1)
            Spacer(minLength: RX.Space.s2)
            Sparkline(
                samples,
                color: isReceive ? .rxSeries2 : .rxAccent,
                fill: isReceive ? .rxSeries2Fill : .rxAccentFill
            )
            .frame(height: height * 0.42)
        }
        .frame(height: height)
        .rxCardChrome()
    }
}

public struct NetworkCard: View {
    @ObservedObject var session: MonitorSession

    public init(session: MonitorSession) {
        self.session = session
    }

    public var body: some View {
        let elements = session.status.network.elements.sorted { ($0.rxBytesPerSec + $0.txBytesPerSec) > ($1.rxBytesPerSec + $1.txBytesPerSec) }
        let peak = Double(max(1, elements.map { max($0.rxBytesPerSec, $0.txBytesPerSec) }.max() ?? 1))
        VStack(alignment: .leading, spacing: 0) {
            // Totals live in the Receive and Transmit cards beside this one.
            CardHead("Network")
            if elements.isEmpty {
                HelpText("No data")
                    .padding(.top, RX.Space.s2)
            } else {
                VStack(spacing: RX.Space.s3) {
                    ForEach(elements) { element in
                        UsageListRow(
                            name: element.device,
                            value: "↓ \(RXFormat.rateString(Double(element.rxBytesPerSec)))",
                            detail: "↑ \(RXFormat.rateString(Double(element.txBytesPerSec)))"
                        ) {
                            UsageBar([
                                .init("Receive", Double(element.rxBytesPerSec) / peak / 2, .rxSeries2),
                                .init("Transmit", Double(element.txBytesPerSec) / peak / 2, .rxAccent),
                            ])
                        }
                    }
                }
                .padding(.top, RX.Space.s2)
            }
        }
        .rxCard()
    }
}

// MARK: - Graphics

/// One row per GPU from nvidia-smi. Hidden when the server has no GPU.
public struct GraphicsCard: View {
    @ObservedObject var session: MonitorSession

    public init(session: MonitorSession) {
        self.session = session
    }

    public var body: some View {
        if let graphics = session.status.graphics, !graphics.units.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(graphics.units.count == 1 ? String(localized: "Graphics · 1 GPU") : String(localized: "Graphics · \(graphics.units.count) GPUs")) {
                    HintText(String(localized: "Driver \(graphics.version)"))
                }
                VStack(spacing: RX.Space.s4) {
                    ForEach(graphics.units) { unit in
                        GPURow(unit: unit)
                    }
                }
                .padding(.top, RX.Space.s2)
            }
            .rxCard()
        }
    }
}

struct GPURow: View {
    let unit: ServerStatus.SingleGraphicsInfo

    var body: some View {
        let utilisation = Double(unit.utilization.gpu_util)
        let vram = unit.memory.total > 0 ? Double(unit.memory.used / unit.memory.total) * 100 : 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: RX.Space.s2) {
                Text(unit.name)
                    .font(.rxBodyStrong)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                Spacer(minLength: RX.Space.s2)
                Text(String(localized: "Fan \(unit.fan_speed)"))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
            }
            labeledBar("GPU", percent: utilisation, color: .rxAccent)
            labeledBar("VRAM", percent: vram, color: .rxSeries2)
            if !unit.vbios_version.isEmpty {
                HintText(String(localized: "vbios \(unit.vbios_version)"))
            }
        }
    }

    func labeledBar(_ title: LocalizedStringKey, percent: Double, color: Color) -> some View {
        HStack(spacing: RX.Space.s2) {
            CapsLabel(title)
                .frame(width: 40, alignment: .leading)
            UsageBar(fraction: percent / 100, color: color, thresholds: true)
            Text("\(RXFormat.percent(percent))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.rxInk)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
