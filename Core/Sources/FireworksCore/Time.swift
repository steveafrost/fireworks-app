import Foundation

/// The API's time handling, in one place.
///
/// Everything sent is RFC-3339 UTC. Everything *displayed* is a local day, which
/// is why a day can never be taken from the API's own buckets: `DAY` groups in
/// UTC, so a "day" asked for that way starts at 20:00 for a US-East user and
/// silently attributes the evening's spend to tomorrow.
public enum Time {
    /// A value type, so it is safe to share and to call from any concurrency
    /// domain — the old `ISO8601DateFormatter` class is not.
    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: false,
                                                     timeZone: .gmt)

    public static func isoUTC(_ date: Date) -> String {
        date.formatted(iso)
    }

    /// Acronyms and offsets, both. A naive stamp (no offset) is read as local
    /// time, which is how a person typing a date into a settings file means it.
    public static func parse(_ text: String) -> Date? {
        if let date = try? iso.parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let parser = DateFormatter()     // local per call: no shared mutable state
            parser.dateFormat = format
            parser.timeZone = .current
            if let date = parser.date(from: text) { return date }
        }
        return nil
    }

    /// Local midnight → now.
    public static func todayWindow(now: Date, calendar: Calendar = .current) -> (Date, Date) {
        (calendar.startOfDay(for: now), now)
    }

    /// `[start, end]` split into contiguous slices of at most `maxDays`, since a
    /// single request may not span more than 31 days.
    public static func chunkWindow(start: Date, end: Date, maxDays: Int = 31,
                                   calendar: Calendar = .current) -> [(Date, Date)] {
        var chunks: [(Date, Date)] = []
        var cursor = start
        while cursor < end {
            let limit = calendar.date(byAdding: .day, value: maxDays, to: cursor) ?? end
            let chunkEnd = min(limit, end)
            chunks.append((cursor, chunkEnd))
            cursor = chunkEnd
        }
        return chunks.isEmpty ? [(start, end)] : chunks
    }

    /// One window per local day, oldest first, ending at `now`.
    /// Returns `(label, start, end)` so a label can never drift from its window.
    public static func localDayWindows(now: Date, days: Int,
                                       calendar: Calendar = .current) -> [(String, Date, Date)] {
        let startOfToday = calendar.startOfDay(for: now)
        var windows: [(String, Date, Date)] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else {
                continue
            }
            let dayEnd = offset == 0
                ? now
                : (calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now)
            windows.append((label(for: dayStart, calendar: calendar), dayStart, min(dayEnd, now)))
        }
        return windows
    }

    public static func label(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func displayLabel(_ dateString: String, short: Bool = false) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = .current
        guard let date = parser.date(from: dateString) else { return dateString }
        if short {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "3m ago" / "2h ago" — how old a cached reading is.
    public static func humanAge(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded()))s ago" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded()))m ago" }
        return "\(Int((seconds / 3600).rounded()))h ago"
    }

    /// A full timestamp for a tooltip or a settings row: "16 Sep 2026 at 09:14".
    public static func displayStamp(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    /// A compact stamp for a subtitle or a narrow column: "Fri 25 Sep 13:36".
    ///
    /// A fixed pattern rather than a localized template, because the templates
    /// expand ("September 25, 2026 at 1:36 PM") and this rides beside a section
    /// heading, where a long date pushes the heading off its own line. The
    /// locale still supplies the weekday and month names.
    public static func compactStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }

    /// The clock time alone, 24-hour: "15:41". A panel sentence that ends
    /// "· updated 3:40 PM" is eleven characters wider than the same fact in
    /// 24-hour time, and that sentence sits on one line by design.
    public static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The rate a forecast uses: today's pace blended with the window average.
    ///
    /// A partial day projects badly — eight good hours of work on a quiet
    /// afternoon reads as a runaway rate — while the window average lags by
    /// however long the anchor has been open. Neither alone is the rate; the mean
    /// is, so one heavy day moves the forecast without owning it. The average
    /// carries the case where too little of today has passed to project at all,
    /// and the pace carries a fresh anchor with no window behind it yet.
    public static func dailyRate(todaySpend: Double, hoursToday: Double,
                                 spend: Double, hours: Double) -> Double {
        let pace = hoursToday >= 1 ? todaySpend / hoursToday * 24 : 0
        let average = hours > 0.05 ? spend / hours * 24 : 0
        if pace > 0 && average > 0 { return (pace + average) / 2 }
        return pace > 0 ? pace : average
    }
}
