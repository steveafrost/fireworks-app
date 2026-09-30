import Foundation

/// The numbers the app shows when there is nothing real to show yet.
///
/// One source of sample data for two different jobs: the offscreen renderer
/// (`--render-ui-sample`, which draws the panels used in the README) and the demo
/// mode a person can switch on from the setup card. The renderer installs it
/// silently, because it is drawing documentation; demo mode labels it everywhere it
/// appears, because someone looking at the app has to be able to tell these figures
/// from their own account's.
///
/// The figures are deliberately *self-consistent*, and `DemoReadingTests` holds them
/// to it. A stranger judges the app by these numbers, so they have to survive being
/// read closely: the seven-day chart covers the whole open cycle, the model mix adds
/// up to the spend, and `remaining` is exactly what the cycle's credit has left after
/// the cycle days in the chart. Sample data that contradicts itself makes the app look
/// broken before it has ever been configured.
public enum DemoReading {
    /// Shown wherever sample data appears, so it can never be mistaken for measured.
    public static let label = "Demo"
    /// The one-line explanation that travels with the label.
    public static let explanation = "Sample numbers — not your account"

    /// Credit paid into the account over its life, and the cycle that is open now.
    /// Lifetime is the larger figure on purpose: that relationship is what the app
    /// shows in Settings, and the sample should demonstrate it rather than avoid it.
    public static let credited = 20.00
    public static let cycleBalance = 12.50

    /// The cycle is four days old inside a seven-day window: recent enough that the
    /// chart's older bars are visibly *before* the top-up, which is the distinction the
    /// app exists to draw.
    public static let cycleDays = 4
    public static let windowDays = 7

    /// Costs, oldest first: three days before the last top-up, then the four days of
    /// the open cycle. The last four sum to `cycleBalance - remaining`; all seven sum
    /// to `spend`.
    public static let dailyCosts: [Double] = [2.50, 2.50, 2.50, 2.11, 2.94, 2.27, 2.84]

    /// What is left of the open cycle once its days are paid for. Derived, never
    /// typed in: this is the figure the whole demo hangs together around.
    public static var remaining: Double {
        let cycleSpend = dailyCosts.suffix(cycleDays).reduce(0, +)
        return Money.rounded(cycleBalance - cycleSpend)
    }

    /// Spend since the first reading, over the whole window.
    public static var spend: Double { Money.rounded(dailyCosts.reduce(0, +)) }

    /// Per-model spend, summing to `spend`. Kept realistic in shape — one model
    /// carrying most of it, a long tail — because the mix bar is read at a glance.
    public static let models: [String: Double] = [
        "accounts/fireworks/models/deepseek-v4p1-flash": 9.42,
        "accounts/fireworks/models/glm-5p3-flash": 6.10,
        "accounts/fireworks/models/qwen3-coder-480b": 1.64,
        "accounts/fireworks/models/llama-v3p3-70b": 0.50
    ]

    /// Hours since the first reading, and since local midnight.
    public static let hours: Double = 168
    public static let hoursToday: Double = 14

    /// A reading that looks like a measured one.
    ///
    /// `now` is a parameter rather than read from the clock so the renderer, the demo
    /// and the tests all agree on what "today" means, and so the same call twice
    /// produces the same reading.
    public static func make(now: Date = Date(), calendar: Calendar = .current) -> Reading {
        let day: TimeInterval = 86_400
        let days = (0..<windowDays).map { offset -> DayTotal in
            let date = calendar.date(byAdding: .day, value: offset - (windowDays - 1), to: now) ?? now
            return DayTotal(date: Time.label(for: date),
                            cost: dailyCosts[offset],
                            today: offset == windowDays - 1)
        }
        return Reading(remaining: remaining,
                       spend: spend,
                       today: dailyCosts.last ?? 0,
                       models: models,
                       days: days,
                       hours: hours,
                       hoursToday: hoursToday,
                       anchorBalance: credited,
                       anchorTime: now.addingTimeInterval(-hours * 3_600),
                       fetchedAt: now,
                       liveBalance: remaining,
                       credited: credited,
                       cycleBalance: cycleBalance,
                       cycleStart: now.addingTimeInterval(-Double(cycleDays) * day))
    }
}
