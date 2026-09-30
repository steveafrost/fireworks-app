import XCTest
@testable import FireworksCore

/// A fixed zone so a "local day" assertion cannot pass or fail depending on where
/// the test runs — and so a window boundary is checkable to the minute.
let zone = TimeZone(secondsFromGMT: -4 * 3600)!
let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}()

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
          zone: TimeZone = zone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                              hour: hour, minute: minute))!
}

/// Answers by *window*, not by call order: the day requests go out concurrently,
/// so a fake keyed off call order would be flaky by construction.
struct FakeSource: CostSource {
    var total: Double = 1.2587
    var today: Double = 1.2587
    var models: [String: Double] = [
        "accounts/fireworks/models/deepseek-v4p1-flash": 1.198113,
        "accounts/fireworks/models/kimi-k3": 0.029955
    ]
    var dayCosts: [String: Double] = ["2026-09-17": 1.2587]
    var failure: FireworksError?
    /// What the account gateway answers. Nil by default, i.e. a gateway that
    /// cannot be reached — so every expectation written before the live balance
    /// existed is still testing the anchored fallback.
    var live: Double?
    var liveFailure: FireworksError?
    /// What the invoice ledger answers. Nil by default, like `live`: a source with
    /// no ledger, which is the state the denominator has to fall back from.
    var credited: Double?
    /// When the newest paid invoice was issued. Nil by default, which is the state
    /// the cycle cannot be rebuilt from.
    var lastPaid: Date?

    func balance() async throws -> CreditBalance {
        if let liveFailure { throw liveFailure }
        guard let live else {
            throw FireworksError(kind: .transport("gateway unreachable"))
        }
        return CreditBalance(amount: live, currency: "USD", fetchedAt: Date())
    }

    func ledger() async throws -> CreditLedger {
        guard let credited else {
            throw FireworksError(kind: .transport("no ledger"))
        }
        return CreditLedger(credited: credited, paidInvoices: 1, lastPaid: lastPaid)
    }

    func costs(start: Date, end: Date, groupBy: [String]) async throws -> CostWindow {
        if let failure { throw failure }
        let seconds = end.timeIntervalSince(start)
        if seconds <= 26 * 3600 {
            // A completed day ends exactly at local midnight; the window that ends
            // mid-day is today's and answers `today`, so the fake cannot silently
            // return the wrong one of the two.
            if calendar.startOfDay(for: end) == end {
                return CostWindow(subtotal: dayCosts[Time.label(for: start, calendar: calendar)] ?? 0,
                                  models: [:], days: [:])
            }
            return CostWindow(subtotal: today, models: [:], days: [:])
        }
        return CostWindow(subtotal: total, models: models, days: [:])
    }

    func totalSpend(from start: Date, to end: Date) async throws -> CostWindow {
        if let failure { throw failure }
        return CostWindow(subtotal: total, models: models, days: [:])
    }
}

final class MoneyTests: XCTestCase {
    func testParsesUnitsAndNanos() {
        XCTAssertEqual(Money.parse(units: "1", nanos: 185_418_910), 1.18541891, accuracy: 1e-9)
        XCTAssertEqual(Money.parse(units: nil, nanos: nil), 0)
    }

    func testParsesTheJsonShapeTheApiActuallySends() {
        XCTAssertEqual(Money.parse(json: ["units": "1", "nanos": 185_418_910]),
                       1.18541891, accuracy: 1e-9)
        XCTAssertEqual(Money.parse(json: nil), 0)
    }

    func testFormatsTwoDecimals() {
        XCTAssertEqual(Money.formatted(4.7413), "$4.74")
        XCTAssertEqual(Money.formatted(0), "$0.00")
    }

    func testRemainingComesFromTheBalanceNotASubtraction() async {
        // Fireworks reports the balance, so the app shows that figure rather than
        // deriving one. This is the rule that used to be `anchor − spend`.
        let config = FireworksConfig()
        var anchored = config
        anchored.anchorBalance = 6.00
        anchored.anchorTime = Date(timeIntervalSince1970: 1_760_000_000)
        let source = FakeSource(live: 4.7413)
        let outcome = await RefreshService().refresh(config: anchored, previous: nil, source: source)
        XCTAssertEqual(outcome.reading?.remaining ?? 0, 4.7413, accuracy: 1e-6)
        XCTAssertEqual(outcome.reading?.liveBalance ?? 0, 4.7413, accuracy: 1e-6)
    }

