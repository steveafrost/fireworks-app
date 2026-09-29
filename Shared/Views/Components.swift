import SwiftUI
import FireworksCore

/// Catppuccin, the same palette the menu-bar plugin used — Latte in light mode,
/// Mocha in dark — so a Mac running both does not look like two products.
///
/// Two registers, and keeping them apart is the whole trick:
///
/// * **Marks are saturated.** The balance, the status pill, the 7pt legend dot:
///   small areas of ink that carry meaning.
/// * **Fills are soft.** A chart bar or a composition segment spans hundreds of
///   points; a saturated blue or a pure orange at that size swamps a pastel
///   palette and makes the panel read as an alarm. Wide fills use the lavender
///   and teal end of the palette, and today's bar borrows the balance's own ink
///   so the two agree.
///
/// Text is neither: labels use the system's semantic label colours
/// (`.primary` / `.secondary` / `.tertiary`), which stay legible on whatever
/// surface the host ends up drawing behind them.
public enum Palette {
    public static func green(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xa6e3a1) : hex(0x40a02b) }
    public static func amber(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xfab387) : hex(0xfe640b) }
    public static func red(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xf38ba8) : hex(0xd20f39) }
    public static func accent(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xcba6f7) : hex(0x8839ef) }
    public static func surface(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0x1e1e2e) : hex(0xeff1f5) }
    public static func raised(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0x313244) : hex(0xe6e9ef) }
    public static func trace(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0x45475a) : hex(0xdce0e8) }
    /// Hairlines: a tile's border, the baseline under the chart, the rule above
    /// the footer. One step darker than the track so an edge reads as an edge.
    public static func edge(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0x45475a) : hex(0xccd0da) }
    /// The fill for anything wide and non-semantic: daily bars.
    public static func bar(_ scheme: ColorScheme) -> Color { scheme == .dark ? hex(0xb4befe) : hex(0x7287fd) }
    /// The model-mix ramp, in order. Soft end first, because the first segment
    /// is the widest.
    public static func mix(_ index: Int, _ scheme: ColorScheme) -> Color {
        let ramps = scheme == .dark
            ? [0xb4befe, 0x94e2d5, 0xf5e0dc, 0xcba6f7, 0x74c7ec]
            : [0x7287fd, 0x179299, 0xdc8a78, 0x8839ef, 0x209fb5]
        return hex(ramps[index % ramps.count])
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

/// The spacing scale. Three values, used everywhere, so every surface has the
/// same rhythm instead of a hand-picked gap per component — which is what made
/// the first popover read as assorted boxes rather than one panel.
public enum Rhythm {
    /// Around the panel.
    public static let inset: CGFloat = 15
    /// Between sections.
    public static let section: CGFloat = 15
    /// Inside a section.
    public static let inner: CGFloat = 8
    /// The popover's width. Fixed: a menu-bar panel that resizes with its
    /// content is a panel you cannot aim at.
    public static let width: CGFloat = 340
}

/// A hairline. Used to close a group, never to decorate one.
public struct Rule: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        Rectangle().fill(Palette.edge(scheme)).frame(height: 1)
    }
}

public extension View {
    /// The uppercase micro-label the panel uses for eyebrows and tile titles.
    /// One modifier, so "TODAY" in a tile and "MODEL MIX" over a section can
    /// never drift into two different sizes.
    func eyebrow(_ size: CGFloat = 10) -> some View {
        font(.system(size: size, weight: .semibold))
            .tracking(0.7)
            .textCase(.uppercase)
    }
}

/// The share of the anchor still unspent, as one line: filled is what is left,
/// the track is what is gone.
///
/// This is the bar the panel used instead of the ring. Both encode the same
/// fraction, but a bar costs 8pt of height where a ring costs 128 — which is
/// what let the rest of the panel fit on one screen at a readable size.
public struct CreditBar: View {
    let fraction: Double
    let ink: Color

    @Environment(\.colorScheme) private var scheme

    public init(fraction: Double, ink: Color) {
        self.fraction = fraction
        self.ink = ink
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.trace(scheme))
                Capsule()
                    .fill(ink)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent left")
    }
}

/// A section's eyebrow, with an optional detail on the right. The detail exists
/// so a section heading can carry the one number the section is about ("7 days ·
/// $0.73/day") instead of the chart having to explain itself twice.
public struct SectionLabel: View {
    let title: String
    var detail: String?

