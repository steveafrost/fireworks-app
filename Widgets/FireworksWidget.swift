import SwiftUI
import WidgetKit

/// The widget itself, one definition for both platforms: the families differ in
/// what fits, not in what the number means.
public struct FireworksWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FireworksWidget", provider: FireworksProvider()) { entry in
            FireworksWidgetView(entry: entry)
        }
        .configurationDisplayName("Remaining credit")
        .description("Fireworks credit left, today's spend and the daily trend.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct FireworksWidgetBundle: WidgetBundle {
    var body: some Widget {
        FireworksWidget()
    }
}
