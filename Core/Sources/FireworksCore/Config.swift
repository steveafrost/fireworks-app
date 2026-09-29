import Foundation

/// Where a settings file lives, and what an unreadable one means.
///
/// The app and the plugin read the *same* file when they share a Mac: a user
/// migrating from the SwiftBar plugin keeps their anchor, thresholds and alert
/// history instead of re-entering them. Only the storage location differs
/// (App Group container for the sandbox-free app, dotfile for the plugin).
public enum SettingsLocation {
    public static let fileName = "config.json"
}

public enum AppGroup {
    /// Shared between the app and its widget extensions. Widgets cannot read the
    /// app's container, and neither can they reliably make network calls on a
    /// timeline budget, so the app writes a snapshot here and the widget reads it.
    public static let identifier = "group.com.whitebox.fireworks"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Everything the user can set, with the defaults in one place.
public struct FireworksConfig: Codable, Sendable, Equatable {
    /// Blank = discover it from the API key via `GET /v1/accounts`.
    public var account: String = ""
    /// The balance held at `anchorTime` — the figure the remaining amount is
    /// measured down from, because the API cannot report a balance itself.
    public var anchorBalance: Double = 0
    public var anchorTime: Date?
    /// The title turns amber/red at these amounts, and they drive the
    /// low/critical alerts.
    public var lowThreshold: Double = 3.00
    public var criticalThreshold: Double = 1.00
    /// Days in the daily breakdown, sparkline, chart and the "Last Nd" total.
    public var historyDays: Int = 7
    /// How close the forecast has to get before the pace tile earns its fire.
    /// 0 turns the mark off.
    public var paceHorizonDays: Int = 3
    /// How often the app re-measures, in seconds (widgets get their own budget).
    public var refreshSeconds: Int = 300
    /// Desktop/iOS alerts on threshold crossings.
    public var notify: Bool = true
    /// The crossings to warn on, as a share of the anchor already *spent*.
    public var notifyPercent: [Int] = [70, 90]
    /// Warn at every 10% instead of only `notifyPercent`.
    public var notifyEveryTen: Bool = false

    public enum CodingKeys: String, CodingKey {
        case account
        case anchorBalance = "anchor_balance"
        case anchorTime = "anchor_time"
        case lowThreshold = "low_threshold"
        case criticalThreshold = "critical_threshold"
        case historyDays = "history_days"
        case paceHorizonDays = "pace_horizon_days"
        case refreshSeconds = "refresh_seconds"
        case notify
        case notifyPercent = "notify_percent"
        case notifyEveryTen = "notify_every_10"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FireworksConfig()
        account = (try? values.decode(String.self, forKey: .account)) ?? defaults.account
        anchorBalance = (try? values.decode(Double.self, forKey: .anchorBalance))
            ?? defaults.anchorBalance
        anchorTime = try? values.decodeIfPresent(Date.self, forKey: .anchorTime)
        lowThreshold = (try? values.decode(Double.self, forKey: .lowThreshold))
            ?? defaults.lowThreshold
        criticalThreshold = (try? values.decode(Double.self, forKey: .criticalThreshold))
            ?? defaults.criticalThreshold
        historyDays = (try? values.decode(Int.self, forKey: .historyDays)) ?? defaults.historyDays
        paceHorizonDays = (try? values.decode(Int.self, forKey: .paceHorizonDays))
            ?? defaults.paceHorizonDays
        refreshSeconds = (try? values.decode(Int.self, forKey: .refreshSeconds))
            ?? defaults.refreshSeconds
        notify = (try? values.decode(Bool.self, forKey: .notify)) ?? defaults.notify
        notifyPercent = (try? values.decode([Int].self, forKey: .notifyPercent))
            ?? defaults.notifyPercent
        notifyEveryTen = (try? values.decode(Bool.self, forKey: .notifyEveryTen))
            ?? defaults.notifyEveryTen
        normalise()
    }

    /// Clamp anything a hand-edited file can get wrong, so no setting can make
    /// the app render nonsense (a 400-day history is 400 API requests a refresh).
    public mutating func normalise() {
        historyDays = min(31, max(2, historyDays))
        paceHorizonDays = min(90, max(0, paceHorizonDays))
        refreshSeconds = min(3600, max(30, refreshSeconds))
        notifyPercent = FireworksConfig.cleanPercents(notifyPercent)
    }

    public static func cleanPercents(_ raw: [Int]) -> [Int] {
        let cleaned = Set(raw.filter { (1...99).contains($0) })
        return cleaned.isEmpty ? [70, 90] : cleaned.sorted()
    }

    /// The crossings to warn on, once `notifyEveryTen` is taken into account.
    public var effectiveThresholds: [Int] {
        notifyEveryTen ? Array(stride(from: 10, to: 100, by: 10)) : notifyPercent
    }

    public var thresholdsForDisplay: String {
        effectiveThresholds.map(String.init).joined(separator: ",")
    }

    /// What the account field means, in the words the settings panel shows.
    ///
    /// Here rather than in the view because it is the only place the app explains
    /// the field, and the explanation is a rule about settings: blank means "ask
    /// the key", and anything else means "use this and do not ask". The settings
    /// pane is a `Form`, which the offscreen renderer draws as nothing, so this
    /// string is verified by test rather than by looking at a picture.
    public static func accountHint(configured: String, resolved: String) -> String {
        guard configured.isEmpty else {
            return "Set to \(configured), so the app will not ask. "
                + "Clear the field to let it work the account out from the key again."
        }
        return resolved.isEmpty
            ? "Blank is normal — the app asks the key which account it can see."
            : "Blank is normal — the app asked the key and found \(resolved). "
              + "Fill this in only if the key can see several accounts and it has to be told which one."
    }

    public var isAnchored: Bool {
        anchorBalance > 0 && anchorTime != nil
    }
}

/// Reading and writing settings, with the same "never crash on a bad file" rule
/// the rest of the app follows: a corrupt file falls back to defaults rather
/// than leaving the user with nothing.
public enum ConfigStore {
    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(SettingsLocation.fileName)
    }

    public static func load(from directory: URL) -> FireworksConfig {
        let url = url(in: directory)
        guard let data = try? Data(contentsOf: url) else { return FireworksConfig() }
        // The plugin writes snake_case keys and dates as ISO-8601 strings; accept
        // both spellings so a Mac that ran the plugin first keeps its history.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unrecognised date"))
        }
        guard var config = try? decoder.decode(FireworksConfig.self, from: data) else {
            return FireworksConfig()
        }
        config.normalise()
        return config
    }

    @discardableResult
    public static func save(_ config: FireworksConfig, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = url(in: directory)
        try encoder.encode(config).write(to: url, options: .atomic)
        return url
    }
}
