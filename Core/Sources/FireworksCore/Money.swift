import Foundation

/// Money as Fireworks reports it: a protobuf-style `{units, nanos}` pair whose
/// `units` arrives as a *string* (int64 over JSON must not lose precision).
///
/// Everything the app shows is cents-rounded, so the only place full precision
/// matters is the running total: 40 sub-cent API calls must not each round to
/// zero before being summed.
public enum Money {
    public static func parse(units: String?, nanos: Int?) -> Double {
        let whole = Double(units ?? "0") ?? 0
        return whole + Double(nanos ?? 0) / 1_000_000_000
    }

    public static func parse(json: Any?) -> Double {
        guard let row = json as? [String: Any] else { return 0 }
        let units = (row["units"] as? String) ?? (row["units"].map { "\($0)" })
        let nanos = (row["nanos"] as? Int) ?? Int((row["nanos"] as? Double) ?? 0)
        return parse(units: units, nanos: nanos)
    }

    /// `$4.74` — cents everywhere. Four- and six-decimal amounts make a menu
    /// look broken, and nothing here needs more resolution than a cent.
    public static func formatted(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// Rounds to the cent for storage, so a cached reading and the figures it
    /// disagrees with can never differ by a fraction of a cent.
    public static func rounded(_ value: Double, places: Int = 6) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }
}

/// How much of the credit has been burned, 0–100 (0 when there is none).
public func spentShare(anchorBalance: Double, remaining: Double) -> Double {
    guard anchorBalance > 0 else { return 0 }
    return max(0, min(100, (1 - remaining / anchorBalance) * 100))
}

/// Days of credit left at the current rate, or nil when that cannot be said.
public func creditDays(remaining: Double, perDay: Double) -> Double? {
    guard remaining > 0, perDay > 0 else { return nil }
    return remaining / perDay
}
