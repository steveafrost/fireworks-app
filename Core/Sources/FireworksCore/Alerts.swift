import Foundation

/// A threshold crossing worth telling the user about.
public struct AlertEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A share of the anchor has been burned.
        case spend
        /// Credit crossed the user's low warning line.
        case low
        /// Credit crossed the user's critical line.
        case critical
        /// The anchor was raised — a top-up, which starts fresh windows.
        case refill
    }

    public var kind: Kind
    public var title: String
    public var message: String
    public var subtitle: String

    public var id: String { kind.rawValue + message }

    public init(kind: Kind, message: String, subtitle: String = "",
                title: String = "Fireworks credit") {
        self.kind = kind
        self.title = title
        self.message = message
        self.subtitle = subtitle
    }
}

/// What has already been said, so nothing is said twice.
///
/// Stored with the reading: an alert must fire once per *real* crossing, and a
/// process that restarts every refresh has no memory of its own.
public struct AlertMemory: Codable, Sendable, Equatable {
    /// `"pct:70"` and `"usd:low"` / `"usd:critical"`, keyed by threshold.
    public var fired: [String: Int]
    public var anchorBalance: Double?
    public var anchorTime: Date?

    public enum CodingKeys: String, CodingKey {
        case fired
        case anchorBalance = "anchor_balance"
        case anchorTime = "anchor_time"
    }

    public init(fired: [String: Int] = [:], anchorBalance: Double? = nil, anchorTime: Date? = nil) {
        self.fired = fired
        self.anchorBalance = anchorBalance
        self.anchorTime = anchorTime
    }
}

public enum Alerts {
    /// `(events, memory)` for the thresholds this reading has just crossed.
    ///
    /// Each threshold fires once per real crossing: one that is no longer crossed
    /// (after a top-up, or a re-anchor) is re-armed, and a raised anchor is
    /// announced as a top-up that starts a fresh set of windows. `isFirstRun`
    /// (nothing cached yet) seeds the memory silently — installing the app while
    /// already past 90% must not fire three alerts at once.
    public static func plan(reading: Reading, config: FireworksConfig,
                            previous: AlertMemory? = nil,
                            isFirstRun: Bool = false) -> (events: [AlertEvent], memory: AlertMemory) {
        var events: [AlertEvent] = []
        var fired = previous?.fired ?? [:]
        let seedOnly = isFirstRun || previous?.anchorBalance == nil

        let priorAnchor = previous?.anchorBalance
        let raised = priorAnchor.map { reading.anchorBalance > $0 + 0.005 } ?? false
        let retimed = previous?.anchorTime != nil && previous?.anchorTime != reading.anchorTime
        if !seedOnly && (raised || retimed) {
            // A fresh window: everything below the new anchor can warn again. Only
            // a *raised* anchor is a top-up — re-stamping the time says nothing.
            if raised, let priorAnchor {
                events.append(AlertEvent(
                    kind: .refill,
                    message: "Credit topped up — the anchor is now \(Money.formatted(reading.anchorBalance)) (was \(Money.formatted(priorAnchor)))",
                    subtitle: "Windows reset · \(Money.formatted(reading.remaining)) left"))
            }
            fired = [:]
        }

        let percent = reading.spentPercent
        let crossed = config.effectiveThresholds.filter { percent >= Double($0) }
        var keys = Set(crossed.map { "pct:\($0)" })
        if reading.remaining <= config.criticalThreshold { keys.insert("usd:critical") }
        if reading.remaining <= config.lowThreshold { keys.insert("usd:low") }

        // An overspent anchor reads as a negative balance; say "over by $x"
        // rather than putting a minus sign inside a sentence.
        let overspent = reading.remaining < 0
        let left = overspent
            ? "over the anchor by \(Money.formatted(-reading.remaining))"
            : "\(Money.formatted(reading.remaining)) left"

        let newly = crossed.filter { fired["pct:\($0)"] == nil }
        if let top = newly.max(), !seedOnly {
            events.append(AlertEvent(
                kind: .spend,
                message: "\(top)% of your credit burned — \(left)",
                subtitle: "\(Money.formatted(reading.spend)) spent since the anchor"))
        }

        if reading.remaining <= config.criticalThreshold, fired["usd:critical"] == nil, !seedOnly {
            events.append(AlertEvent(
                kind: .critical,
                message: overspent
                    ? "Critical — \(left)"
                    : "Critical — only \(Money.formatted(reading.remaining)) left of \(Money.formatted(reading.anchorBalance))",
                subtitle: "Under your \(Money.formatted(config.criticalThreshold)) critical line"))
        } else if reading.remaining <= config.lowThreshold, fired["usd:low"] == nil, !seedOnly {
            events.append(AlertEvent(
                kind: .low,
                message: overspent
                    ? "Low credit — \(left)"
                    : "Low credit — \(Money.formatted(reading.remaining)) left of \(Money.formatted(reading.anchorBalance))",
                subtitle: "Under your \(Money.formatted(config.lowThreshold)) warning line"))
        }

        // Un-crossed thresholds are dropped, which re-arms them for next time.
        let memory = AlertMemory(fired: Dictionary(uniqueKeysWithValues: keys.map { ($0, 1) }),
                                 anchorBalance: reading.anchorBalance,
                                 anchorTime: reading.anchorTime)
        return (events, memory)
    }

    /// The thresholds a person can see are armed, for a settings screen.
    public static func armedSummary(config: FireworksConfig) -> String {
        guard config.notify else { return "Alerts off" }
        return "Alerts on · \(config.thresholdsForDisplay)% of the anchor"
    }
}
