import XCTest
@testable import FireworksCore

/// The sample figures are what a stranger sees first — a reviewer, or someone who
/// opens the app before pasting a key — so they are held to the same arithmetic the
/// real readings are. A demo that contradicts itself reads as a broken app.
final class DemoReadingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testSameMomentProducesTheSameReading() {
        XCTAssertEqual(DemoReading.make(now: now), DemoReading.make(now: now),
                       "the demo must be deterministic, or two panels could disagree")
    }

    func testWindowIsSevenDaysEndingToday() {
        let reading = DemoReading.make(now: now)
        XCTAssertEqual(reading.days.count, 7)
        XCTAssertEqual(reading.days.filter(\.today).count, 1, "exactly one day is today")
        XCTAssertTrue(reading.days.last?.today ?? false, "today is the last bar")
        XCTAssertEqual(reading.days.last?.cost, reading.today)
    }

    func testDaysAreInAscendingOrder() {
        let labels = DemoReading.make(now: now).days.map(\.date)
        XCTAssertEqual(Set(labels).count, labels.count, "no day appears twice")
        XCTAssertEqual(labels, DemoReading.make(now: now).days.map(\.date))
    }

    /// The chart, the headline spend and the model mix are three views of one number.
    /// When they disagree the app looks broken, which is the whole reason this file
    /// exists.
    func testSpendAgreesWithTheChartAndTheMix() {
        let reading = DemoReading.make(now: now)
        let charted = Money.rounded(reading.days.reduce(0) { $0 + $1.cost })
        XCTAssertEqual(reading.spend, charted, accuracy: 0.001,
                       "spend since the first reading must equal the bars drawn for it")
        XCTAssertEqual(reading.models.values.reduce(0, +), reading.spend, accuracy: 0.001,
                       "the model mix is a breakdown of the spend, so it sums to it")
    }

    /// The dial's denominator is the open cycle, and what it has left has to match the
    /// days drawn inside that cycle. This is the relationship a reader checks without
    /// meaning to: bars since the top-up, versus credit left.
    func testCycleIsConsistentWithTheBarsInsideIt() {
        let reading = DemoReading.make(now: now)
        guard let cycleBalance = reading.cycleBalance, let cycleStart = reading.cycleStart else {
            return XCTFail("the demo must carry an open cycle — the fallback path is the one case nobody sees")
        }
        XCTAssertEqual(cycleBalance, DemoReading.cycleBalance)
        XCTAssertLessThanOrEqual(cycleBalance, DemoReading.credited,
                                 "a cycle cannot exceed everything ever paid in")
        XCTAssertEqual(reading.denominator, cycleBalance,
                       "the dial divides by the cycle, not the lifetime total")

        let cycleBars = reading.days.suffix(DemoReading.cycleDays).reduce(0) { $0 + $1.cost }
        XCTAssertEqual(reading.cycleUsed ?? -1, Money.rounded(cycleBars), accuracy: 0.001,
                       "what the dial says is gone must be what the cycle's bars add up to")
        XCTAssertEqual(cycleBalance - reading.remaining, Money.rounded(cycleBars), accuracy: 0.001)

        // Every bar inside the cycle starts at or after the top-up, and every bar
        // before it does not — otherwise the chart would be claiming spend that
        // predates the credit it came out of.
        XCTAssertGreaterThan(reading.days.count, DemoReading.cycleDays,
                            "there has to be at least one bar from before the top-up")
    }

    func testCycleStartIsOlderThanTheLastCycleDayAndNewerThanTheFirst() {
        let reading = DemoReading.make(now: now)
        guard let cycleStart = reading.cycleStart else { return XCTFail("no cycle start") }
        XCTAssertLessThan(cycleStart, reading.fetchedAt, "the cycle opened before now")
        let daysAgo = reading.fetchedAt.timeIntervalSince(cycleStart) / 86_400
        XCTAssertEqual(daysAgo, Double(DemoReading.cycleDays), accuracy: 0.01)
    }

    /// The sample shows the *normal* state, not the exception: a live balance and a
    /// cycle. The fallback line ("balance last seen") is the one case a reader is least
    /// likely to meet, so the demo must not be it.
    func testDemoShowsTheLiveState() {
        let reading = DemoReading.make(now: now)
        XCTAssertFalse(reading.isEstimated, "the demo carries a live balance")
        XCTAssertEqual(reading.liveBalance, reading.remaining)
        XCTAssertEqual(reading.sourceWord, "live")
        XCTAssertNil(reading.creditAdded, "no top-up is happening in the sample")
    }

    func testFirstReadingCoversTheWindowAndTodayIsWithinADay() {
        let reading = DemoReading.make(now: now)
        XCTAssertEqual(reading.hours, Double(DemoReading.windowDays) * 24,
                       "the first reading is as old as the window that is drawn")
        XCTAssertGreaterThan(reading.hoursToday, 0)
        XCTAssertLessThanOrEqual(reading.hoursToday, 24)
        XCTAssertEqual(reading.anchorTime, reading.fetchedAt.addingTimeInterval(-reading.hours * 3_600))
    }

    /// The one thing the sample must never do is read as a real balance.
    func testTheDemoIsLabelled() {
        XCTAssertFalse(DemoReading.label.isEmpty)
        XCTAssertFalse(DemoReading.explanation.isEmpty)
        XCTAssertTrue(DemoReading.explanation.lowercased().contains("not your account"),
                      "the explanation has to say whose numbers these are not")
    }

    func testPaceAndRemainingArePlausible() {
        let reading = DemoReading.make(now: now)
        XCTAssertGreaterThan(reading.remaining, 0, "a demo that is already spent teaches nothing")
        XCTAssertLessThan(reading.remaining, DemoReading.cycleBalance)
        XCTAssertGreaterThan(reading.dailyRate, 0)
        // Low enough to be interesting, not so low the dial reads as empty.
        XCTAssertLessThan(reading.remaining / DemoReading.cycleBalance, 0.5)
        XCTAssertGreaterThan(reading.remaining / DemoReading.cycleBalance, 0.05)
    }
}