    func testSpentShareClampsAndNeedsAnAnchor() {
        XCTAssertEqual(spentShare(anchorBalance: 6, remaining: 4.5), 25, accuracy: 1e-6)
        XCTAssertEqual(spentShare(anchorBalance: 6, remaining: -1), 100, accuracy: 1e-6)
        XCTAssertEqual(spentShare(anchorBalance: 0, remaining: 1), 0)
    }

    func testCreditDaysNeedsBothARateAndCredit() {
        XCTAssertNil(creditDays(remaining: 5, perDay: 0))
        XCTAssertNil(creditDays(remaining: 0, perDay: 1))
        XCTAssertEqual(creditDays(remaining: 5, perDay: 2), 2.5)
    }
}

final class TimeTests: XCTestCase {
    func testTodayWindowStartsAtLocalMidnight() {
        let (start, end) = Time.todayWindow(now: date(2026, 9, 17, 16, 30), calendar: calendar)
        XCTAssertEqual(start, date(2026, 9, 17, 0, 0))
        XCTAssertEqual(end, date(2026, 9, 17, 16, 30))
    }

    func testChunksALongWindowIntoContiguousThirtyOneDaySlices() {
        let start = date(2026, 1, 1)
        let end = date(2026, 3, 12)             // 70 days
        let chunks = Time.chunkWindow(start: start, end: end, calendar: calendar)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.first?.0, start)
        XCTAssertEqual(chunks.last?.1, end)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.1, b.0)            // no gap, no overlap
        }
    }

    func testAShortWindowIsOneChunk() {
        XCTAssertEqual(Time.chunkWindow(start: date(2026, 9, 16), end: date(2026, 9, 17),
                                        calendar: calendar).count, 1)
    }

    func testDayWindowsAreContiguousLocalDaysEndingNow() {
        let windows = Time.localDayWindows(now: date(2026, 9, 17, 16, 30), days: 3,
                                           calendar: calendar)
        XCTAssertEqual(windows.map(\.0), ["2026-09-15", "2026-09-16", "2026-09-17"])
        XCTAssertEqual(windows[0].1, date(2026, 9, 15, 0, 0))
        XCTAssertEqual(windows[2].2, date(2026, 9, 17, 16, 30))
        for (a, b) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(a.2, b.1)
        }
    }

    func testTheDailyRateBlendsTodaysPaceWithTheWindowsAverage() {
        // 12 hours into the day at $1.00 is $2/day; the same $1.00 spent across a
        // 96-hour window is $0.25/day. One heavy afternoon moves the forecast
        // without owning it, so the rate is the mean of the two.
        XCTAssertEqual(Time.dailyRate(todaySpend: 1.00, hoursToday: 12, spend: 1.0, hours: 96),
                       1.125, accuracy: 1e-6)
        // too little of today to have a pace: the average stands alone
        XCTAssertEqual(Time.dailyRate(todaySpend: 0.10, hoursToday: 0.5, spend: 2.0, hours: 48),
                       1.0, accuracy: 1e-6)
        // a fresh anchor has no window behind it: the pace stands alone
        XCTAssertEqual(Time.dailyRate(todaySpend: 0.50, hoursToday: 6, spend: 0, hours: 0),
                       2.0, accuracy: 1e-6)
    }

    func testTheCompactStampStaysShort() {
        let stamp = Time.compactStamp(date(2026, 9, 25, 13, 36))
        XCTAssertTrue(stamp.contains("13:36"), stamp)
        XCTAssertFalse(stamp.contains("2026"), stamp)   // the year is noise in a subtitle
        XCTAssertTrue(stamp.count <= 17, stamp)
        XCTAssertEqual(Time.clock(date(2026, 9, 25, 15, 41)), "15:41")
    }

    func testHumanAgeReadsInTheRightUnit() {
        XCTAssertEqual(Time.humanAge(30), "30s ago")
        XCTAssertEqual(Time.humanAge(600), "10m ago")
        XCTAssertEqual(Time.humanAge(7200), "2h ago")
    }

    func testParsesTheDateShapesASettingsFileCanContain() {
        XCTAssertNotNil(Time.parse("2026-09-16T00:00:00-04:00"))
        XCTAssertNotNil(Time.parse("2026-09-16T00:00:00Z"))
        XCTAssertNotNil(Time.parse("2026-09-16"))
        XCTAssertNil(Time.parse("last tuesday"))
    }
}

final class ConfigTests: XCTestCase {
    func testMissingFileYieldsUsableDefaults() {
        let config = ConfigStore.load(from: URL(fileURLWithPath: "/tmp/definitely-not-here"))
        XCTAssertEqual(config.anchorBalance, 0)
        XCTAssertNil(config.anchorTime)
        XCTAssertEqual(config.lowThreshold, 3.0)
        XCTAssertEqual(config.notifyPercent, [70, 90])
        XCTAssertFalse(config.isAnchored)
    }

