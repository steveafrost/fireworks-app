import Foundation

/// One local day's rated spend.
public struct DayTotal: Codable, Sendable, Equatable, Identifiable {
    public var date: String
    public var cost: Double
    public var today: Bool

    public var id: String { date }

    public init(date: String, cost: Double, today: Bool) {
        self.date = date
        self.cost = cost
        self.today = today
    }
}

/// A finished measurement — everything a view (menu bar, popover, widget) needs,
/// and nothing it has to compute. Stored on disk as the last *good* reading, so
/// a failed refresh shows the previous numbers and says how old they are instead
/// of going blank.
public struct Reading: Codable, Sendable, Equatable {
    public var remaining: Double
    public var spend: Double
    public var today: Double
    public var models: [String: Double]
    public var days: [DayTotal]
    public var hours: Double
    public var hoursToday: Double
    public var anchorBalance: Double
    public var anchorTime: Date
    public var fetchedAt: Date
    /// Crossing memory for the alerts, carried with the reading so an alert can
    /// never fire twice for the same crossing.
    public var alerts: AlertMemory?
    /// The balance the gateway reported, when it could be reached. `remaining` is
    /// this figure verbatim in that case; nil means `remaining` is the last balance
    /// the gateway gave, remembered across the outage.
    public var liveBalance: Double?
    /// What has been paid into the account, when the gateway could be asked. The
    /// denominator for every percentage in the app: the balance says what is left,
    /// this says what it is left out of. Carried forward from the last good reading
    /// when a refresh cannot reach the invoice call, so an outage does not empty the
    /// dial.
    public var credited: Double?
    /// When the *balance* was last read from Fireworks. `fetchedAt` is when the spend
    /// was measured, which is a different question — a remembered balance with fresh
    /// spend is exactly the state this names.
    public var balanceSeenAt: Date?

    /// True when `remaining` is the anchored estimate rather than the account's
    /// real balance — the popover says so rather than passing an estimate off as
    /// the truth.
    public var isEstimated: Bool { liveBalance == nil }

    /// The denominator for the percentages: what was paid in, or the last balance
    /// Fireworks gave when there is no ledger to divide by. 0 means "cannot say",
    /// which the views draw as no ring rather than as an empty one.
    public var denominator: Double { credited ?? anchorBalance }

    /// Which figure `remaining` is, in the one word the popover has room for.
    public var sourceWord: String { isEstimated ? "stale" : "live" }

    /// Every dollar spent since the account was topped up: the ledger minus what is
    /// left. The measured window answers a different question ("spend since
    /// Thursday"); this one needs no measurement at all.
    public var creditUsed: Double? {
        guard let credited else { return nil }
        return Money.rounded(max(0, credited - remaining))
    }

    /// The line under the credit bar: when the figure was measured.
    ///
    /// Just the time in the normal case, because the panel is already dense. The one
    /// thing that is *not* dropped is the exception: when the gateway could not be
    /// reached the number is the last balance it gave, and a line that said only
    /// "Last updated" would pass a remembered figure off as one just read.
    ///
    /// In Core rather than in the view because it is one string with two states, and
    /// the popover cannot be screenshotted on a Mac without Screen Recording
    /// permission — so it is verified by test.
    public func footnote() -> String {
        guard !isEstimated else {
            return "Balance last seen: \(Time.clock(balanceSeenAt ?? anchorTime))"
        }
        return "Last updated: \(Time.clock(fetchedAt))"
    }

    /// What the balance is out of, in prose, for the views that show a percentage
    /// and have to say what it is a percentage of.
    public func creditLine() -> String {
        if let credited, credited > 0 {
            return "of \(Money.formatted(credited)) credited"
        }
        if anchorBalance > 0 {
            return "of \(Money.formatted(anchorBalance)) last seen"
        }
        return "with no credit history yet"
    }

    public enum CodingKeys: String, CodingKey {
        case remaining, spend, today, models, days, hours, alerts, credited
        case hoursToday = "hours_today"
        case anchorBalance = "anchor_balance"
        case anchorTime = "anchor_time"
        case fetchedAt = "fetched_at"
        case liveBalance = "live_balance"
        case balanceSeenAt = "balance_seen_at"
        case costUsd = "cost"
    }

