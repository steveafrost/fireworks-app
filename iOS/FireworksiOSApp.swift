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
    @Environment(\.colorScheme) private var scheme
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // The label comes first: everything under it is sample data, and that
                    // has to be known before the figures are read rather than after.
                    if model.isDemo, model.demoIsLabelled { DemoLabel() }
                    if let reading = model.reading, model.showsReading {
                        CreditGauge(reading: reading, low: model.config.lowThreshold,
                                    critical: model.config.criticalThreshold, size: 150)
                            .frame(maxWidth: .infinity)
                        tiles(reading)
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("History",
                                         detail: "measuring since \(Time.compactStamp(reading.anchorTime))")
                            MetricTable(metrics(reading))
                        }
                        if reading.days.count > 1 {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel("Daily burn",
                                             detail: "\(Money.formatted(reading.windowDailyAverage))/day average")
                                DayChart(days: reading.days, ink: ink(reading))
                            }
                        }
                        if !reading.models.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel("Model mix",
                                             detail: "\(Money.formatted(reading.spend)) in that time")
                                ModelMix(reading: reading)
                            }
                        }
                    } else {
                        SetupCard()
                    }
                    HStack {
                        if showsFreshness {
                            Text(model.freshnessText())
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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

    private var showsFreshness: Bool {
        if model.reading != nil { return true }
        if case .needsAnchor = model.status, model.keySource.isEmpty { return false }
        return true
    }

    @ViewBuilder
    private func tiles(_ reading: Reading) -> some View {
        HStack(spacing: 10) {
            Tile(title: "Today", value: Money.formatted(reading.today))
            Tile(title: "Pace", value: "\(Money.formatted(reading.dailyRate))/day",
                 note: reading.daysLeft.map { String(format: "~%.1f days left", $0) },
                 badge: reading.paceIsTight(horizonDays: model.config.paceHorizonDays) ? "🔥" : nil)
        }
    }

    /// The same rows the popover shows, so a number read on the phone means the
    /// same thing as the same number read in the menu bar.
    private func metrics(_ reading: Reading) -> [Metric] {
        [
            Metric(label: "Yesterday",
                   note: reading.days.dropLast().last.map { Time.displayLabel($0.date) },
                   value: Money.formatted(reading.days.dropLast().last?.cost ?? 0)),
            Metric(label: "Since first reading", note: "\(Int(reading.hours))h",
                   value: Money.formatted(reading.spend)),
            Metric(label: "Last \(reading.days.count) days",
                   note: "\(Money.formatted(reading.windowDailyAverage))/day",
                   value: Money.formatted(reading.windowTotal))
        ]
    }

    private func ink(_ reading: Reading) -> Color {
        Palette.ink(remaining: reading.remaining, low: model.config.lowThreshold,
                    critical: model.config.criticalThreshold, scheme: scheme)
    }
}
