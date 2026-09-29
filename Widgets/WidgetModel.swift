import Foundation
import WidgetKit
import FireworksCore

/// One rendered frame: the app's snapshot plus the thresholds that colour it.
///
/// The snapshot carries the figures; the *config* carries the taste (where "low"
/// is), and the widget reads both from the same shared folder so its colours
/// cannot drift from the app's.
public struct FireworksEntry: TimelineEntry {
    public var date: Date
    public var snapshot: ReadingStore.Snapshot?
    public var config: FireworksConfig

    public init(date: Date, snapshot: ReadingStore.Snapshot?, config: FireworksConfig) {
        self.date = date
        self.snapshot = snapshot
        self.config = config
    }
}

/// The widget's whole data story: read the snapshot the app wrote, draw it, and
/// ask the system to come back at the right time.
///
/// No network here on purpose. A widget's timeline budget is small and
/// unpredictable, and a widget that fetches is a widget that can show a
/// rate-limited blank. The app does the measuring; the widget does the showing.
public struct FireworksProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> FireworksEntry {
        FireworksEntry(date: Date(), snapshot: nil, config: FireworksConfig())
    }

    public func getSnapshot(in context: Context, completion: @escaping (FireworksEntry) -> Void) {
        completion(entry(at: Date()))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<FireworksEntry>) -> Void) {
        let now = Date()
        let entry = entry(at: now)
        // Ask to be redrawn a little after the app's next refresh, so a widget on
        // a desk that never opens the app still moves. A failed read retries
        // sooner: the file may simply not exist yet while the app is being
        // installed.
        let seconds = entry.snapshot == nil ? 15 * 60 : max(60, Double(entry.config.refreshSeconds) + 30)
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(seconds))))
    }

    private func entry(at date: Date) -> FireworksEntry {
        let directory = SharedContainer.directory
        return FireworksEntry(date: date,
                              snapshot: ReadingStore.loadSnapshot(from: directory),
                              config: ConfigStore.load(from: directory))
    }
}