    /// Writes the same key names the plugin used, so an app on a Mac that ran
    /// the plugin first picks up the existing cache, anchor and alert history.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Money.rounded(remaining), forKey: .remaining)
        try values.encode(Money.rounded(spend), forKey: .spend)
        try values.encode(Money.rounded(today), forKey: .today)
        try values.encode(models, forKey: .models)
        try values.encode(days, forKey: .days)
        try values.encode(hours, forKey: .hours)
        try values.encode(hoursToday, forKey: .hoursToday)
        try values.encode(anchorBalance, forKey: .anchorBalance)
        try values.encode(anchorTime, forKey: .anchorTime)
        try values.encode(fetchedAt, forKey: .fetchedAt)
        try values.encodeIfPresent(alerts, forKey: .alerts)
        try values.encodeIfPresent(liveBalance, forKey: .liveBalance)
        try values.encodeIfPresent(credited, forKey: .credited)
        try values.encodeIfPresent(balanceSeenAt, forKey: .balanceSeenAt)
    }

    public init(remaining: Double, spend: Double, today: Double, models: [String: Double],
                days: [DayTotal], hours: Double, hoursToday: Double, anchorBalance: Double,
                anchorTime: Date, fetchedAt: Date, alerts: AlertMemory? = nil,
                liveBalance: Double? = nil, credited: Double? = nil,
                balanceSeenAt: Date? = nil) {
        self.remaining = remaining
        self.spend = spend
        self.today = today
        self.models = models
        self.days = days
        self.hours = hours
        self.hoursToday = hoursToday
        self.anchorBalance = anchorBalance
        self.anchorTime = anchorTime
        self.fetchedAt = fetchedAt
        self.alerts = alerts
        self.liveBalance = liveBalance
        self.credited = credited
        self.balanceSeenAt = balanceSeenAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        remaining = try values.decode(Double.self, forKey: .remaining)
        spend = (try? values.decode(Double.self, forKey: .spend)) ?? 0
        today = (try? values.decode(Double.self, forKey: .today)) ?? 0
        models = (try? values.decode([String: Double].self, forKey: .models)) ?? [:]
        days = (try? values.decode([DayTotal].self, forKey: .days)) ?? []
        hours = (try? values.decode(Double.self, forKey: .hours)) ?? 0
        hoursToday = (try? values.decode(Double.self, forKey: .hoursToday)) ?? 0
        anchorBalance = (try? values.decode(Double.self, forKey: .anchorBalance)) ?? 0
        anchorTime = (try? values.decode(Date.self, forKey: .anchorTime)) ?? .distantPast
        fetchedAt = (try? values.decode(Date.self, forKey: .fetchedAt)) ?? .distantPast
        alerts = try? values.decodeIfPresent(AlertMemory.self, forKey: .alerts)
        liveBalance = try? values.decodeIfPresent(Double.self, forKey: .liveBalance)
        credited = try? values.decodeIfPresent(Double.self, forKey: .credited)
        balanceSeenAt = try? values.decodeIfPresent(Date.self, forKey: .balanceSeenAt)
    }

    /// The fraction of the credit that is left — the dial's arc.
    ///
    /// Out of what was paid *in*, not out of a figure someone typed: `credited` is
    /// the sum of the paid invoices. It falls back to the last balance Fireworks
    /// gave only when there is no ledger at all (a reading saved before the ledger
    /// existed), and 0 means "cannot say", which the views draw as no ring rather
    /// than as an empty one.
    public var share: Double {
        denominator > 0 ? max(0, min(1, remaining / denominator)) : 0
    }

    public var spentPercent: Double {
        spentShare(anchorBalance: denominator, remaining: remaining)
    }

    public var dailyRate: Double {
        Time.dailyRate(todaySpend: today, hoursToday: hoursToday, spend: spend, hours: hours)
    }

    public var daysLeft: Double? {
        creditDays(remaining: remaining, perDay: dailyRate)
    }

    /// Whether the forecast has run inside the horizon — the condition the pace
    /// tile badges. The rule lives here so the popover, the phone and the widget
    /// cannot disagree about when the mark appears; the glyph belongs to whichever
    /// view draws it, and `horizonDays` of 0 means the mark is off.
    public func paceIsTight(horizonDays: Int) -> Bool {
        guard horizonDays > 0, let left = daysLeft else { return false }
        return left < Double(horizonDays)
    }

    /// The chosen window in dollars — the figure a prepaid account actually
    /// cares about when there is no quota percentage to watch.
    public var windowTotal: Double {
        days.reduce(0) { $0 + $1.cost }
    }

    public var windowDailyAverage: Double {
        days.isEmpty ? 0 : windowTotal / Double(days.count)
    }

    public var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 60 * 30 }

    public func age(now: Date = Date()) -> Double {
        max(0, now.timeIntervalSince(fetchedAt))
    }

    /// Models worth showing: everything else rounds to a cent.
    public func visibleModels(floor: Double = 0.005) -> [(String, Double)] {
        models.filter { $0.value >= floor }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// A short, human model name for a narrow column.
    public static func shortModel(_ name: String) -> String {
        var text = name
        if let range = text.range(of: "models/") { text = String(text[range.upperBound...]) }
        text = text.replacingOccurrences(of: "accounts/fireworks/", with: "")
        if text.count > 16 { text = String(text.prefix(15)) + "…" }
        return text
    }
}

