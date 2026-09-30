import Foundation

/// The calls a reading needs. A protocol so tests can drive the whole refresh
/// path (windows, failure fallbacks, alert planning) with no network.
public protocol CostSource: Sendable {
    func totalSpend(from start: Date, to end: Date) async throws -> CostWindow
    func costs(start: Date, end: Date, groupBy: [String]) async throws -> CostWindow
    /// The account's real balance. A source that cannot answer *throws*: the
    /// reading then shows the last balance it was given, marked stale, rather than
    /// inventing a figure — which is the whole difference between a balance and a
    /// guess.
    func balance() async throws -> CreditBalance
    /// What has been paid into the account. Throws for the same reason `balance`
    /// does, and the caller keeps the previous ledger rather than a zero.
    func ledger() async throws -> CreditLedger
}

extension FireworksClient: CostSource {}

public struct RefreshOutcome: Sendable {
    /// The fresh reading, or the previous one when the refresh failed.
    public var reading: Reading?
    /// Crossings to tell the user about. Empty when alerts are off.
    public var events: [AlertEvent]
    /// Non-nil when the newest measurement failed.
    public var error: FireworksError?
    /// True when `reading` is the previous one being shown because of `error`.
    public var isStale: Bool

    public var didSucceed: Bool { error == nil }
}

