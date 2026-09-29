import XCTest
@testable import FireworksCore

/// The refresh path end to end, with the network replaced by a fake: which
/// windows are asked for, what a failure does to the reading, and whether the
/// alerts that come out are the ones the crossing earned.
final class RefreshServiceTests: XCTestCase {
    let now = date(2026, 9, 17, 16, 30)
    var config = FireworksConfig()

    override func setUp() {
        config = FireworksConfig()
        config.anchorBalance = 6.0
        config.anchorTime = date(2026, 9, 16, 0, 0)
        config.historyDays = 3
        config.lowThreshold = 1.00
        config.criticalThreshold = 0.50
    }

    func refresh(source: FakeSource, previous: Reading? = nil) async -> RefreshOutcome {
        await RefreshService().refresh(config: config, previous: previous, source: source, now: now)
    }

    func testBuildsTheReadingFromRatedSpend() async {
        let outcome = await refresh(source: FakeSource(total: 1.2587, today: 0.42))
        let reading = try! XCTUnwrap(outcome.reading)
        XCTAssertEqual(reading.remaining, 4.7413, accuracy: 1e-6)
        XCTAssertEqual(reading.spend, 1.2587, accuracy: 1e-6)
        XCTAssertEqual(reading.today, 0.42, accuracy: 1e-6)
        XCTAssertEqual(reading.anchorBalance, 6.0)
        XCTAssertEqual(reading.models.count, 2)
        XCTAssertNil(outcome.error)
        XCTAssertFalse(outcome.isStale)
    }

    func testTheDaySeriesEndsWithTodayAndNeverAsksTwice() async {
        let outcome = await refresh(source: FakeSource(today: 0.42))
        let reading = try! XCTUnwrap(outcome.reading)
        XCTAssertEqual(reading.days.count, 3)
        XCTAssertEqual(reading.days.map(\.date), ["2026-09-15", "2026-09-16", "2026-09-17"])
        XCTAssertEqual(reading.days.last?.today, true)
        XCTAssertEqual(reading.days.last?.cost ?? 0, 0.42, accuracy: 1e-6)
        // the previous two days are absent from the fake, so they read as $0 —
        // the point is that today's figure came from the reading, not a second query
        XCTAssertEqual(reading.days.dropLast().map(\.cost), [0, 0])
    }

    func testAnUnanchoredConfigIsASetupStateNotAMeasurement() async {
        config.anchorBalance = 0
        let outcome = await refresh(source: FakeSource())
        XCTAssertNil(outcome.reading)
        XCTAssertTrue(outcome.error?.isSetup == true)
        XCTAssertTrue(outcome.error!.errorDescription!.contains("balance you hold"))
    }

    func testAFailedRefreshKeepsTheLastGoodReadingAndSaysItIsStale() async {
        let good = Reading(remaining: 4.74, spend: 1.26, today: 0.42, models: [:], days: [],
                           hours: 40, hoursToday: 16, anchorBalance: 6.0,
                           anchorTime: config.anchorTime!, fetchedAt: now.addingTimeInterval(-900))
        let outcome = await refresh(source: FakeSource(failure: FireworksError(kind: .http(503, ""))),
                                    previous: good)
        XCTAssertEqual(outcome.reading?.remaining, 4.74)     // the number is not invented
        XCTAssertTrue(outcome.isStale)
        XCTAssertEqual(outcome.error?.errorDescription, "HTTP 503")
    }

    func testWithNoEarlierReadingAFailureIsReportedNotFaked() async {
        let outcome = await refresh(source: FakeSource(failure: FireworksError(kind: .http(500, "boom"))))
        XCTAssertNil(outcome.reading)
        XCTAssertFalse(outcome.isStale)
        XCTAssertNotNil(outcome.error)
    }

    func testAFailedDayIsFilledFromTheCachedOneSoTheChartDoesNotBlank() async {
        let previous = Reading(remaining: 4.74, spend: 1.26, today: 0.42, models: [:],
                               days: [DayTotal(date: "2026-09-15", cost: 2.50, today: false),
                                      DayTotal(date: "2026-09-16", cost: 1.25, today: false)],
                               hours: 40, hoursToday: 16, anchorBalance: 6.0,
                               anchorTime: config.anchorTime!, fetchedAt: now.addingTimeInterval(-300))
        // a source that answers the anchor window and today, but fails the per-day
        // windows — which is the case the fallback exists for
        struct DayBroken: CostSource {
            let today: Date
            func totalSpend(from start: Date, to end: Date) async throws -> CostWindow {
                CostWindow(subtotal: 1.26)
            }
            func costs(start: Date, end: Date, groupBy: [String]) async throws -> CostWindow {
                if end == today { return CostWindow(subtotal: 0.42) }
                if end.timeIntervalSince(start) > 26 * 3600 { return CostWindow(subtotal: 1.26) }
                throw FireworksError(kind: .http(500, "day failed"))
            }
            func balance() async throws -> CreditBalance {
                throw FireworksError(kind: .transport("gateway unreachable"))
            }
        }
        let outcome = await RefreshService().refresh(config: config, previous: previous,
                                                     source: DayBroken(today: now), now: now)
        let days = try! XCTUnwrap(outcome.reading?.days)
        XCTAssertEqual(days.map(\.cost), [2.50, 1.25, 0.42])
        XCTAssertEqual(days.last?.today, true)
    }

