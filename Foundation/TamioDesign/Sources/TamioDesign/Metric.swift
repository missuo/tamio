//
//  Metric.swift
//  TamioDesign
//

import SwiftUI

/// A number with its unit beside it, baseline-aligned. One `.xl` per card.
public struct MetricView: View {
    public enum Size {
        case xl
        case md
    }

    let value: String
    let unit: String
    let size: Size

    public init(_ value: String, unit: String = "", size: Size = .xl) {
        self.value = value
        self.unit = unit
        self.size = size
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RX.Space.s1) {
            Text(verbatim: value)
                .font(size == .xl ? .rxMetricXL : .rxMetricMD)
                .foregroundStyle(.rxInk)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: value)
            if !unit.isEmpty {
                Text(LocalizedStringKey(unit))
                    .font(size == .xl ? .rxUnit : .system(size: 12, weight: .medium))
                    .foregroundStyle(.rxInk)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// Caption above a medium metric, used in a card's sub-metric row and page headers.
public struct LabeledMetric: View {
    let label: CapsLabel
    let value: String
    let unit: String
    let swatch: Color?

    public init(_ label: LocalizedStringKey, value: String, unit: String = "", swatch: Color? = nil) {
        self.label = CapsLabel(label)
        self.value = value
        self.unit = unit
        self.swatch = swatch
    }

    public init<S: StringProtocol>(_ label: S, value: String, unit: String = "", swatch: Color? = nil) {
        self.label = CapsLabel(label)
        self.value = value
        self.unit = unit
        self.swatch = swatch
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s1) {
            HStack(spacing: 6) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(swatch)
                        .frame(width: 8, height: 8)
                }
                label
            }
            MetricView(value, unit: unit, size: .md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sub-metrics split by `hairline` dividers, `space-5` below the headline metric.
public struct SubMetricRow: View {
    let items: [Item]

    public struct Item: Identifiable {
        /// Stable across rebuilds; one row must not repeat a label.
        public var id: String { label }
        let label: String
        let value: String
        let unit: String
        let swatch: Color?

        public init(_ label: String, value: String, unit: String = "", swatch: Color? = nil) {
            self.label = label
            self.value = value
            self.unit = unit
            self.swatch = swatch
        }
    }

    public init(_ items: [Item]) {
        self.items = items
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Hairline(vertical: true)
                        .padding(.horizontal, RX.Space.s3)
                }
                LabeledMetric(LocalizedStringKey(item.label), value: item.value, unit: item.unit, swatch: item.swatch)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Facts row under a page title (four columns of caption + value).
public struct FactsRow: View {
    public struct Fact: Identifiable {
        /// Stable across rebuilds; one row must not repeat a label.
        public var id: String { label }
        let label: String
        let value: String
        let monospaced: Bool
        let redacted: Bool

        public init(_ label: String, value: String, monospaced: Bool = false, redacted: Bool = false) {
            self.label = label
            self.value = value
            self.monospaced = monospaced
            self.redacted = redacted
        }
    }

    let facts: [Fact]
    public init(_ facts: [Fact]) {
        self.facts = facts
    }

    public var body: some View {
        HStack(alignment: .top, spacing: RX.Space.s4) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: RX.Space.s1) {
                    CapsLabel(LocalizedStringKey(fact.label))
                    RedactableText(fact.value, redacted: fact.redacted)
                        .font(fact.monospaced ? .system(size: 14, weight: .medium, design: .monospaced) : .rxMetricMD)
                        .foregroundStyle(.rxInk)
                        // Long values ("Debian GNU/Linux 12 (bookworm)") wrap
                        // rather than lose a part.
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(fact.redacted ? "" : fact.value)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

public enum RXFormat {
    /// `23 %` style percentages: integers.
    public static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(Int(value.rounded()))
    }

    /// One decimal for rates and sizes.
    public static func oneDecimal(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.1f", value)
    }

    /// Splits a byte count into a number and a unit (`1.4`, `MB`).
    public static func bytes(_ bytes: Double) -> (value: String, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, bytes.isFinite ? bytes : 0)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 || value >= 100 {
            return (String(Int(value.rounded())), units[index])
        }
        return (String(format: "%.1f", value), units[index])
    }

    public static func bytesString(_ value: Double) -> String {
        let pair = bytes(value)
        return "\(pair.value) \(pair.unit)"
    }

    public static func rate(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let pair = bytes(bytesPerSecond)
        return (pair.value, pair.unit + "/s")
    }

    public static func rateString(_ bytesPerSecond: Double) -> String {
        let pair = rate(bytesPerSecond)
        return "\(pair.value) \(pair.unit)"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// "41 days, 3 h" style uptime.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return durationFormatter.string(from: seconds) ?? "—"
    }

    /// "2 min ago", "Yesterday" style relative dates; "Never" before 1971.
    public static func relative(_ date: Date) -> String {
        if date.timeIntervalSince1970 < 86400 * 365 { return String(localized: "Never") }
        if abs(date.timeIntervalSinceNow) < 60 { return String(localized: "Now") }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
