import Foundation

/// The balance the account actually holds, as Fireworks' own tooling reports it.
public struct CreditBalance: Sendable, Equatable {
    public let amount: Double
    public let currency: String
    public let fetchedAt: Date

    public init(amount: Double, currency: String = "USD", fetchedAt: Date = Date()) {
        self.amount = amount
        self.currency = currency
        self.fetchedAt = fetchedAt
    }
}

/// What has been paid *into* the account, from the invoices the gateway lists.
///
/// This is the denominator the app used to ask a human for. The balance alone says
/// how much is left but not out of what — a ring, a percentage and a "warn at 70%"
/// all need to know the size of the thing being spent. `ListInvoices` returns the
/// prepaid top-ups that were actually paid ($5 + $5 + $10 for this account), so
/// "how much of what I bought is left" needs no hand-entered anchor and cannot
/// drift the way one does: a top-up raises the denominator by itself.
public struct CreditLedger: Codable, Sendable, Equatable {
    /// The sum of the paid invoices.
    public let credited: Double
    /// How many paid invoices that sum came from, so a surprising total can be
    /// traced back to the invoices it was added up from.
    public let paidInvoices: Int
    public let firstPaid: Date?
    public let lastPaid: Date?
    public let currency: String
    public let fetchedAt: Date

    public init(credited: Double, paidInvoices: Int, firstPaid: Date? = nil, lastPaid: Date? = nil,
                currency: String = "USD", fetchedAt: Date = Date()) {
        self.credited = credited
        self.paidInvoices = paidInvoices
        self.firstPaid = firstPaid
        self.lastPaid = lastPaid
        self.currency = currency
        self.fetchedAt = fetchedAt
    }
}

/// Reads the account balance off the control-plane gateway the vendor's CLI uses.
///
/// There is no REST route for it. `GET /v1/accounts/{id}/balance` answers 404,
/// `billing/balance` and `credits` likewise, and the account object the REST API
/// returns carries no balance field — which is why this app has been measuring
/// remaining credit as `anchor − rated spend` with a hand-entered anchor.
///
/// The figure does exist. `firectl account get` prints `Balance: USD 7.75`, and
/// firectl is a *gRPC* client, so the number comes from
/// `gateway.Gateway/GetBalance` on `gateway.fireworks.ai`, authenticated with
/// the same API key in an `x-api-key` header. Speaking that call needs no gRPC
/// library and no generated protos: it is HTTP/2 — which `URLSession` already
/// speaks — and the message is two fields wide.
public enum BalanceRPC {
    public static let endpoint = URL(string: "https://gateway.fireworks.ai/gateway.Gateway/GetBalance")!
    public static let invoiceEndpoint = URL(string: "https://gateway.fireworks.ai/gateway.Gateway/ListInvoices")!

    /// The invoice state that means the money actually arrived. The account's only
    /// other invoice is state 1 with a zero amount on it — an open invoice, which is
    /// not money in, and counting it would inflate the denominator the dial uses.
    static let paidInvoiceState: UInt64 = 2

    public static func requestHeaders(apiKey: String) -> [String: String] {
        [
            "x-api-key": apiKey,
            "content-type": "application/grpc",
            "te": "trailers",
        ]
    }

    /// `GetBalanceRequest{ name: "accounts/<id>" }` in gRPC's length-prefixed frame.
    public static func request(account: String) -> Data {
        Data(framed(protobufString(field: 1, value: "accounts/\(account)")))
    }

    /// `GetBalanceResponse{ balance: Money{ currency_code, units, nanos } }`.
    ///
    /// Nil for anything that is not that shape: an unreadable figure has to read
    /// as "no balance", because 0 would render as a spent-out account.
    public static func decode(_ data: Data) -> (amount: Double, currency: String)? {
        guard let message = unframed(data),
              let money = Proto.message(named: 1, in: message),
              let value = amount(in: money) else { return nil }
        return (value, Proto.string(named: 1, in: money) ?? "USD")
    }

    /// `ListInvoicesRequest{ name: "accounts/<id>" }` — the same message shape as
    /// the balance call, and the same frame.
    public static func invoiceRequest(account: String) -> Data {
        Data(framed(protobufString(field: 1, value: "accounts/\(account)")))
    }