    public init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .eyebrow()
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// The state of the balance in two words, tinted by the same ink as the number.
public struct StatusPill: View {
    let text: String
    let tint: Color

    public init(text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// The ring: how much of the anchor is left.
///
/// The ring carries the *share* and the figure next to it carries the dollars,
/// so the two never say the same thing twice — which is what a 128pt ring with
/// "$2.34 / 12% of $20.00" did. `.percent` is the compact form the popover uses;
/// `.amount` puts the balance in the middle, for a widget with no room beside it.
public struct CreditGauge: View {
    public enum Content { case amount, percent }

    let reading: Reading
    let low: Double
    let critical: Double
    var size: CGFloat = 132
    var content: Content = .amount

    @Environment(\.colorScheme) private var scheme

    public init(reading: Reading, low: Double, critical: Double,
                size: CGFloat = 132, content: Content = .amount) {
        self.reading = reading
        self.low = low
        self.critical = critical
        self.size = size
        self.content = content
    }

    private var ink: Color {
        Palette.ink(remaining: reading.remaining, low: low, critical: critical, scheme: scheme)
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.trace(scheme), style: StrokeStyle(lineWidth: max(3, size * 0.1)))
            Circle()
                .trim(from: 0, to: reading.share)
                .stroke(ink, style: StrokeStyle(lineWidth: max(3, size * 0.1), lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                switch content {
                case .amount:
                    Text(Money.formatted(reading.remaining))
                        .font(.system(size: size * 0.235, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("\(Int((reading.share * 100).rounded()))% of \(Money.formatted(reading.anchorBalance))")
                        .font(.system(size: size * 0.095))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                case .percent:
                    Text("\(Int((reading.share * 100).rounded()))%")
                        .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("left")
                        .font(.system(size: size * 0.125))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, size * 0.07)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Money.formatted(reading.remaining)) left, "
                            + "\(Int((reading.share * 100).rounded())) percent of "
                            + Money.formatted(reading.anchorBalance))
    }
}

/// One statistic with the comparison that makes it mean something.
public struct Tile: View {
    let title: String
    let value: String
    var note: String? = nil
    /// A small glyph after the figure — the fire the pace earns when the forecast
    /// runs short.
    ///
    /// A badge rather than a colour on the number: the figure is the same ink as
    /// every other figure, so the tile never shouts, and the mark says what it
    /// means instead of implying the number itself is wrong. (Repainting the pace
    /// red was the earlier version, and it made an ordinary figure look like an
    /// error message.)
    var badge: String? = nil

    @Environment(\.colorScheme) private var scheme

    public init(title: String, value: String, note: String? = nil, badge: String? = nil) {
        self.title = title
        self.value = value
        self.note = note
        self.badge = badge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .eyebrow()
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Palette.raised(scheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Palette.edge(scheme), lineWidth: 1)
        )
    }
}

/// One row of a `MetricTable`.
public struct Metric: Identifiable {
    public var label: String
    public var note: String?
    public var value: String
    public var tint: Color?

    public var id: String { label + value }

    public init(label: String, note: String? = nil, value: String, tint: Color? = nil) {
        self.label = label
        self.note = note
        self.value = value
        self.tint = tint
    }
}

/// Aligned rows: what it is, the qualifier, then the figure.
///
/// The note sits in a fixed-width column and the figures share the trailing
/// edge, so a column of dollars can be read straight down. The previous popover
/// put each note wherever its own width ended, which read as ragged even when
/// every number was correct.
public struct MetricTable: View {
    let rows: [Metric]
    /// Wide enough for "Mon, Sep 28" and "97h · $0.43/d"; fixed so the values
    /// after it line up no matter how the notes change.
    var noteWidth: CGFloat = 104

    public init(_ rows: [Metric], noteWidth: CGFloat = 104) {
        self.rows = rows
        self.noteWidth = noteWidth
    }

    public var body: some View {
        VStack(spacing: 7) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let note = row.note {
                        Text(note)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(width: noteWidth, alignment: .trailing)
                    }
                    Text(row.value)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(row.tint ?? .primary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
            }
        }
    }
}

/// The single-row form, for a narrow surface with only one metric to show.
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
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
    }
}

/// The daily series as bars, with the two things the previous version left out:
/// each bar's value and which day it is. Unlabelled bars are a decoration —
/// you could see that Thursday was expensive and not how expensive, and only a
/// hover told you which day you were even looking at.
public struct DayChart: View {
    let days: [DayTotal]
    var height: CGFloat = 46
    /// Today's bar borrows the balance's ink, so a green panel has a green today.
    var ink: Color

