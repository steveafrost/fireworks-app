import XCTest
@testable import FireworksCore

/// The balance call, checked against bytes captured from the live gateway.
///
/// The fixtures are real, not invented: the request is the frame Fireworks' own
/// CLI sends, and the response is what `gateway.fireworks.ai` answered for
/// `accounts/f12057` — where `firectl account get` printed `Balance: USD 7.75`.
/// If the gateway ever changes shape, these tests have to fail rather than let
/// the app quietly render a zero.
final class BalanceTests: XCTestCase {
    /// `GetBalanceRequest{name: "accounts/f12057"}` in a gRPC frame.
    static let requestHex = "00000000110a0f6163636f756e74732f663132303537"
    /// `GetBalanceResponse{balance: Money{USD, units=7, nanos=750129467}}`.
    static let responseHex = "000000000f0a0d0a03555344100718bba2d8e502"

    static func bytes(_ hex: String) -> Data {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return Data(out) }
            out.append(byte)
            index = next
        }
        return Data(out)
    }

    func testTheRequestIsTheFrameTheCliSends() {
        XCTAssertEqual(BalanceRPC.request(account: "f12057"), Self.bytes(Self.requestHex))
    }

    func testItAsksTheGatewayTheWayTheGatewayWants() {
        let headers = BalanceRPC.requestHeaders(apiKey: "k")
        XCTAssertEqual(headers["x-api-key"], "k")
        XCTAssertEqual(headers["content-type"], "application/grpc")
        XCTAssertEqual(headers["te"], "trailers")
        XCTAssertEqual(BalanceRPC.endpoint.host, "gateway.fireworks.ai")
        XCTAssertEqual(BalanceRPC.endpoint.path, "/gateway.Gateway/GetBalance")
    }

    func testItReadsTheBalanceTheAccountActuallyHas() throws {
        let money = try XCTUnwrap(BalanceRPC.decode(Self.bytes(Self.responseHex)))
        XCTAssertEqual(money.currency, "USD")
        XCTAssertEqual(money.amount, 7.750129467, accuracy: 1e-9)
        XCTAssertEqual(Money.formatted(money.amount), "$7.75")
    }

    func testAWholeDollarBalanceNeedsNoNanos() throws {
        // Money{EUR, units=12} — the nanos field is simply absent.
        let money = try XCTUnwrap(BalanceRPC.decode(Self.bytes("00000000090a070a03455552100c")))
        XCTAssertEqual(money.currency, "EUR")
        XCTAssertEqual(money.amount, 12, accuracy: 1e-9)
    }

    func testAnEmptyReplyIsNoBalanceRatherThanZero() {
        // What an unauthorised gateway answers: HTTP 200, no message.
        XCTAssertNil(BalanceRPC.decode(Data()))
        XCTAssertNil(BalanceRPC.decode(Self.bytes("0000000000")))
        // A compressed frame carries a flag byte, not a plain message.
        XCTAssertNil(BalanceRPC.decode(Self.bytes("0100000003aabbcc")))
        // A frame that promises more than it carries.
        XCTAssertNil(BalanceRPC.decode(Self.bytes("00000000100a0d0a03555344100718")))
        // A message that is not a balance at all.
        XCTAssertNil(BalanceRPC.decode(Self.bytes("00000000020a00")))
        // Garbage that is not even a frame header.
        XCTAssertNil(BalanceRPC.decode(Self.bytes("00ff")))
    }

    func testLaterFieldsInTheEnvelopeAreIgnored() throws {
        // A gateway with more to say (an expiry, a hold) must not break the read.
        let extended = Self.bytes(Self.responseHex + "10011802")
        let money = try XCTUnwrap(BalanceRPC.decode(extended))
        XCTAssertEqual(money.amount, 7.750129467, accuracy: 1e-9)
    }

    // MARK: - the reading

    private func config(anchor: Double = 20, liveBalance: Bool = true) -> FireworksConfig {
        var config = FireworksConfig()
        config.anchorBalance = anchor
        config.anchorTime = Date(timeIntervalSince1970: 1_760_000_000)
        config.liveBalance = liveBalance
        return config
    }

    private func refresh(config: FireworksConfig, source: CostSource,
                         previous: Reading? = nil) async -> RefreshOutcome {
        await RefreshService().refresh(config: config, previous: previous, source: source,
                                       now: Date(timeIntervalSince1970: 1_760_400_000))
    }

    func testTheRealBalanceBeatsTheAnchoredEstimate() async {
        // 20 − 12.25 = 7.75, while the account really holds 7.750129467: close
        // enough to look right, far enough apart to tell the two apart. The
        // reading stores six places, so that is the accuracy asserted here.
        let outcome = await refresh(config: config(),
                                    source: FakeSource(total: 12.25, today: 1.0,
                                                       live: 7.750129467))
        XCTAssertEqual(outcome.reading?.remaining ?? 0, 7.750129467, accuracy: 1e-6)
        XCTAssertEqual(outcome.reading?.liveBalance ?? 0, 7.750129467, accuracy: 1e-6)
        XCTAssertEqual(outcome.reading?.isEstimated, false)
        // Spending is still the rated cost of the window — the balance replaces
        // the subtraction, not the measurement.
        XCTAssertEqual(outcome.reading?.spend ?? 0, 12.25, accuracy: 1e-9)
    }

    func testAGatewayThatCannotBeReachedFallsBackToTheAnchor() async throws {
        let outcome = await refresh(config: config(),
                                    source: FakeSource(total: 12.25, today: 1.0,
                                                       liveFailure: FireworksError(
                                                        kind: .transport("no gateway"))))
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertEqual(reading.remaining, 7.75, accuracy: 1e-9)
        XCTAssertNil(reading.liveBalance)
        XCTAssertTrue(reading.isEstimated)
        // An unreachable gateway is not a failed refresh: the estimate stands.
        XCTAssertNil(outcome.error)
        XCTAssertFalse(outcome.isStale)
    }

    func testTurningTheLiveBalanceOffNeverCallsTheGateway() async {
        final class Counting: CostSource, @unchecked Sendable {
            var balanceCalls = 0
            func totalSpend(from start: Date, to end: Date) async throws -> CostWindow {
                CostWindow(subtotal: 4.0)
            }
            func costs(start: Date, end: Date, groupBy: [String]) async throws -> CostWindow {
                CostWindow(subtotal: 0.5)
            }
            func balance() async throws -> CreditBalance {
                balanceCalls += 1
                return CreditBalance(amount: 1)
            }
        }
        let source = Counting()
        let outcome = await refresh(config: config(liveBalance: false), source: source)
        XCTAssertEqual(source.balanceCalls, 0)
        XCTAssertEqual(outcome.reading?.remaining ?? 0, 16.0, accuracy: 1e-9)
        XCTAssertTrue(outcome.reading?.isEstimated ?? false)
    }

    func testAStoredReadingKeepsWhichFigureItWas() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fireworks-balance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let reading = Reading(remaining: 7.750129467, spend: 12.25, today: 1.0, models: [:],
                              days: [], hours: 10, hoursToday: 5, anchorBalance: 20,
                              anchorTime: Date(timeIntervalSince1970: 1_760_000_000),
                              fetchedAt: Date(timeIntervalSince1970: 1_760_400_000),
                              liveBalance: 7.750129467)
        XCTAssertTrue(ReadingStore.save(reading, to: directory))
        let loaded = try XCTUnwrap(ReadingStore.load(from: directory))
        XCTAssertEqual(loaded.liveBalance ?? 0, 7.750129467, accuracy: 1e-6)
        XCTAssertFalse(loaded.isEstimated)

        // A cache written before the balance existed still loads — as an estimate.
        let older = #"{"remaining": 4.74, "spend": 1.26, "today": 0.42, "models": {}, "days": [], "#
            + #""hours": 10, "hours_today": 5, "anchor_balance": 6, "#
            + #""anchor_time": "2026-09-25T13:30:00Z", "fetched_at": "2026-09-29T15:41:00Z"}"#
        try Data(older.utf8).write(to: ReadingStore.url(in: directory), options: .atomic)
        let back = try XCTUnwrap(ReadingStore.load(from: directory))
        XCTAssertNil(back.liveBalance)
        XCTAssertTrue(back.isEstimated)
        XCTAssertEqual(back.remaining, 4.74, accuracy: 1e-9)
    }

    func testTheSettingDefaultsOnAndCanBeTurnedOff() throws {
        XCTAssertTrue(FireworksConfig().liveBalance)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let off = try decoder.decode(FireworksConfig.self,
                                     from: Data(#"{"live_balance": false}"#.utf8))
        XCTAssertFalse(off.liveBalance)
    }

    func testTheBalanceToggleExplainsItselfInBothStates() {
        // The settings pane is a `Form`, which the offscreen renderer draws as
        // nothing, so this copy is checked here rather than by looking at it.
        XCTAssertTrue(FireworksConfig.balanceSourceHint(live: true).contains("gateway"))
        XCTAssertTrue(FireworksConfig.balanceSourceHint(live: false).contains("anchor"))
        XCTAssertNotEqual(FireworksConfig.balanceSourceHint(live: true),
                          FireworksConfig.balanceSourceHint(live: false))
    }

    func testThePopoverSaysWhichFigureItIsShowing() {
        // The popover cannot be screenshotted on this Mac, so the footnote it
        // draws is asserted here: the time, and the one word that keeps an
        // estimate from reading as something Fireworks reported.
        let measuredAt = Date(timeIntervalSince1970: 1_760_400_000)
        let anchored = Reading(remaining: 4.74, spend: 1.26, today: 0.42, models: [:],
                               days: [], hours: 10, hoursToday: 5, anchorBalance: 6,
                               anchorTime: Date(timeIntervalSince1970: 1_760_000_000),
                               fetchedAt: measuredAt)
        XCTAssertTrue(anchored.isEstimated)
        XCTAssertEqual(anchored.footnote(), "Last updated: \(Time.clock(measuredAt)) · estimate")

        var live = anchored
        live.liveBalance = anchored.remaining
        XCTAssertFalse(live.isEstimated)
        XCTAssertEqual(live.footnote(), "Last updated: \(Time.clock(measuredAt))")
        XCTAssertFalse(live.footnote().contains("estimate"))
    }

    /// A source that behaves like the API does about a zero-length window: it
    /// refuses one outright, which is exactly what `HTTP 400 validation failed`
    /// was, live, when a first run adopted its own balance as the anchor.
    private final class RefusesEmptyWindow: CostSource, @unchecked Sendable {
        func totalSpend(from start: Date, to end: Date) async throws -> CostWindow {
            guard end.timeIntervalSince(start) >= RefreshService.minimumWindow else {
                throw FireworksError(kind: .http(400, "validation failed"))
            }
            return CostWindow(subtotal: 1.0)
        }
        func costs(start: Date, end: Date, groupBy: [String]) async throws -> CostWindow {
            guard end.timeIntervalSince(start) >= RefreshService.minimumWindow else {
                throw FireworksError(kind: .http(400, "validation failed"))
            }
            return CostWindow(subtotal: 0.25)
        }
        func balance() async throws -> CreditBalance { CreditBalance(amount: 7.61) }
    }

    private func anchored(now: Date, minutesAgo: Double = 0) -> FireworksConfig {
        var config = FireworksConfig()
        config.anchorBalance = 7.61
        config.anchorTime = now.addingTimeInterval(-minutesAgo * 60)
        return config
    }

    func testAnAnchorAdoptedJustNowStillMakesAReading() async throws {
        let now = Date(timeIntervalSince1970: 1_760_400_000)
        let outcome = await RefreshService().refresh(config: anchored(now: now), previous: nil,
                                                     source: RefusesEmptyWindow(), now: now)
        XCTAssertNil(outcome.error)
        let reading = try XCTUnwrap(outcome.reading)
        XCTAssertEqual(reading.spend, 0, accuracy: 1e-9)
        // Today's window is not the anchor's: it is still measured, so the guard
        // swallows exactly the impossible query and nothing else.
        XCTAssertEqual(reading.today, 0.25, accuracy: 1e-9)
        XCTAssertEqual(reading.remaining, 7.61, accuracy: 1e-9)
        XCTAssertEqual(reading.liveBalance ?? 0, 7.61, accuracy: 1e-9)
    }

    func testTheSpendIsMeasuredOnceTheWindowIsReal() async throws {
        // Five minutes after the same anchor the window is real, so the guard
        // must not be swallowing measurements — only the impossible ones.
        let now = Date(timeIntervalSince1970: 1_760_400_000)
        let outcome = await RefreshService().refresh(config: anchored(now: now, minutesAgo: 5),
                                                     previous: nil,
                                                     source: RefusesEmptyWindow(), now: now)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(try XCTUnwrap(outcome.reading).spend, 1.0, accuracy: 1e-9)
    }
}
