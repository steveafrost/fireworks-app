import Foundation

/// The two Info.plist keys Sparkle reads, and the validation they need.
///
/// A wrong `SUPublicEDKey` does not fail at launch. It fails the *next* update,
/// and then every one after it: Sparkle rejects the download's signature and the
/// app quietly never updates again. That is the worst failure shape there is, so
/// the key is checked once at launch — base64 that decodes to the 32 bytes
/// Ed25519 requires — and Settings says so when it does not.
public enum UpdateFeed {
    public static let feedKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"

    /// Ed25519 public keys are 32 bytes.
    public static let publicKeyBytes = 32

    /// The appcast URL, or nil if it is missing or is not something Sparkle can
    /// fetch. https only: an update feed over plain http is an update feed
    /// anyone on the network can rewrite.
    public static func url(in info: [String: Any]) -> URL? {
        guard let raw = info[feedKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              !trimmed.hasSuffix("/") else { return nil }
        return url
    }

    /// The signing key, if it is the right shape. Returned trimmed, so a stray
    /// newline from a copy-paste cannot break verification.
    public static func publicKey(in info: [String: Any]) -> String? {
        guard let raw = info[publicKeyKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == publicKeyBytes else { return nil }
        return trimmed
    }

    /// What is wrong with this build's update configuration, in one sentence, or
    /// nil when there is nothing wrong. Shown in Settings: a build that cannot
    /// update should say so rather than looking like one that can.
    public static func problem(in info: [String: Any]) -> String? {
        if url(in: info) == nil {
            return "No update feed is configured, so this build cannot be updated."
        }
        if publicKey(in: info) == nil {
            return "The update feed has no usable signing key, so updates would be rejected."
        }
        return nil
    }

    /// One line for Settings, with `now` passed in so the wording is testable.
    public static func statusHint(available: Bool, lastCheck: Date?, now: Date = Date(),
                                  calendar: Calendar = .current) -> String {
        guard available else {
            return "Updates are delivered by the App Store on iPhone and iPad."
        }
        guard let lastCheck else {
            return "Not checked yet — the app also checks once a day on its own."
        }
        if now.timeIntervalSince(lastCheck) < 60 { return "Checked just now." }
        return "Last checked \(stamp(lastCheck, now: now, calendar: calendar))."
    }

    private static func stamp(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "'today at' HH:mm"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "'yesterday at' HH:mm"
        } else {
            formatter.dateFormat = "'on' d MMM yyyy"
        }
        return formatter.string(from: date)
    }
}
