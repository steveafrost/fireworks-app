import Foundation

/// A threshold crossing worth telling the user about.
public struct AlertEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A share of the credit has been burned.
        case spend
        /// Credit crossed the user's low warning line.
        case low
        /// Credit crossed the user's critical line.
        case critical
        /// Credit was added — a top-up, which starts fresh windows.
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
    /// What the percentages were measured against when this was written: the credited
    /// total, or the last balance when there is no ledger.
    ///
    /// A top-up raises this, which is a real event — the windows re-arm and it is
    /// announced. A balance falling does not, which is the point: keying the memory
    /// to the balance would have re-armed a window on every single refresh.
    public var denominator: Double?
    /// The old name for `denominator`, still written and still read: a cache written
    /// by the plugin, or by the version that had an anchor, keeps re-arming correctly.
    public var anchorBalance: Double?
    public var anchorTime: Date?

    public enum CodingKeys: String, CodingKey {
        case fired, denominator
        case anchorBalance = "anchor_balance"
        case anchorTime = "anchor_time"
    }

    /// Whichever field carries the reference figure — the new name, or the one an
    /// older cache has.
    public var reference: Double? { denominator ?? anchorBalance }

    public init(fired: [String: Int] = [:], denominator: Double? = nil,
                anchorBalance: Double? = nil, anchorTime: Date? = nil) {
        self.fired = fired
        self.denominator = denominator
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
        let seedOnly = isFirstRun || previous?.reference == nil

        let prior = previous?.reference
        let raised = prior.map { reading.denominator > $0 + 0.005 } ?? false
        let retimed = previous?.anchorTime != nil && previous?.anchorTime != reading.anchorTime
        if !seedOnly && (raised || retimed) {
            // A fresh window: everything below the new figure can warn again. Only a
            // real addition of credit is a top-up — re-stamping the time says nothing.
            if raised, let prior {
                events.append(AlertEvent(
                    kind: .refill,
                    message: "Credit added — \(Money.formatted(reading.denominator)) in total now (was \(Money.formatted(prior)))",
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
                subtitle: creditSubtitle(reading)))
        }

        if reading.remaining <= config.criticalThreshold, fired["usd:critical"] == nil, !seedOnly {
            events.append(AlertEvent(
                kind: .critical,
                message: overspent
                    ? "Critical — \(left)"
                    : "Critical — only \(Money.formatted(reading.remaining)) left of \(Money.formatted(reading.denominator))",
                subtitle: "Under your \(Money.formatted(config.criticalThreshold)) critical line"))
        } else if reading.remaining <= config.lowThreshold, fired["usd:low"] == nil, !seedOnly {
            events.append(AlertEvent(
                kind: .low,
                message: overspent
                    ? "Low credit — \(left)"
                    : "Low credit — \(Money.formatted(reading.remaining)) left of \(Money.formatted(reading.denominator))",
                subtitle: "Under your \(Money.formatted(config.lowThreshold)) warning line"))
        }

        // Un-crossed thresholds are dropped, which re-arms them for next time.
        let memory = AlertMemory(fired: Dictionary(uniqueKeysWithValues: keys.map { ($0, 1) }),
                                 denominator: reading.denominator,
                                 anchorBalance: reading.denominator,
                                 anchorTime: reading.anchorTime)
        return (events, memory)
    }

    /// What a crossing message says it is out of.
    ///
    /// The ledger answers "how much has gone since I paid for this" exactly, with no
    /// measurement. Without one, the measured window is the only figure there is, and
    /// the subtitle says so rather than implying the ledger's total.
    static func creditSubtitle(_ reading: Reading) -> String {
        if let used = reading.creditUsed {
            return "\(Money.formatted(used)) spent of the \(Money.formatted(reading.denominator)) credited"
        }
        return "\(Money.formatted(reading.spend)) spent so far"
    }

    /// The thresholds a person can see are armed, for a settings screen.
    public static func armedSummary(config: FireworksConfig) -> String {
        guard config.notify else { return "Alerts off" }
        return "Alerts on · \(config.thresholdsForDisplay)% of your credit"
    }
}