    /// `ListInvoicesResponse{ invoices: repeated Invoice }`.
    ///
    /// The invoice fields, read off the gateway rather than assumed: 1 = id,
    /// 2 = Money (the same two-field shape the balance uses), 5 = `{1: seconds}`
    /// issued, 6 = `{1: seconds}` paid, 7 = state. Checked against
    /// `firectl billing list-invoices`, which reports the same three PAID
    /// PREPAID_CREDITS invoices this adds up to $20.00.
    ///
    /// Nil only when the reply is not a frame at all. An account that has never
    /// topped up genuinely has no paid invoices, and that has to arrive as a ledger
    /// of zero rather than as a failure: "nothing bought yet" and "could not ask"
    /// mean different things to the dial.
    public static func decodeInvoices(_ data: Data) -> CreditLedger? {
        guard let message = unframed(data) else { return nil }
        var credited = 0.0
        var paid = 0
        var dates: [Date] = []
        var currency = "USD"
        for invoice in Proto.all(named: 1, in: message) {
            guard Proto.varint(named: 7, in: invoice) == paidInvoiceState,
                  let money = Proto.message(named: 2, in: invoice),
                  let value = amount(in: money), value > 0 else { continue }
            credited += value
            paid += 1
            currency = Proto.string(named: 1, in: money) ?? currency
            // Paid when the gateway says so, issued otherwise: one date for every
            // invoice counted, so the range covers exactly what was added up.
            let seconds = Proto.message(named: 6, in: invoice).flatMap { Proto.varint(named: 1, in: $0) }
                ?? Proto.message(named: 5, in: invoice).flatMap { Proto.varint(named: 1, in: $0) }
            if let seconds {
                dates.append(Date(timeIntervalSince1970: TimeInterval(seconds)))
            }
        }
        return CreditLedger(credited: credited, paidInvoices: paid,
                            firstPaid: dates.min(), lastPaid: dates.max(), currency: currency)
    }

    /// A `Money` message as a number: units plus nanos. One arithmetic path for
    /// money, because the balance and an invoice amount are the same type.
    static func amount(in money: [UInt8]) -> Double? {
        guard let units = Proto.varint(named: 2, in: money) else { return nil }
        let nanos = Proto.varint(named: 3, in: money).map { Int64(bitPattern: $0) } ?? 0
        return Double(Int64(bitPattern: units)) + Double(nanos) / 1_000_000_000
    }

    // MARK: - framing

    static func framed(_ message: [UInt8]) -> [UInt8] {
        let length = UInt32(message.count)
        return [0x00,
                UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                UInt8((length >> 8) & 0xff), UInt8(length & 0xff)] + message
    }

    /// The payload of the first frame. Nil when the message arrived compressed
    /// (the flag byte is not `0x00`) or the frame is short or truncated.
    static func unframed(_ data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5, bytes[0] == 0x00 else { return nil }
        let length = Int(bytes[1]) << 24 | Int(bytes[2]) << 16
            | Int(bytes[3]) << 8 | Int(bytes[4])
        // `length` of 0 is a legitimate protobuf message with no fields set — the
        // server answering "there is nothing here" — so only a frame that cannot
        // hold what it claims to hold is rejected.
        guard bytes.count >= 5 + length else { return nil }
        return Array(bytes[5..<(5 + length)])
    }

    static func protobufString(field: Int, value: String) -> [UInt8] {
        let utf8 = Array(value.utf8)
        return varint((UInt64(field) << 3) | 2) + varint(UInt64(utf8.count)) + utf8
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var out: [UInt8] = []
        repeat {
            let byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            out.append(remaining == 0 ? byte : byte | 0x80)
        } while remaining != 0
        return out
    }
}

/// Just enough protobuf to read a two-field money message: no library, no
/// generated types, and no assumption that the fields arrive in order.
enum Proto {
    struct Field {
        let number: Int
        let wire: Int
        let bytes: [UInt8]
        let varint: UInt64
    }

    static func walk(_ message: [UInt8]) -> [Field] {
        var fields: [Field] = []
        var index = 0
        while index < message.count {
            guard let (tag, afterTag) = read(message, from: index) else { break }
            index = afterTag
            let number = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            switch wire {
            case 0:
                guard let (value, next) = read(message, from: index) else { return fields }
                fields.append(Field(number: number, wire: wire, bytes: [], varint: value))
                index = next
            case 2:
                guard let (length, start) = read(message, from: index) else { return fields }
                let end = start + Int(length)
                guard end <= message.count else { return fields }
                fields.append(Field(number: number, wire: wire,
                                    bytes: Array(message[start..<end]), varint: 0))
                index = end
            case 5:
                index += 4
            case 1:
                index += 8
            default:
                // Groups and anything unknown: stop rather than guess.
                return fields
            }
        }
        return fields
    }

    static func string(named: Int, in message: [UInt8]) -> String? {
        guard let field = walk(message).first(where: { $0.number == named && $0.wire == 2 })
        else { return nil }
        return String(bytes: field.bytes, encoding: .utf8)
    }

    static func varint(named: Int, in message: [UInt8]) -> UInt64? {
        walk(message).first { $0.number == named && $0.wire == 0 }?.varint
    }

    static func message(named: Int, in message: [UInt8]) -> [UInt8]? {
        walk(message).first { $0.number == named && $0.wire == 2 }?.bytes
    }

    /// Every length-delimited field with this number, in the order they arrived —
    /// which is how protobuf carries a repeated message.
    static func all(named: Int, in message: [UInt8]) -> [[UInt8]] {
        walk(message).filter { $0.number == named && $0.wire == 2 }.map(\.bytes)
    }

    private static func read(_ bytes: [UInt8], from start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift = 0
        var index = start
        while index < bytes.count, shift <= 63 {
            let byte = bytes[index]
            value |= UInt64(byte & 0x7f) << shift
            index += 1
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
        }
        return nil
    }
}
