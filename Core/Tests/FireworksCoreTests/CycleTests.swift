import XCTest
@testable import FireworksCore

/// The credit cycle: what the percentages are measured against.
///
/// Not everything ever bought — that fraction can only fall, so a steady user's dial
/// ends up pinned near empty and the percent alerts stay crossed and silent forever.
/// The cycle is what was available when credit was last added, so it refills on a
/// top-up and empties as it is spent.
final class CycleTests: XCTestCase {
    let now = date(2026, 9, 29, 16, 30)

    /// A balance Fireworks has already reported once, and no cycle yet.
    private func config(cycle: Double = 0) -> FireworksConfig {
        var config = FireworksConfig()
        config.anchorBalance = 2.00
        config.anchorTime = date(2026, 9, 25, 13, 30)
        config.historyDays = 2
        config.cycleBalance = cycle
        config.cycleStart = cycle > 0 ? date(2026, 9, 25, 13, 30) : nil
        return config
    }

    private func prior(remaining: Double, credited: Double?, cycle: Double? = nil) -> Reading {
        Reading(remaining: remaining, spend: 1.0, today: 0.5, models: [:], days: [],
                hours: 24, hoursToday: 12, anchorBalance: remaining,
                anchorTime: date(2026, 9, 25, 13, 30),
                fetchedAt: date(2026, 9, 29, 12, 0),
                liveBalance: remaining, credited: credited, cycleBalance: cycle)
    }

    private func refresh(config: FireworksConfig, source: FakeSource,
                         previous: Reading? = nil) async -> RefreshOutcome {
        await RefreshService().refresh(config: config, previous: previous, source: source, now: now)
    }

    // MARK: - the tank

