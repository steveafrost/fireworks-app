import SwiftUI
import WidgetKit
import FireworksCore

/// WidgetKit's own view. Nothing here is shared with the app's views except the
/// palette and the money formatting — a widget's layout constraints are
/// genuinely different (no scrolling, no hover, a fixed family), and pretending
/// otherwise produces a popover squeezed into a square.
public struct FireworksWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    let entry: FireworksEntry

    public init(entry: FireworksEntry) { self.entry = entry }

    public var body: some View {
        Group {
            if let snapshot = entry.snapshot, snapshot.denominator > 0 {
                content(snapshot)
            } else {
                unconfigured
            }
        }
        .containerBackground(for: .widget) {
            Palette.surface(scheme)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: ReadingStore.Snapshot) -> some View {
        let ink = Palette.ink(remaining: snapshot.remaining,
                              low: entry.config.lowThreshold,
                              critical: entry.config.criticalThreshold,
                              scheme: scheme)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.formatted(snapshot.remaining))
                    .font(.system(size: family == .systemSmall ? 26 : 30,
                                  weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if family != .systemSmall {
                    Text("\(Int(snapshot.spendPercent.rounded()))%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: snapshot.share)
                .progressViewStyle(.linear)
                .tint(ink)

            HStack(spacing: 6) {
                Label(Money.formatted(snapshot.today), systemImage: "calendar")
                if let daysLeft = snapshot.daysLeft {
                    Label(String(format: "%.1fd", daysLeft), systemImage: "hourglass")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            if family != .systemSmall, snapshot.days.count > 1 {
                DayBars(days: snapshot.days, height: 22)
            }

            Spacer(minLength: 0)

            Text(freshness(snapshot))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .widgetURL(URL(string: "fireworks://open"))
    }

    private var unconfigured: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "flame")
                .font(.system(size: 18))
                .foregroundStyle(Palette.amber(scheme))
            Text("Open Fireworks to set your balance")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text("The app measures spend and writes it here.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func freshness(_ snapshot: ReadingStore.Snapshot) -> String {
        let ago = Time.humanAge(Date().timeIntervalSince(snapshot.fetchedAt))
        return snapshot.account.isEmpty ? "updated \(ago)" : "\(snapshot.account) · \(ago)"
    }
}

/// Small: just the number and the ring's worth of context.
public struct FireworksSmallWidget: View {
    let entry: FireworksEntry
    public init(entry: FireworksEntry) { self.entry = entry }

    public var body: some View {
        if let snapshot = entry.snapshot, snapshot.anchorBalance > 0 {
            VStack(spacing: 3) {
                CreditGauge(reading: gaugeReading(snapshot),
                            low: entry.config.lowThreshold,
                            critical: entry.config.criticalThreshold,
                            size: 96)
                Text(snapshot.daysLeft.map { String(format: "~%.1f days left", $0) } ?? "no rate yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .containerBackground(for: .widget) { Palette.surface(.light) }
        } else {
            FireworksWidgetView(entry: entry)
        }
    }

    /// `CreditGauge` takes a `Reading`; the snapshot is the widget's version of
    /// one, so rebuild the few fields the ring reads rather than teaching the
    /// gauge two shapes.
    private func gaugeReading(_ snapshot: ReadingStore.Snapshot) -> Reading {
        Reading(remaining: snapshot.remaining,
                spend: snapshot.anchorBalance - snapshot.remaining,
                today: snapshot.today,
                models: [:],
                days: snapshot.days,
                hours: 0,
                hoursToday: 0,
                anchorBalance: snapshot.anchorBalance,
                anchorTime: snapshot.fetchedAt,
                fetchedAt: snapshot.fetchedAt)
    }
}