    func testGarbageValuesAreClampedNotTrusted() {
        var config = FireworksConfig()
        config.historyDays = 400
        config.refreshSeconds = 1
        config.notifyPercent = [0, 150, 70, 70]
        config.normalise()
        XCTAssertEqual(config.historyDays, 31)
        XCTAssertEqual(config.refreshSeconds, 30)
        XCTAssertEqual(config.notifyPercent, [70])
    }

    func testTheAccountFieldExplainsItselfInBothStates() {
        // Blank is the normal setting, and the note says which account the key
        // resolved — the question an empty optional field raises.
        XCTAssertEqual(FireworksConfig.accountHint(configured: "", resolved: ""),
                       "Blank is normal — the app asks the key which account it can see.")
        let detected = FireworksConfig.accountHint(configured: "", resolved: "f12057")
        XCTAssertTrue(detected.contains("found f12057"), detected)
        let pinned = FireworksConfig.accountHint(configured: "f12057", resolved: "f12057")
        XCTAssertTrue(pinned.contains("Set to f12057"), pinned)
        XCTAssertTrue(pinned.contains("Clear the field"), pinned)
    }

    func testThePaceHorizonSurvivesGarbageAndOff() {
        var config = FireworksConfig()
        XCTAssertEqual(config.paceHorizonDays, 3)          // the default the panel uses
        config.paceHorizonDays = 400
        config.normalise()
        XCTAssertEqual(config.paceHorizonDays, 90)
        config.paceHorizonDays = -5
        config.normalise()
        XCTAssertEqual(config.paceHorizonDays, 0)          // 0 is a setting, not a mistake
    }

    func testPercentCleaningFallsBackRatherThanDisarmingAlerts() {
        XCTAssertEqual(FireworksConfig.cleanPercents([]), [70, 90])
        XCTAssertEqual(FireworksConfig.cleanPercents([90, 70]), [70, 90])
        XCTAssertEqual(FireworksConfig.cleanPercents([100, -3]), [70, 90])
    }

    func testEveryTenWidensTheWindows() {
        var config = FireworksConfig()
        XCTAssertEqual(config.effectiveThresholds, [70, 90])
        config.notifyEveryTen = true
        XCTAssertEqual(config.effectiveThresholds, [10, 20, 30, 40, 50, 60, 70, 80, 90])
    }