    func testATopUpFillsTheTankWithWhatWasLeftPlusWhatArrived() async throws {
        // $2.00 left, $10.00 added: the cycle is $12.00 to spend, and the dial is full.
        // Nothing here was typed in — the ledger said how much arrived and the balance
        // said what was there first.
        let outcome = await refresh(config: config(),
                                    source: FakeSource(live: 12.00, credited: 30.00),
                                    previous: prior(remaining: 2.00, credited: 20.00))
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertEqual(reading.creditAdded ?? 0, 10.00, accuracy: 1e-9)
        XCTAssertEqual(reading.cycleBalance ?? 0, 12.00, accuracy: 1e-9)
        XCTAssertEqual(reading.denominator, 12.00, accuracy: 1e-9)
        XCTAssertEqual(reading.share, 1.0, accuracy: 1e-9)
        XCTAssertEqual(reading.cycleUsed ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(reading.cycleStart, now, "the top-up is when this cycle started")
        XCTAssertEqual(reading.credited ?? 0, 30.00, accuracy: 1e-9, "lifetime is kept for history")
    }

    func testTheDialFallsThroughTheCycleInsteadOfTotallingUpEveryTopUp() async throws {
        // The case that made this necessary: the lifetime ledger is $500, the cycle is
        // $12. Dividing by the lifetime figure would read 0.6% and never recover.
        var config = config(cycle: 12.00)
        config.anchorBalance = 6.84
        let outcome = await refresh(config: config,
                                    source: FakeSource(live: 3.00, credited: 500.00),
                                    previous: prior(remaining: 6.84, credited: 500.00, cycle: 12.00))
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertEqual(reading.denominator, 12.00, accuracy: 1e-9)
        XCTAssertEqual(reading.share, 0.25, accuracy: 1e-9, "a quarter of this cycle is left")
        XCTAssertEqual(reading.cycleUsed ?? 0, 9.00, accuracy: 1e-9)
        XCTAssertEqual(reading.spentPercent, 75.0, accuracy: 1e-9, "and 75% of it has gone")
    }

    func testWithoutATopUpTheCycleIsCarriedNotRecomputed() async throws {
        // A refresh where the ledger says the same total: the cycle must survive it, or
        // every five minutes would silently refill the dial from the lifetime figure.
        let outcome = await refresh(config: config(cycle: 12.00),
                                    source: FakeSource(live: 3.00, credited: 20.00),
                                    previous: prior(remaining: 3.00, credited: 20.00, cycle: 12.00))
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertNil(reading.creditAdded)
        XCTAssertEqual(reading.cycleBalance ?? 0, 12.00, accuracy: 1e-9)
        XCTAssertEqual(reading.cycleStart, date(2026, 9, 25, 13, 30), "the start does not move")
    }

    func testTheCycleSurvivesARestartWithNoCachedReading() async throws {
        let outcome = await refresh(config: config(cycle: 12.00),
                                    source: FakeSource(live: 3.00, credited: 20.00),
                                    previous: nil)
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertEqual(reading.denominator, 12.00, accuracy: 1e-9)
    }

    func testAFreshInstallStartsFromTheLedgerRatherThanASuppliedFigure() async throws {
        // No previous reading to compare against, so no top-up can be detected yet and
        // the first cycle is the lifetime total. It corrects itself on the next top-up.
        let outcome = await refresh(config: config(),
                                    source: FakeSource(live: 7.50, credited: 20.00),
                                    previous: nil)
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertNil(reading.creditAdded)
        XCTAssertEqual(reading.cycleBalance ?? 0, 20.00, accuracy: 1e-9)
        XCTAssertEqual(reading.denominator, 20.00, accuracy: 1e-9)
    }

    func testAFailedLedgerLeavesTheCycleAlone() async throws {
        // FakeSource has no ledger, which is the read that failed. The cycle is the
        // denominator, so it must not change when the network does.
        let outcome = await refresh(config: config(cycle: 12.00),
                                    source: FakeSource(live: 3.00),
                                    previous: prior(remaining: 3.00, credited: 20.00, cycle: 12.00))
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertNil(reading.creditAdded)
        XCTAssertEqual(reading.denominator, 12.00, accuracy: 1e-9)
        XCTAssertEqual(reading.credited ?? 0, 20.00, accuracy: 1e-9, "carried, not emptied")
    }

    // MARK: - rebuilding the cycle the app has never seen

    func testTheCycleIsRebuiltFromTheNewestTopUpWhenNoneWasSeen() async throws {
        // The state this ships into: a cache written before the cycle existed. The dial
        // must not read the lifetime total until the account is topped up again — the
        // balance plus everything spent since the newest invoice IS that top-up's credit.
        var config = config()
        config.anchorBalance = 6.84
        config.historyDays = 5
        let source = FakeSource(today: 1.00,
                                dayCosts: ["2026-09-26": 0.20, "2026-09-27": 0.10,
                                           "2026-09-28": 0.30],
                                live: 6.84, credited: 20.00,
                                lastPaid: date(2026, 9, 25, 13, 20))
        let outcome = await refresh(config: config, source: source,
                                    previous: prior(remaining: 6.84, credited: 20.00))
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertNil(reading.creditAdded, "nothing arrived since the last look")
        // 6.84 left + 0.20 + 0.10 + 0.30 + 1.00 spent since the top-up (the 25th itself
        // is nil in the fake, which is the same as a day with no spend on it).
        XCTAssertEqual(reading.cycleBalance ?? 0, 8.44, accuracy: 1e-9)
        XCTAssertEqual(reading.denominator, 8.44, accuracy: 1e-9)
        XCTAssertEqual(reading.cycleStart, date(2026, 9, 25, 13, 20), "the invoice dates the cycle")
    }

    func testTheRebuildIsRefusedWhenTheSeriesDoesNotReachBackToTheTopUp() async throws {
        // Two days of spend cannot account for a top-up five weeks ago. A partial sum
        // would name a cycle smaller than what is left in it, so the lifetime total is
        // used instead: wrong, but labelled as such, and corrected by the next top-up.
        let source = FakeSource(live: 6.84, credited: 20.00,
                                lastPaid: date(2026, 8, 20, 9, 0))
        let outcome = await refresh(config: config(), source: source,
                                    previous: prior(remaining: 6.84, credited: 20.00))
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertEqual(reading.denominator, 20.00, accuracy: 1e-9)
    }

    // MARK: - what counts as a top-up

    func testARoundingCrumbIsNotATopUp() {
        // The figures are rounded on their way to disk. A crumb must not refill a dial.
        XCTAssertNil(RefreshService.creditAdded(credited: 20.000001, previous: 20.0))
        XCTAssertNil(RefreshService.creditAdded(credited: 19.50, previous: 20.0), "spending is not adding")
        XCTAssertNil(RefreshService.creditAdded(credited: nil, previous: 20.0))
        XCTAssertNil(RefreshService.creditAdded(credited: 20.0, previous: nil))
        XCTAssertEqual(RefreshService.creditAdded(credited: 25.0, previous: 20.0) ?? 0, 5.0, accuracy: 1e-9)
    }

    // MARK: - the words the views use

    func testTheLineNamesTheCycleRatherThanTheLifetimeTotal() {
        let reading = Reading(remaining: 3.00, spend: 1.0, today: 0.5, models: [:], days: [],
                              hours: 24, hoursToday: 12, anchorBalance: 3.00,
                              anchorTime: date(2026, 9, 29, 12, 0),
                              fetchedAt: now, liveBalance: 3.00, credited: 500.00,
                              cycleBalance: 12.00)
        XCTAssertEqual(reading.creditLine(), "of $12.00 this cycle")
        XCTAssertEqual(reading.allTimeLine(), "All time: $497.00 used of $500.00 paid in")

        // No cycle yet: the lifetime total names itself, and does not pretend to be one.
        var bootstrap = reading
        bootstrap.cycleBalance = nil
        XCTAssertEqual(bootstrap.creditLine(), "of $500.00 credited")
    }
}
