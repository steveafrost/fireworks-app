import SwiftUI
import FireworksCore
import WidgetKit

/// iPhone/iPad. Same engine, same numbers, a phone-shaped layout: one scroll, the
/// ring at the top, and the settings that matter on a device that cannot read a
/// shared folder behind it.
@main
struct FireworksiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            iOSRootView()
                .environment(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is the only reliable cue on iOS: there is no
            // background refresh guarantee for a utility like this, so refresh on
            // activation and let the widget show the last known snapshot.
            if phase == .active { Task { await model.refresh() } }
        }
    }
}

struct iOSRootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let reading = model.reading, model.config.isAnchored {
                        CreditGauge(reading: reading, low: model.config.lowThreshold,
                                    critical: model.config.criticalThreshold, size: 150)
                            .frame(maxWidth: .infinity)
                        tiles(reading)
                        metrics(reading)
                        if reading.days.count > 1 {
                            DayBars(days: reading.days, height: 44)
                        }
                        if !reading.models.isEmpty {
                            ModelMix(reading: reading)
                        }
                    } else {
                        SetupCard()
                    }
                    HStack {
                        Text(model.freshnessText())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .font(.footnote)
                    }
                }
                .padding()
            }
            .navigationTitle("Fireworks")
            .toolbar {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .toolbar {
                            Button("Done") { showingSettings = false }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func tiles(_ reading: Reading) -> some View {
        HStack(spacing: 10) {
            Tile(title: "Today", value: Money.formatted(reading.today))
            Tile(title: "Pace", value: "\(Money.formatted(reading.dailyRate))/day",
                 note: reading.daysLeft.map { String(format: "~%.1f days left", $0) })
        }
    }

    @ViewBuilder
    private func metrics(_ reading: Reading) -> some View {
        VStack(spacing: 6) {
            MetricRow(label: "Anchor", value: Money.formatted(reading.spend),
                      note: "\(Int(reading.hours))h")
            MetricRow(label: "Last \(reading.days.count)d", value: Money.formatted(reading.windowTotal),
                      note: "\(Money.formatted(reading.windowDailyAverage))/day")
        }
    }
}
