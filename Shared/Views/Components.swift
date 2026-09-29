import SwiftUI
import FireworksCore

/// Catppuccin, the same palette the menu-bar plugin used — Latte in light mode,
/// Mocha in dark — so a Mac running both does not look like two products.
public enum Palette {
    public static func green(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xa6e3a1) : hex(0x40a02b) }
    public static func amber(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xfab387) : hex(0xfe640b) }
    public static func red(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xf38ba8) : hex(0xd20f39) }
    public static func accent(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xcba6f7) : hex(0x8839ef) }
    public static func surface(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0x1e1e2e) : hex(0xeff1f5) }
    public static func raised(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0x313244) : hex(0xe6e9ef) }
    public static func trace(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0x45475a) : hex(0xdce0e8) }
    /// The cool→warm ramp for daily bars: a cheap day is cool, an expensive one warm.
    public static func heat(_ fraction: Double, _ scheme: ColorScheme) -> Color {
        let stops = scheme == .dark
            ? [0x6c7086, 0x7f849c, 0x89b4fa, 0xf9e2af, 0xfab387]
            : [0x8c8fa1, 0x7c7f93, 0x1e66f5, 0xdf8e1d, 0xfe640b]
        let clamped = max(0, min(1, fraction))
        return hex(stops[min(stops.count - 1, Int(clamped * Double(stops.count)))])
    }

    public static func hex(_ value: Int) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
             green: Double((value >> 8) & 0xFF) / 255,
             blue: Double(value & 0xFF) / 255)
    }

    /// The colour a balance earns: green, amber under the low line, red under the
    /// critical one. Shared by the app and the widgets so the two can never
    /// disagree about what "low" looks like.
    public static func ink(remaining: Double, low: Double, critical: Double,
                           scheme: ColorScheme) -> Color {
        if remaining <= critical { return red(scheme) }
        if remaining <= low { return amber(scheme) }
        return green(scheme)
    }
}

/// The ring: remaining credit as a share of the anchor, with the figure in the
/// middle. A ring (not a bar) because the number it encodes is a *share of what
/// you started with*, and a ring reads as a whole.
public struct CreditGauge: View {
    let reading: Reading
    let low: Double
    let critical: Double
    var size: CGFloat = 132

    @Environment(\.colorScheme) private var scheme

    public init(reading: Reading, low: Double, critical: Double, size: CGFloat = 132) {
        self.reading = reading
        self.low = low
        self.critical = critical
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.trace(scheme), style: StrokeStyle(lineWidth: size * 0.085))
            Circle()
                .trim(from: 0, to: reading.share)
                .stroke(Palette.ink(remaining: reading.remaining, low: low, critical: critical,
                                    scheme: scheme),
                        style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(Money.formatted(reading.remaining))
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink(remaining: reading.remaining, low: low,
                                                 critical: critical, scheme: scheme))
                Text("\(Int((reading.share * 100).rounded()))% of \(Money.formatted(reading.anchorBalance))")
                    .font(.system(size: size * 0.095))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// One aligned row: label, value, optional note. Values are monospaced so a
/// column of dollars can be read straight down.
public struct MetricRow: View {
    let label: String
    let value: String
    var note: String? = nil
    var tint: Color? = nil

    public init(label: String, value: String, note: String? = nil, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.note = note
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
    }
}

/// The daily series as a sparkline of bars. Today is tinted; the rest sit on the
/// cool→warm ramp, so a heavy day is visible without reading a single number.
public struct DayBars: View {
    let days: [DayTotal]
    var height: CGFloat = 34

    @Environment(\.colorScheme) private var scheme

    public init(days: [DayTotal], height: CGFloat = 34) {
        self.days = days
        self.height = height
    }

    public var body: some View {
        let peak = max(days.map(\.cost).max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(days) { day in
                let fraction = day.cost / peak
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(day.today
                          ? Palette.ink(remaining: 1, low: 0, critical: -1, scheme: scheme)
                          : Palette.heat(fraction, scheme))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, height * fraction))
                    .help("\(Time.displayLabel(day.date))  \(Money.formatted(day.cost))")
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

/// The model mix as one stacked bar plus named rows: three named models, the tail
/// rolled into a single recessive segment, so the legend is always short and the
/// bar always adds up.
public struct ModelMix: View {
    let reading: Reading

    @Environment(\.colorScheme) private var scheme

    public init(reading: Reading) { self.reading = reading }

    public var body: some View {
        let models = reading.visibleModels()
        if models.isEmpty {
            EmptyView()
        } else {
            let named = Array(models.prefix(3))
            let tail = models.dropFirst(3)
            let tailTotal = tail.reduce(0) { $0 + $1.1 }
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geometry in
                    HStack(spacing: 1) {
                        ForEach(Array(named.enumerated()), id: \.offset) { index, model in
                            segment(width: geometry.size.width * (model.1 / reading.spend),
                                    colour: Palette.hex([0x8839ef, 0x1e66f5, 0x40a02b,
                                                         0xdf8e1d, 0xd20f39][index % 5]))
                                .help("\(Reading.shortModel(model.0))  \(Money.formatted(model.1))")
                        }
                        if tailTotal > 0 {
                            segment(width: geometry.size.width * (tailTotal / reading.spend),
                                    colour: Palette.trace(scheme))
                                .help("\(tail.count) more models  \(Money.formatted(tailTotal))")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .frame(height: 10)

                ForEach(Array(named.enumerated()), id: \.offset) { index, model in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Palette.hex([0x8839ef, 0x1e66f5, 0x40a02b, 0xdf8e1d, 0xd20f39][index % 5]))
                            .frame(width: 7, height: 7)
                        Text(Reading.shortModel(model.0))
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Money.formatted(model.1))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func segment(width: CGFloat, colour: Color) -> some View {
        Rectangle().fill(colour).frame(width: max(1, width))
    }
}

/// A small statistic card — "today", "pace" — with the note carrying the
/// comparison that makes the number mean something.
public struct Tile: View {
    let title: String
    let value: String
    var note: String? = nil
    var tint: Color? = nil

    @Environment(\.colorScheme) private var scheme

    public init(title: String, value: String, note: String? = nil, tint: Color? = nil) {
        self.title = title
        self.value = value
        self.note = note
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Palette.raised(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
