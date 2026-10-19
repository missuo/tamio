//
//  Charts.swift
//  TamioDesign
//
//  Usage bars, split bars, legends, sparklines and core tiles.
//

import SwiftUI

/// Usage color for disks and VRAM: `warning` at 75%, `danger` at 90%.
public func rxUsageColor(_ percent: Double, base: Color = .rxAccent) -> Color {
    if percent >= 90 { return .rxDanger }
    if percent >= 75 { return .rxWarning }
    return base
}

/// A 6pt rounded track on `surface-sunken` with one or more segments.
public struct UsageBar: View {
    public struct Segment: Identifiable {
        /// Stable across rebuilds as long as a bar's segments keep their
        /// labels; one bar must not repeat a label.
        public var id: String { label }
        let label: String
        let fraction: Double
        let color: Color

        public init(_ label: String = "value", _ fraction: Double, _ color: Color) {
            self.label = label
            self.fraction = fraction
            self.color = color
        }
    }

    let segments: [Segment]
    let height: CGFloat

    public init(_ segments: [Segment], height: CGFloat = 6) {
        self.segments = segments
        self.height = height
    }

    /// A single-value bar; pass `thresholds` to turn it `warning` / `danger` past 75% / 90%.
    public init(fraction: Double, color: Color = .rxAccent, thresholds: Bool = false, height: CGFloat = 6) {
        let clamped = max(0, min(1, fraction.isFinite ? fraction : 0))
        let tint = thresholds ? rxUsageColor(clamped * 100, base: color) : color
        segments = [Segment("value", clamped, tint)]
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    let fraction = max(0, min(1, segment.fraction.isFinite ? segment.fraction : 0))
                    let width = proxy.size.width * fraction - 2
                    // Segments thinner than the bar is tall read as dots; leave them out.
                    if width >= height {
                        Capsule()
                            .fill(segment.color)
                            .frame(width: width)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Capsule().fill(Color.rxSurfaceSunken))
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.3), value: segments.map(\.fraction))
    }
}

/// Segmented 20pt bar (memory used / cache / free).
public struct SplitBar: View {
    let parts: [(value: Double, color: Color)]

    public init(_ parts: [(value: Double, color: Color)]) {
        self.parts = parts
    }

    public var body: some View {
        GeometryReader { proxy in
            let total = max(parts.map { max(0, $0.value) }.reduce(0, +), 0.0001)
            let gaps = CGFloat(max(0, parts.count - 1)) * 4
            HStack(spacing: 4) {
                ForEach(parts.indices, id: \.self) { index in
                    let width = (proxy.size.width - gaps) * CGFloat(max(0, parts[index].value) / total)
                    if width >= 2 {
                        RoundedRectangle(cornerRadius: width < 8 ? 1 : RX.Radius.sm, style: .continuous)
                            .fill(parts[index].color)
                            .frame(width: width)
                    }
                }
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.3), value: parts.map(\.value))
    }
}

/// Legend entry: swatch, name, bold value.
public struct LegendItem: View {
    let title: Text
    let value: String
    let color: Color
    let outlined: Bool

    public init(_ title: LocalizedStringKey, value: String, color: Color, outlined: Bool = false) {
        self.title = Text(title)
        self.value = value
        self.color = color
        self.outlined = outlined
    }

    public init<S: StringProtocol>(_ title: S, value: String, color: Color, outlined: Bool = false) {
        self.title = Text(verbatim: String(title))
        self.value = value
        self.color = color
        self.outlined = outlined
    }

    public var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(outlined ? Color.rxControlBorder : .clear, lineWidth: 1)
                )
                .frame(width: 8, height: 8)
            title
                .foregroundStyle(.rxInkSecondary)
            Text(verbatim: value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(.rxInk)
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

/// 2pt line with a soft area fill, no points, no axes.
public struct Sparkline: View {
    let values: [Double]
    let maxValue: Double?
    let color: Color
    let fill: Color

    public init(_ values: [Double], maxValue: Double? = nil, color: Color = .rxAccent, fill: Color = .rxAccentFill) {
        self.values = values
        self.maxValue = maxValue
        self.color = color
        self.fill = fill
    }

    public var body: some View {
        GeometryReader { proxy in
            let points = makePoints(in: proxy.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(fill)
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: values)
        .accessibilityHidden(true)
    }

    private func makePoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let top = max(maxValue ?? (values.max() ?? 1), 0.0001) * (maxValue == nil ? 1.15 : 1)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let ratio = max(0, min(1, value / top))
            return CGPoint(x: CGFloat(index) * step, y: size.height - 2 - (size.height - 4) * CGFloat(ratio))
        }
    }
}

/// A per-core tile: index top-left, percent top-right, fill height = usage.
public struct CoreTile: View {
    let index: Int
    let percent: Double
    let height: CGFloat

    public init(index: Int, percent: Double, height: CGFloat = 44) {
        self.index = index
        self.percent = percent
        self.height = height
    }

    public var body: some View {
        let fraction = max(0, min(1, percent / 100))
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.rxSurfaceSunken)
            Rectangle()
                .fill(rxUsageColor(percent).opacity(0.85))
                .frame(height: height * CGFloat(fraction))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .top) {
            HStack {
                Text("\(index)")
                Spacer(minLength: 0)
                Text(RXFormat.percent(percent))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(fraction > 0.7 ? Color.white : Color.rxInkSecondary)
            .padding(.horizontal, 5)
            .padding(.top, 4)
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.3), value: percent)
        .accessibilityElement()
        .accessibilityLabel("Core \(index), \(RXFormat.percent(percent)) percent")
    }
}

/// 4pt `accent` progress bar.
public struct RXProgressBar: View {
    let fraction: Double
    public init(_ fraction: Double) { self.fraction = fraction }
    public var body: some View {
        UsageBar(fraction: fraction, height: 4)
    }
}
