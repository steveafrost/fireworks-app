import Foundation

/// A fetch that did not produce usable data.
public struct FireworksError: Error, LocalizedError, Sendable {
    public enum Kind: Sendable {
        case http(Int, String)
        case transport(String)
        case badKey(String)
        /// The user still has to supply something — never shown as an outage,
        /// and never allowed to fall back to a stale reading.
        case setup(String)
    }

    public let kind: Kind

    public var errorDescription: String? {
        switch kind {
        case .http(let code, let detail):
            return detail.isEmpty ? "HTTP \(code)" : "HTTP \(code) \(detail)"
        case .transport(let text): return text
        case .badKey(let text): return text
        case .setup(let text): return text
        }
    }

    public var isSetup: Bool {
        if case .setup = kind { return true }
        return false
    }
}

/// One window of rated spend, cut the way the API groups it.
public struct CostWindow: Sendable, Equatable {
    public var subtotal: Double = 0
    public var models: [String: Double] = [:]
    public var days: [String: Double] = [:]

    public init(subtotal: Double = 0, models: [String: Double] = [:], days: [String: Double] = [:]) {
        self.subtotal = subtotal
        self.models = models
        self.days = days
    }
}

/// The one endpoint that returns real dollars.
///
/// `GET /billing/summary` answers with empty line items and `billingUsage`
/// reports `costNanoUsd: 0`; balance-shaped endpoints do not exist at all
/// (re-measured against the live API: `billing/summary`, `billing/balance`,
/// `balance`, `credits`, `billing/usage` all 404). So rated cost is the only
/// figure there is, and the anchor subtraction is what turns it into a balance.
public actor FireworksClient {
    public static let apiRoot = URL(string: "https://api.fireworks.ai/v1/accounts")!
    /// A single request may not span more than 31 days.
    public static let maxWindowDays = 31
    private static let maxPages = 20

    private let apiKey: String
    public private(set) var account: String
    private let session: URLSession

    public init(apiKey: String, account: String = "", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.account = account
        self.session = session
    }

    /// Account ids this key can see, with the `accounts/` prefix removed.
    public func accounts() async throws -> [String] {
        let payload = try await get(Self.apiRoot)
        let rows = (payload["accounts"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return name.components(separatedBy: "/").last
        }
    }

    /// The configured account, or the only one the key can see.
    public func resolvedAccount() async throws -> String {
        if !account.isEmpty { return account }
        let found: [String]
        do {
            found = try await accounts()
        } catch let error as FireworksError {
            throw FireworksError(kind: .setup(
                "Could not work out which Fireworks account this key belongs to "
                + "(\(error.errorDescription ?? "unknown error")) — set the account id in Settings"))
        }
        guard let first = found.first else {
            throw FireworksError(kind: .setup("This API key has no accounts attached to it"))
        }
        guard found.count == 1 else {
            throw FireworksError(kind: .setup(
                "This key can see \(found.count) accounts (\(found.joined(separator: ", "))) — "
                + "choose one in Settings"))
        }
        return first
    }

    /// Rated cost over a window. Paginated, and never double counted: when rows
    /// arrive the rows are the truth, because a multi-page subtotal would be
    /// counted once per page.
    public func costs(start: Date, end: Date, groupBy: [String] = ["MODEL"]) async throws -> CostWindow {
        var body: [String: Any] = [
            "startTime": Time.isoUTC(start),
            "endTime": Time.isoUTC(end),
            "groupBy": groupBy,
            "scope": "ACCOUNT",
            "pageSize": 1000
        ]
        var window = CostWindow()
        var pages = 0
        while true {
            let payload = try await post("usageCosts:query", body: body)
            let rows = (payload["rows"] as? [[String: Any]]) ?? []
            for row in rows {
                let dimensions = (row["dimensions"] as? [String: Any]) ?? [:]
                let cost = Money.parse(json: row["subtotal"])
                if let model = dimensions["model"] as? String {
                    window.models[model, default: 0] += cost
                }
                if let day = dimensions["startTime"] as? String {
                    window.days[String(day.prefix(10)), default: 0] += cost
                }
            }
            if rows.isEmpty && pages == 0 {
                window.subtotal += Money.parse(json: payload["subtotal"])
            }
            pages += 1
            guard let token = payload["nextPageToken"] as? String, !token.isEmpty,
                  pages < Self.maxPages else { break }
            body["pageToken"] = token
        }
        if !window.models.isEmpty {
            window.subtotal = window.models.values.reduce(0, +)
        } else if !window.days.isEmpty {
            window.subtotal = window.days.values.reduce(0, +)
        }
        return window
    }

    /// Rated spend over `[start, end]`, chunked to respect the 31-day limit.
    public func totalSpend(from start: Date, to end: Date) async throws -> CostWindow {
        var total = CostWindow()
        for (chunkStart, chunkEnd) in Time.chunkWindow(start: start, end: end) {
            let part = try await costs(start: chunkStart, end: chunkEnd)
            total.subtotal += part.subtotal
            for (model, cost) in part.models {
                total.models[model, default: 0] += cost
            }
        }
        return total
    }

    // MARK: - transport

    private func get(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = Self.apiRoot.appendingPathComponent(account).appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        // A key with a stray newline or a pasted arrow must not reach the header
        // as an encoding failure — it is a setup problem, and saying so is the
        // difference between "fix your key" and an unreadable crash.
        guard apiKey.unicodeScalars.allSatisfy({ $0.isASCII }),
              !apiKey.contains(where: { $0.isWhitespace }) else {
            throw FireworksError(kind: .badKey(
                "The API key contains a character that cannot be sent in a request — "
                + "re-copy just the key"))
        }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                throw FireworksError(kind: .badKey("Fireworks rejected the API key (HTTP \(code))"))
            }
            guard (200..<300).contains(code) else {
                let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
                throw FireworksError(kind: .http(code, message ?? ""))
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw FireworksError(kind: .http(code, "the response was not JSON"))
            }
            return object
        } catch let error as FireworksError {
            throw error
        } catch {
            throw FireworksError(kind: .transport("\(type(of: error)): \(error.localizedDescription)"))
        }
    }
}
