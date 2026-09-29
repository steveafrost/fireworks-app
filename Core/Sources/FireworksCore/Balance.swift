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
              let units = Proto.varint(named: 2, in: money) else { return nil }
        let nanos = Proto.varint(named: 3, in: money).map { Int64(bitPattern: $0) } ?? 0
        return (Double(Int64(bitPattern: units)) + Double(nanos) / 1_000_000_000,
                Proto.string(named: 1, in: money) ?? "USD")
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
        guard length > 0, bytes.count >= 5 + length else { return nil }
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
