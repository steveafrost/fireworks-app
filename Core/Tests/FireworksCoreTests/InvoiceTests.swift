import XCTest
@testable import FireworksCore

/// The credit ledger: what has been paid into the account.
///
/// This is the denominator the app used to ask a human for, so it is the number
/// that has to be right — the dial, the percentage and the percent alerts are all
/// measured against it, and a wrong total is a wrong-looking balance.
final class InvoiceTests: XCTestCase {
    /// A real `ListInvoices` reply for account f12057, recorded 2026-09-29: three
    /// paid PREPAID_CREDITS invoices ($5 + $5 + $10) and one open invoice with no
    /// amount on it. Recorded rather than synthesised, because the field numbers are
    /// the thing being checked and a hand-built message would only prove the decoder
    /// agrees with itself.
    private let recordedReply = [
        "00000003230a83010a104459394a4d63777062677247464d346412050a035553441a5c687474",
        "70733a2f2f696e766f696365732e776974686f72622e636f6d2f766965773f746f6b656e3d49",
        "6d7436554656345230705a4e4546485954524d576b63692e654c2d772d737844515f37575273",
        "7466544264382d77577852464120012a060880c5f6d50638010adc0138020a1b696e5f31554a",
        "63774b4c5a59546341394946683173734f72724d4f12070a03555344100a1a9f016874747073",
        "3a2f2f696e766f6963652e7374726970652e636f6d2f692f616363745f314e5a49524b4c5a59",
        "546341394946682f6c6976655f59574e6a64463878546c704a556b744d576c6c555930453553",
        "555a6f4c463957533068575155316855566c6956466b32636b746f6258526b4e6a6875644763",
        "354e46424462576c614c4445344d5449334d5467354f4130323030306b6b72367743573f733d",
        "617020032a060881dfdad50632060881dfdad5060adc010a1b696e5f3155493945754c5a5954",
        "6341394946687061396266786a46120710050a035553441a9f0168747470733a2f2f696e766f",
        "6963652e7374726970652e636f6d2f692f616363745f314e5a49524b4c5a5954634139494668",
        "2f6c6976655f59574e6a64463878546c704a556b744d576c6c555930453553555a6f4c463957",
        "535774724d4564435448467851314a324d57567663484a4e596a6c59517a644a645642465a33",
        "4a464c4445344d5449334d5467354f41303230306a7663667352334b3f733d617020032a0608",
        "919dc5d506320608919dc5d50638020adc011a9f0168747470733a2f2f696e766f6963652e73",
        "74726970652e636f6d2f692f616363745f314e5a49524b4c5a59546341394946682f6c697665",
        "5f59574e6a64463878546c704a556b744d576c6c555930453553555a6f4c4639575344525252",
        "5568695345313164486c554d6a6c4c516b7030517a5a694e44643654317052545851324c4445",
        "344d5449334d5467354f41303230306f3069774a736d4f3f733d617020032a060897c5add506",
        "32060897c5add50638020a1b696e5f31554757484f4c5a595463413949466839673367427878",
        "7112070a035553441005",
].joined()

    // MARK: - the recorded reply

    func testAddsUpThePaidInvoices() throws {
        let ledger = try XCTUnwrap(BalanceRPC.decodeInvoices(Data(hex: recordedReply)),
                                   "the recorded reply did not decode")
        XCTAssertEqual(ledger.credited, 20.00, accuracy: 0.001)
        XCTAssertEqual(ledger.paidInvoices, 3)
        XCTAssertEqual(ledger.currency, "USD")
    }

    func testTakesTheDatesFromThePaidTimes() throws {
        let ledger = try XCTUnwrap(BalanceRPC.decodeInvoices(Data(hex: recordedReply)))
        // The three paid invoices' own timestamps, read off the reply: the newest is
        // the $10 top-up and the oldest the first $5. Asserted exactly, because a
        // decoder that picked the wrong field would still produce two plausible
        // dates in the right month.
        XCTAssertEqual(ledger.firstPaid, Date(timeIntervalSince1970: 1_789_616_791))
        XCTAssertEqual(ledger.lastPaid, Date(timeIntervalSince1970: 1_790_357_377))
    }

    // MARK: - what counts as money in