    func testReadsThePluginsSnakeCaseFileWithItsIsoDates() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {"anchor_balance": 6.0, "anchor_time": "2026-09-16T00:00:00-04:00",
         "account": "f12057", "history_days": 14, "notify_percent": [50, 80]}
        """
        try Data(json.utf8).write(to: ConfigStore.url(in: directory))
        let config = ConfigStore.load(from: directory)
        XCTAssertEqual(config.anchorBalance, 6.0)
        XCTAssertEqual(config.account, "f12057")
        XCTAssertEqual(config.historyDays, 14)
        XCTAssertEqual(config.notifyPercent, [50, 80])
        XCTAssertEqual(config.anchorTime, date(2026, 9, 16, 0, 0, zone: TimeZone(secondsFromGMT: -4 * 3600)!))
        XCTAssertTrue(config.isAnchored)
    }

    func testRoundTripsThroughDisk() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        var config = FireworksConfig()
        config.anchorBalance = 11.21
        config.anchorTime = date(2026, 9, 25, 13, 30)
        config.notifyPercent = [60, 85]
        try ConfigStore.save(config, to: directory)
        let reloaded = ConfigStore.load(from: directory)
        XCTAssertEqual(reloaded.anchorBalance, 11.21)
        XCTAssertEqual(reloaded.notifyPercent, [60, 85])
        XCTAssertEqual(reloaded.anchorTime, config.anchorTime)
    }

    func testACorruptFileDoesNotTakeTheAppDown() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: ConfigStore.url(in: directory))
        XCTAssertEqual(ConfigStore.load(from: directory).anchorBalance, 0)
    }
}

final class AlertTests: XCTestCase {
    var config = FireworksConfig()

    override func setUp() {
        config = FireworksConfig()
        config.anchorBalance = 6.0
        config.anchorTime = date(2026, 9, 16, 0, 0)
        config.lowThreshold = 1.00
        config.criticalThreshold = 0.50
    }

    func reading(_ remaining: Double, anchor: Double = 6.0,
                 anchorTime: Date? = nil, spend: Double? = nil,
                 credited: Double? = nil, cycle: Double? = nil,
                 creditAdded: Double? = nil) -> Reading {
        Reading(remaining: remaining,
                spend: spend ?? (anchor - remaining),
                today: 0, models: [:], days: [],
                hours: 17, hoursToday: 6,
                anchorBalance: anchor,
                anchorTime: anchorTime ?? config.anchorTime!,
                fetchedAt: date(2026, 9, 17, 16, 30),
                credited: credited, cycleBalance: cycle, creditAdded: creditAdded)
    }

    func memory(_ fired: [String: Int] = [:], anchor: Double? = 6.0,
                when: Date? = nil) -> AlertMemory {
        AlertMemory(fired: fired, anchorBalance: anchor,
                    anchorTime: when ?? config.anchorTime)
    }

    func testThePaceBadgeDrawsTheLineAtTheHorizon() {
        // $6.80 across the 17-hour window is $9.60/day, so $28 of credit is 2.9
        // days and $30 is 3.1: the horizon is the line the badge sits on, and it
        // is the only mark the tile makes.
        let tight = reading(28.0, anchor: 40.0, spend: 6.8)
        XCTAssertEqual(tight.dailyRate, 9.6, accuracy: 0.01)
        XCTAssertEqual(tight.daysLeft!, 2.917, accuracy: 0.01)
        XCTAssertTrue(tight.paceIsTight(horizonDays: 3))
        XCTAssertFalse(tight.paceIsTight(horizonDays: 2))
        XCTAssertFalse(tight.paceIsTight(horizonDays: 0))     // 0 turns the mark off
        XCTAssertFalse(reading(30.0, anchor: 40.0, spend: 6.8).paceIsTight(horizonDays: 3))
        // nothing spent yet is no rate at all, and no rate is not a tight forecast
        XCTAssertFalse(reading(30.0, anchor: 40.0, spend: 0).paceIsTight(horizonDays: 3))
    }

    func testACrossingWarnsOnce() {
        let state = reading(1.50)                       // 75% spent
        let (events, alertMemory) = Alerts.plan(reading: state, config: config,
                                               previous: memory())
        XCTAssertEqual(events.map(\.kind), [.spend])
        XCTAssertTrue(events[0].message.contains("70% of your credit burned"))
        XCTAssertTrue(events[0].message.contains("$1.50 left"))
        XCTAssertEqual(alertMemory.fired, ["pct:70": 1])

        let (again, _) = Alerts.plan(reading: state, config: config, previous: alertMemory)
        XCTAssertTrue(again.isEmpty)                    // already said
    }

    func testTheHighestNewCrossingIsTheOneReported() {
        let (events, alertMemory) = Alerts.plan(reading: reading(0.50), config: config,
                                               previous: memory())
        XCTAssertEqual(events.map(\.kind), [.spend, .critical])
        XCTAssertTrue(events[0].message.contains("90% of your credit burned"))
        XCTAssertEqual(alertMemory.fired, ["pct:70": 1, "pct:90": 1,
                                           "usd:critical": 1, "usd:low": 1])
    }

    func testAFirstRunSeedsSilently() {
        let (events, alertMemory) = Alerts.plan(reading: reading(1.50), config: config,
                                               previous: nil)
        XCTAssertTrue(events.isEmpty)                   // no install-time burst
        XCTAssertEqual(alertMemory.fired, ["pct:70": 1])

        let (next, _) = Alerts.plan(reading: reading(0.50), config: config, previous: alertMemory)
        XCTAssertEqual(next.map(\.kind), [.spend, .critical])
    }

    func testATopUpIsAnnouncedAndReArmsTheThresholds() {
        // Money in the ledger from one refresh to the next IS the top-up: it refills
        // the cycle, so the thresholds below the new figure can warn again.
        let (events, alertMemory) = Alerts.plan(
            reading: reading(5.0, anchor: 12.0, credited: 12.0, cycle: 12.0, creditAdded: 6.0),
            config: config,
            previous: memory(["pct:70": 1, "pct:90": 1, "usd:low": 1]))
        XCTAssertEqual(events.map(\.kind), [.refill])
        XCTAssertTrue(events[0].message.contains("$6.00 more to spend"))
        XCTAssertTrue(events[0].subtitle.contains("$12.00 this cycle"))
        XCTAssertEqual(alertMemory.fired, [:])          // everything can warn again
        XCTAssertEqual(alertMemory.anchorBalance, 12.0, "keyed to the cycle, not the balance")
    }

    func testWithNoCreditAddedAStillCrossedThresholdNeitherWarnsAgainNorResets() {
        // The refresh clock is not a top-up, and neither is the window moving: a
        // threshold still crossed stays in the memory, so it warns once rather than
        // every five minutes.
        let (events, alertMemory) = Alerts.plan(
            reading: reading(1.50, anchorTime: date(2026, 9, 17, 0, 0)), config: config,
            previous: memory(["pct:70": 1]))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(alertMemory.fired, ["pct:70": 1])
    }

    func testTheLowLineWarnsOnceAndReArmsWhenCreditReturns() {
        config.lowThreshold = 3.00
        let (events, alertMemory) = Alerts.plan(reading: reading(2.00), config: config,
                                               previous: memory())
        XCTAssertEqual(events.map(\.kind), [.low])
        XCTAssertTrue(events[0].message.contains("$2.00 left of $6.00"))

        let (again, _) = Alerts.plan(reading: reading(2.00), config: config,
                                     previous: alertMemory)
        XCTAssertTrue(again.isEmpty)

        // Above the line again: nothing to say, and the threshold is armed for later
        let (after, armed) = Alerts.plan(reading: reading(4.0), config: config,
                                         previous: memory(["usd:low": 1]))
        XCTAssertTrue(after.isEmpty)
        XCTAssertNil(armed.fired["usd:low"])
    }

    func testAnOverspentAnchorReadsAsOverNotAsANegativeDollar() {
        let (events, alertMemory) = Alerts.plan(reading: reading(-0.20), config: config,
                                               previous: memory())
        let critical = events.first { $0.kind == .critical }
        XCTAssertNotNil(critical)
        XCTAssertTrue(critical!.message.contains("over the anchor by $0.20"))
        XCTAssertFalse(critical!.message.contains("$-"))
        XCTAssertEqual(alertMemory.fired["usd:critical"], 1)
    }

    func testEveryTenWidensTheWindows() {
        config.notifyEveryTen = true
        let (events, _) = Alerts.plan(reading: reading(2.4), config: config,
                                      previous: memory(["pct:50": 1]))
        XCTAssertEqual(events.map(\.kind), [.spend])
        XCTAssertTrue(events[0].message.contains("60% of your credit burned"))
    }

    func testTheArmedSummaryIsWhatTheUserSeesInSettings() {
        XCTAssertEqual(Alerts.armedSummary(config: config), "Alerts on · 70,90% of your credit")
        config.notify = false
        XCTAssertEqual(Alerts.armedSummary(config: config), "Alerts off")
    }
}

final class KeyStoreTests: XCTestCase {
    func testAcceptsAWellFormedKey() throws {
        XCTAssertEqual(try KeyStore.validate(String(repeating: "k", count: 40) + "\n",
                                             source: "the clipboard").count, 40)
    }

    func testRejectsProseInsteadOfLettingItReachTheRequest() {
        XCTAssertThrowsError(try KeyStore.validate("here is your key:\n" + String(repeating: "k", count: 30),
                                                   source: "the clipboard")) { error in
            guard let error = error as? FireworksError else { return XCTFail("wrong error") }
            XCTAssertTrue(error.isSetup)
            XCTAssertTrue(error.errorDescription!.contains("one line"))
        }
    }

    func testRejectsTheCopyPasteArrowAndShortKeys() {
        XCTAssertThrowsError(try KeyStore.validate("fw_abc→defghijklmnop", source: "x"))
        XCTAssertThrowsError(try KeyStore.validate("tooshort", source: "x"))
        XCTAssertThrowsError(try KeyStore.validate("   ", source: "x"))
    }

    func testReadsTheKeyFromTheEnvironmentWhenThereIsNoFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let key = String(repeating: "a", count: 32)
        let result = try KeyStore.read(service: nil, directory: directory,
                                       environment: [KeyStore.envVar: key])
        XCTAssertEqual(result.key, key)
        XCTAssertEqual(result.source, KeyStore.envVar)
    }

    func testAnEmptyKeyFileIsASetupProblemNotAnOutage() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("\n".utf8).write(to: directory.appendingPathComponent(KeyStore.fileName))
        XCTAssertThrowsError(try KeyStore.read(service: nil, directory: directory,
                                               environment: [KeyStore.envVar: String(repeating: "a", count: 32)])) { error in
            XCTAssertTrue((error as? FireworksError)?.isSetup == true)
        }
    }

    func testTheFileIsWrittenOwnerOnly() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let url = try KeyStore.writeFile(String(repeating: "k", count: 40), directory: directory)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(try KeyStore.read(service: nil, directory: directory,
                                         environment: [:]).key, String(repeating: "k", count: 40))
    }
}
