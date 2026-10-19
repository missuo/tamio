import Foundation
import TamioDesign
import SwiftUI

struct ConfigDuration {
    static let units = ["ns", "us", "ms", "s", "m", "h", "d", "y"]
    static let names = ["ns": "nanosecond", "us": "microsecond", "ms": "millisecond", "s": "second", "m": "minute", "h": "hour", "d": "day", "y": "year"]
    static func unitName(_ unit: String, count: Int = 1, bundle: Bundle = .module) -> String {
        let base = names[unit] ?? unit
        let fallback = count == 1 ? base : "\(base)s"
        let key = count == 1 ? "duration.unit.\(unit)" : "duration.unit.\(unit).plural"
        return ConfigLayout.tr(key, default: fallback, bundle: bundle)
    }

    static func parse(_ source: String, allowEmpty: Bool) throws -> [(Int, String)] {
        var remaining = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.isEmpty {
            if allowEmpty { return [] }; throw ConfigError.message(ConfigLayout.tr("duration.error.required", default: "Value is required"))
        }
        var result: [(Int, String)] = []; var seen: Set<String> = []
        while !remaining.isEmpty {
            remaining = remaining.trimmingCharacters(in: .whitespaces)
            if remaining.isEmpty { break }
            let digits = remaining.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let number = Int(digits) else { throw ConfigError.message(ConfigLayout.tr("duration.error.non_negative", default: "Expected a non-negative integer")) }
            remaining.removeFirst(digits.count)
            guard let unit = units.first(where: { remaining.hasPrefix($0) }) else { throw ConfigError.message(ConfigLayout.tr("duration.error.unknown_unit", default: "Missing or unknown duration unit")) }
            guard seen.insert(unit).inserted else { throw ConfigError.message(String(format: ConfigLayout.tr("duration.error.duplicate_unit", default: "Duplicate unit: %@"), unit)) }
            remaining.removeFirst(unit.count); result.append((number, unit))
        }
        return result
    }
    static func humanize(_ segments: [(Int, String)], bundle: Bundle = .module) -> String {
        segments.map { count, unit in
            let name = unitName(unit, count: count, bundle: bundle)
            let format = ConfigLayout.tr(count == 1 ? "duration.segment_single" : "duration.segment_plural", default: "%d %@", bundle: bundle)
            return String(format: format, count, name)
        }.joined(separator: ConfigLayout.tr("duration.separator", default: ", ", bundle: bundle))
    }
}
struct ConfigDurationInput: View {
    @Binding var value: String
    let allowEmpty: Bool
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: RX.Space.s2) {
                TextField("e.g. 1h30m", text: $value)
                    .textFieldStyle(.rxMono)
                    .frame(width: 140)
                Menu {
                    ForEach(ConfigDuration.units, id: \.self) { unit in
                        Button(String(format: ConfigLayout.tr("duration.add_unit", default: "Add 1 %@"), ConfigDuration.unitName(unit))) { add(1, unit) }
                    }
                    if allowEmpty {
                        Divider()
                        Button(ConfigLayout.tr("action.unset", default: "Unset")) { value = "" }
                    }
                } label: {
                    Label(ConfigLayout.tr("duration.units", default: "Units"), systemImage: "clock")
                }
                .rxButtonMenu(indicator: false)
                .buttonStyle(.rx(iconOnly: true))
                .fixedSize()
                .help(ConfigLayout.tr("duration.help.add_unit", default: "Add a unit"))
            }
            switch Result(catching: { try ConfigDuration.parse(value, allowEmpty: allowEmpty) }) {
            case let .success(segments):
                if !segments.isEmpty { HelpText(ConfigDuration.humanize(segments)) }
            case let .failure(error):
                HelpText(error.localizedDescription, isError: true)
            }
        }
    }

    private func add(_ number: Int, _ unit: String) {
        var segments = (try? ConfigDuration.parse(value, allowEmpty: true)) ?? []
        if let index = segments.firstIndex(where: { $0.1 == unit }) {
            segments[index].0 += number
        } else {
            segments.append((number, unit))
        }
        value = segments.map { "\($0.0)\($0.1)" }.joined()
    }
}