/// Turns the API's rated-cost figures into a reading, a cache entry and the
/// alerts that reading just earned.
///
/// Never throws: every failure becomes an outcome, because a menu bar and a
/// widget both have to render *something* and "the network is down" is a state,
/// not a crash. A measurement failure keeps the previous reading and says how old
/// it is; a missing key or anchor is a setup state that must not be papered over
/// with a stale number.
public actor RefreshService {
    /// Requests in flight at once. A day per request is a round trip each, so they
    /// overlap — but 30 at once is a burst the API has no reason to allow.
    public static let dayConcurrency = 6
    /// Windows shorter than this are not measured — the API rejects a span of no
    /// length, and a balance-with-no-spend reading is the truthful answer.
    public static let minimumWindow: TimeInterval = 60

    public init() {}

    public func refresh(config: FireworksConfig, previous: Reading?, source: CostSource,
                        now: Date = Date()) async -> RefreshOutcome {
        guard let anchorTime = config.anchorTime, config.isAnchored else {
            return RefreshOutcome(
                reading: previous, events: [],
                error: FireworksError(kind: .setup(
                    "Fireworks has not been reached yet, so there is no balance to show "
                    + "and nothing to measure against")),
                isStale: previous != nil)
        }

        let window: CostWindow
        let today: CostWindow
        // A window shorter than a minute is not worth asking about, and the API
        // refuses it outright — `totalSpend` over a span of no length comes back
        // `HTTP 400 validation failed`. That case is real now that a first run
        // adopts the live balance as its anchor (and it was already reachable by
        // setting an anchor to "now"), and the honest reading of it is zero: the
        // spend since an anchor set seconds ago is zero by definition, and the
        // balance is known, so there is nothing to guess at.
        let measurable = now.timeIntervalSince(anchorTime) >= Self.minimumWindow
        let sinceMidnight = Time.todayWindow(now: now).0
        // The balance and the ledger are a different host and a different protocol,
        // so they go out alongside the spend queries rather than adding themselves to
        // the refresh. A gateway that cannot answer is *not* a failed refresh: the
        // last balance it gave is still a reading.
        let balanceTask = Task { try? await source.balance() }
        let ledgerTask = Task { try? await source.ledger() }
        do {
            window = measurable
                ? try await source.totalSpend(from: anchorTime, to: now)
                : CostWindow()
            today = now.timeIntervalSince(sinceMidnight) >= Self.minimumWindow
                ? try await source.costs(start: sinceMidnight, end: now, groupBy: ["MODEL"])
                : CostWindow()
        } catch let error as FireworksError {
            // A failed measurement is not a reason to invent a number: show the
            // last good reading and say how old it is.
            return RefreshOutcome(reading: previous, events: [], error: error,
                                  isStale: previous != nil)
        } catch {
            return RefreshOutcome(reading: previous, events: [],
                                  error: FireworksError(kind: .transport("\(error)")),
                                  isStale: previous != nil)
        }

        let live = await balanceTask.value
        let ledger = await ledgerTask.value

        let days = await daySeries(source: source, now: now, todayCost: today.subtotal,
                                   days: config.historyDays, previous: previous?.days ?? [])

        // The gateway's figure wins outright when it exists: it is the credit that is
        // actually left. When it does not, the last figure Fireworks gave is shown and
        // the reading marks itself stale — the app does not subtract its way to a
        // number it cannot see.
        let remembered = Money.rounded(live.map(\.amount) ?? config.anchorBalance)
        let credited = ledger?.credited ?? previous?.credited
        let added = Self.creditAdded(credited: credited, previous: previous?.credited)
        // The cycle's credit: what was available when it was last topped up — the
        // balance then, plus what arrived. Dividing by this rather than by the lifetime
        // total is what keeps the dial meaningful: a lifetime denominator can only
        // fall, and it would leave the percent alerts crossed forever.
        let cycle = added.map { Money.rounded((previous?.remaining ?? config.anchorBalance) + $0) }
            ?? (config.cycleBalance > 0 ? config.cycleBalance : nil)
            ?? Self.rebuiltCycle(remaining: remembered, since: ledger?.lastPaid, days: days)
            ?? credited
        var reading = Reading(
            remaining: remembered,
            spend: Money.rounded(window.subtotal),
            today: Money.rounded(today.subtotal),
            models: window.models.mapValues { Money.rounded($0) },
            days: days,
            hours: (now.timeIntervalSince(anchorTime) / 3600),
            hoursToday: (now.timeIntervalSince(Time.todayWindow(now: now).0) / 3600),
            anchorBalance: remembered,
            anchorTime: anchorTime,
            fetchedAt: now,
            liveBalance: live.map { Money.rounded($0.amount) },
            // Carried forward on a failed invoice read: the denominator changes when
            // the account is topped up, not when the network drops.
            credited: credited,
            balanceSeenAt: live != nil ? now : (previous?.balanceSeenAt ?? config.anchorTime),
            cycleBalance: cycle,
            cycleStart: added != nil
                ? now
                : (config.cycleStart ?? ledger?.lastPaid ?? ledger?.firstPaid ?? config.anchorTime),
            creditAdded: added)

        let (events, memory) = Alerts.plan(reading: reading, config: config,
                                           previous: previous?.alerts,
                                           isFirstRun: previous == nil)
        reading.alerts = memory
        return RefreshOutcome(reading: reading, events: config.notify ? events : [],
                              error: nil, isStale: false)
    }

    /// Credit added since the previous reading, or nil when nothing arrived — or when
    /// the ledger could not be read, or there is no previous reading to compare with.
    ///
    /// A cent of tolerance: figures are rounded to six places on their way to disk, so
    /// a rounding crumb must not be read as a top-up and refill the dial.
    static func creditAdded(credited: Double?, previous: Double?) -> Double? {
        guard let credited, let previous else { return nil }
        let difference = Money.rounded(credited - previous)
        return difference > 0.005 ? difference : nil
    }

    /// The cycle's credit rebuilt from the newest top-up, for the first run after the
    /// cycle existed — or a first run on a new Mac.
    ///
    /// The balance falls by exactly what has been spent since credit was added, so the
    /// credit that was available at that top-up is `remaining + spent since then`, and
    /// the ledger says when it happened. Without this the dial would read the lifetime
    /// total — the very figure this replaced — until the account was next topped up.
    ///
    /// Day granularity is as fine as the spend series goes, so a top-up in the
    /// afternoon drags that morning's spend into the figure: it reads high by at most
    /// one day's spend. Nil when the series does not reach back to the top-up, because
    /// a partial sum would read *low*, and a dial that understates the credit is worse
    /// than one that names the lifetime total honestly.
    static func rebuiltCycle(remaining: Double, since: Date?, days: [DayTotal]) -> Double? {
        guard let since, let earliest = days.first?.date, !days.isEmpty,
              let key = Time.localDayWindows(now: since, days: 1).last?.0,
              earliest <= key else { return nil }
        let spent = days.filter { $0.date >= key }.reduce(0) { $0 + $1.cost }
        return Money.rounded(remaining + spent)
    }

    /// Spend per local day, oldest first, ending with today.
    ///
    /// Today's figure is the one the refresh already fetched — no second query, so
    /// the series can never disagree with the headline. A day that fails is filled
    /// from the previous series: a day that has already been measured does not
    /// change, so one transient error must not blank the chart.
    public func daySeries(source: CostSource, now: Date, todayCost: Double, days: Int,
                          previous: [DayTotal] = []) async -> [DayTotal] {
        let windows = Time.localDayWindows(now: now, days: days)
        guard let today = windows.last else { return [] }
        let priorWindows = Array(windows.dropLast())
        let cached = Dictionary(previous.map { ($0.date, $0.cost) }, uniquingKeysWith: { first, _ in first })

        var totals: [DayTotal] = []
        for batch in priorWindows.chunked(into: Self.dayConcurrency) {
            let results = await withTaskGroup(of: (String, Double?).self) { group in
                for day in batch {
                    group.addTask {
                        do {
                            let window = try await source.costs(start: day.1, end: day.2,
                                                                groupBy: ["MODEL"])
                            return (day.0, window.subtotal)
                        } catch {
                            return (day.0, nil)
                        }
                    }
                }
                var collected: [(String, Double?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            // The order of a task group is not the order of its input, so the
            // series is re-sorted by date rather than by arrival.
            for (date, cost) in results.sorted(by: { $0.0 < $1.0 }) {
                totals.append(DayTotal(date: date, cost: Money.rounded(cost ?? cached[date] ?? 0),
                                       today: false))
            }
        }
        totals.sort { $0.date < $1.date }
        totals.append(DayTotal(date: today.0, cost: Money.rounded(todayCost), today: true))
        return totals
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