    @Environment(\.colorScheme) private var scheme

    public init(days: [DayTotal], height: CGFloat = 46, ink: Color) {
        self.days = days
        self.height = height
        self.ink = ink
    }

    private func label(for day: DayTotal) -> String {
        day.today ? "Today" : Time.displayLabel(day.date, short: true)
    }

    public var body: some View {
        let peak = max(days.map(\.cost).max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days) { day in
                    let fraction = max(0, min(1, day.cost / peak))
                    VStack(spacing: 3) {
                        Text(Money.formatted(day.cost))
                            .font(.system(size: 9, weight: day.today ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(day.today ? ink : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(day.today ? ink : Palette.bar(scheme))
                            .frame(height: max(2, (height * fraction).rounded()))
                            .padding(.horizontal, 9)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height + 15, alignment: .bottom)
            Rule()
            HStack(spacing: 4) {
                ForEach(days) { day in
                    Text(label(for: day))
                        .font(.system(size: 9, weight: day.today ? .semibold : .regular))
                        .foregroundStyle(day.today ? ink : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The daily series as a bare sparkline, for a widget that has room for a shape
/// and not for labels.
public struct DayBars: View {
    let days: [DayTotal]
    var height: CGFloat = 34
    var ink: Color?

    @Environment(\.colorScheme) private var scheme

    public init(days: [DayTotal], height: CGFloat = 34, ink: Color? = nil) {
        self.days = days
        self.height = height
        self.ink = ink
    }

    public var body: some View {
        let peak = max(days.map(\.cost).max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(days) { day in
                let fraction = max(0, min(1, day.cost / peak))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(day.today ? (ink ?? Palette.green(scheme)) : Palette.bar(scheme))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, height * fraction))
                    .help("\(Time.displayLabel(day.date))  \(Money.formatted(day.cost))")
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

/// The model mix as one stacked bar plus named rows: three named models, the
/// tail rolled into a single recessive segment, so the legend stays short and the
/// bar still adds up.
public struct ModelMix: View {
    let reading: Reading
    /// What the rolled-up segment is called, singular — "1 more model" and
    /// "4 more models" both get built from it, because "1 more models" is the
    /// kind of detail that makes a panel look unfinished.
    var tailNoun: String = "more model"

    @Environment(\.colorScheme) private var scheme

    public init(reading: Reading, tailNoun: String = "more model") {
        self.reading = reading
        self.tailNoun = tailNoun
    }

    public var body: some View {
        let models = reading.visibleModels()
        let named = Array(models.prefix(3))
        let tail = models.dropFirst(3)
        let tailTotal = tail.reduce(0) { $0 + $1.1 }

        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(named.enumerated()), id: \.offset) { index, model in
                        segment(width: geometry.size.width * share(model.1), colour: Palette.mix(index, scheme))
                            .help("\(Reading.shortModel(model.0))  \(Money.formatted(model.1))")
                    }
                    if tailTotal > 0 {
                        segment(width: geometry.size.width * share(tailTotal),
                                colour: Palette.edge(scheme))
                            .help("\(tail.count) more model\(tail.count == 1 ? "" : "s")  \(Money.formatted(tailTotal))")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 9)

            VStack(spacing: 6) {
                ForEach(Array(named.enumerated()), id: \.offset) { index, model in
                    row(name: Reading.shortModel(model.0), colour: Palette.mix(index, scheme), cost: model.1)
                }
                if tailTotal > 0 {
                    row(name: "\(tail.count) \(tailWord(tail.count))", colour: Palette.edge(scheme), cost: tailTotal)
                }
            }
        }
    }

    private func share(_ cost: Double) -> Double {
        reading.spend > 0 ? cost / reading.spend : 0
    }

    private func tailWord(_ count: Int) -> String {
        count == 1 ? tailNoun : tailNoun + "s"
    }

    private func segment(width: CGFloat, colour: Color) -> some View {
        Rectangle().fill(colour).frame(width: max(1, width))
    }

    /// The percent column and the amount column are fixed widths, so the rows
    /// align even though the model names are all different lengths.
    private func row(name: String, colour: Color, cost: Double) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(colour)
                .frame(width: 7, height: 7)
            Text(name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(Money.formatted(cost))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
            Text("\(Int((share(cost) * 100).rounded()))%")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