/// Reads and writes the cached reading, atomically: a half-written cache would
/// render as a plausible but wrong balance, which is worse than a stale one.
public enum ReadingStore {
    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("state.json")
    }

    public static func load(from directory: URL) -> Reading? {
        let url = url(in: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Time.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "bad date"))
            }
            return date
        }
        return try? decoder.decode(Reading.self, from: data)
    }

    @discardableResult
    public static func save(_ reading: Reading, to directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(reading).write(to: url(in: directory), options: .atomic)
            return true
        } catch {
            // A cache write failure must never take the app down with it.
            return false
        }
    }

    /// The snapshot a widget reads. Kept deliberately small and separate from the
    /// full reading: widgets get a strict memory and timeline budget, and the
    /// app is the only thing that should be making network calls.
    public struct Snapshot: Codable, Sendable, Equatable {
        public var remaining: Double
        public var anchorBalance: Double
        public var today: Double
        public var dailyRate: Double
        public var daysLeft: Double?
        public var spendPercent: Double
        public var fetchedAt: Date
        public var days: [DayTotal]
        public var account: String
        /// What was paid in, so a widget can say what the balance is out of.
        public var credited: Double?

        /// The figure the percentage is out of: the credited total, or the last
        /// balance when there is no ledger. 0 means the widget has nothing to draw a
        /// fraction from.
        public var denominator: Double { credited ?? anchorBalance }

        /// The fraction of the credit still there, 0–1 — what a bar or a ring draws.
        ///
        /// Here rather than in the view because `spendPercent` is 0–100 and a view
        /// has no way to tell by looking: the widget multiplied it by 100 and drew a
        /// progress bar of `1 − 75`. One figure with one meaning, computed once.
        public var share: Double {
            denominator > 0 ? max(0, min(1, remaining / denominator)) : 0
        }

        public init(reading: Reading, account: String = "") {
            remaining = reading.remaining
            anchorBalance = reading.anchorBalance
            today = reading.today
            dailyRate = reading.dailyRate
            daysLeft = reading.daysLeft
            spendPercent = reading.spentPercent
            fetchedAt = reading.fetchedAt
            days = reading.days
            self.account = account
            credited = reading.credited
        }
    }

    public static func snapshotURL(in directory: URL) -> URL {
        directory.appendingPathComponent("snapshot.json")
    }

    @discardableResult
    public static func save(snapshot: Snapshot, to directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: snapshotURL(in: directory), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func loadSnapshot(from directory: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }
}