    func testAlertsArePlannedAgainstThePreviousCrossings() async {
        // a prior reading that had warned about nothing yet, so the 70% crossing
        // in the new one is genuinely new — a first run seeds silently by design
        let prior = Reading(remaining: 5.50, spend: 0.50, today: 0, models: [:], days: [],
                            hours: 12, hoursToday: 6, anchorBalance: 6.0,
                            anchorTime: config.anchorTime!,
                            fetchedAt: now.addingTimeInterval(-300),
                            alerts: AlertMemory(fired: [:], anchorBalance: 6.0,
                                                anchorTime: config.anchorTime))
        let outcome = await refresh(source: FakeSource(total: 4.50, today: 0.42), previous: prior)
        XCTAssertEqual(outcome.events.map(\.kind), [.spend])
        XCTAssertEqual(outcome.events.first?.message.contains("70%"), true)
        XCTAssertEqual(outcome.reading?.alerts?.fired, ["pct:70": 1])

        // one that already said so stays quiet and keeps the memory
        let said = try! XCTUnwrap(outcome.reading)
        let second = await refresh(source: FakeSource(total: 4.50, today: 0.42), previous: said)
        XCTAssertTrue(second.events.isEmpty)
        XCTAssertEqual(second.reading?.alerts?.fired, ["pct:70": 1])
    }

    func testAlertsOffProducesNoEventsButStillRemembers() async {
        config.notify = false
        let prior = Reading(remaining: 5.50, spend: 0.50, today: 0, models: [:], days: [],
                            hours: 12, hoursToday: 6, anchorBalance: 6.0,
                            anchorTime: config.anchorTime!,
                            fetchedAt: now.addingTimeInterval(-300),
                            alerts: AlertMemory(fired: [:], anchorBalance: 6.0,
                                                anchorTime: config.anchorTime))
        let outcome = await refresh(source: FakeSource(total: 4.50, today: 0.42), previous: prior)
        XCTAssertTrue(outcome.events.isEmpty)
        XCTAssertEqual(outcome.reading?.alerts?.fired, ["pct:70": 1])
    }

    func testTheWidgetSnapshotCarriesWhatAWidgetShows() async {
        let outcome = await refresh(source: FakeSource(total: 1.2587, today: 0.42))
        let reading = try! XCTUnwrap(outcome.reading)
        let snapshot = ReadingStore.Snapshot(reading: reading, account: "f12057")
        XCTAssertEqual(snapshot.remaining, 4.7413, accuracy: 1e-6)
        XCTAssertEqual(snapshot.spendPercent, reading.spentPercent, accuracy: 1e-9)
        XCTAssertEqual(snapshot.days.count, 3)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(ReadingStore.save(snapshot: snapshot, to: directory))
        XCTAssertEqual(ReadingStore.loadSnapshot(from: directory)?.account, "f12057")
    }

    func testTheReadingRoundTripsThroughTheCacheTheWayThePluginWroteIt() async throws {
        let outcome = await refresh(source: FakeSource())
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertTrue(ReadingStore.save(reading, to: directory))

        // the plugin's key names, so either app can read the other's cache
        let text = try String(contentsOf: ReadingStore.url(in: directory), encoding: .utf8)
        XCTAssertTrue(text.contains("\"anchor_balance\""))
        XCTAssertTrue(text.contains("\"hours_today\""))
        XCTAssertTrue(text.contains("\"fetched_at\""))
        XCTAssertTrue(text.contains("\"alerts\""))

        let reloaded = try XCTUnwrap(ReadingStore.load(from: directory))
        XCTAssertEqual(reloaded.remaining, reading.remaining, accuracy: 1e-6)
        XCTAssertEqual(reloaded.days.count, reading.days.count)
        XCTAssertEqual(reloaded.alerts?.fired, reading.alerts?.fired)
    }
}