    func testAnUnpaidInvoiceIsNotCounted() {
        // An invoice that has been raised but not paid is not money in, and counting
        // it would inflate the denominator until the dial under-reported the spend.
        let reply = self.reply([invoice(id: "open", units: 50, state: 1, seconds: nil)])
        let ledger = BalanceRPC.decodeInvoices(reply)
        XCTAssertEqual(ledger?.credited, 0)
        XCTAssertEqual(ledger?.paidInvoices, 0)
    }

    func testAPaidInvoiceIsCounted() {
        let reply = self.reply([invoice(id: "paid", units: 5, state: 2, seconds: 1_790_000_000)])
        let ledger = BalanceRPC.decodeInvoices(reply)
        XCTAssertEqual(ledger?.credited, 5)
        XCTAssertEqual(ledger?.paidInvoices, 1)
        XCTAssertEqual(ledger?.lastPaid, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testSubDollarAmountsSurviveTheNanoseconds() {
        // units=0 nanos=500000000 is 50 cents, and a decoder that only read units
        // would call it zero and drop the invoice.
        var money = BalanceRPC.protobufString(field: 1, value: "USD")
        money += BalanceRPC.varint(2 << 3) + BalanceRPC.varint(0)
        money += BalanceRPC.varint(3 << 3) + BalanceRPC.varint(500_000_000)
        var invoice = BalanceRPC.protobufString(field: 1, value: "small")
        invoice += self.message(2, money)
        invoice += BalanceRPC.varint(7 << 3) + BalanceRPC.varint(2)
        let ledger = BalanceRPC.decodeInvoices(self.reply([invoice]))
        XCTAssertEqual(ledger?.credited ?? -1, 0.50, accuracy: 0.0001)
        XCTAssertEqual(ledger?.paidInvoices, 1)
    }

    func testAnAccountWithNoInvoicesIsZeroRatherThanAFailure() {
        // "Nothing bought yet" and "could not ask" mean different things to the
        // dial, so an empty list has to decode.
        let ledger = BalanceRPC.decodeInvoices(Data(BalanceRPC.framed([])))
        XCTAssertNotNil(ledger)
        XCTAssertEqual(ledger?.credited, 0)
        XCTAssertEqual(ledger?.paidInvoices, 0)
        XCTAssertNil(ledger?.firstPaid)
    }

    func testAnUnreadableReplyIsAFailureNotZero() {
        // Zero would render as "you have bought nothing", which is a claim.
        XCTAssertNil(BalanceRPC.decodeInvoices(Data()))
        XCTAssertNil(BalanceRPC.decodeInvoices(Data([0x01, 0, 0, 0, 3, 1, 2, 3])))  // compressed flag
        XCTAssertNil(BalanceRPC.decodeInvoices(Data([0x00, 0, 0, 0, 200, 1, 2])))    // truncated
        // An empty frame is a valid empty message — the server answering "there are
        // no invoices" — so it decodes to zero rather than failing.
        XCTAssertEqual(BalanceRPC.decodeInvoices(Data([0x00, 0, 0, 0, 0]))?.paidInvoices, 0)
    }

    // MARK: - building replies

    private func reply(_ invoices: [[UInt8]]) -> Data {
        Data(BalanceRPC.framed(invoices.flatMap { message(1, $0) }))
    }

    private func invoice(id: String, units: UInt64, state: UInt64, seconds: UInt64?) -> [UInt8] {
        var out = BalanceRPC.protobufString(field: 1, value: id)
        var money = BalanceRPC.protobufString(field: 1, value: "USD")
        money += BalanceRPC.varint(2 << 3) + BalanceRPC.varint(units)
        out += message(2, money)
        if let seconds {
            out += message(5, BalanceRPC.varint(1 << 3) + BalanceRPC.varint(seconds))
        }
        out += BalanceRPC.varint(7 << 3) + BalanceRPC.varint(state)
        return out
    }

    private func message(_ number: Int, _ body: [UInt8]) -> [UInt8] {
        BalanceRPC.varint(UInt64(number << 3 | 2)) + BalanceRPC.varint(UInt64(body.count)) + body
    }
}

private extension Data {
    /// Hex from a recorded reply. Tolerates whitespace so the fixture can be wrapped.
    init(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex, let next = digits.index(index, offsetBy: 2, limitedBy: digits.endIndex) {
            bytes.append(UInt8(digits[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}