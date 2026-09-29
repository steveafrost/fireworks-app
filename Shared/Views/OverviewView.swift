import SwiftUI
import FireworksCore

/// The whole product in one scroll: what is left, what it is costing, and what
/// that implies. Deliberately dense — the audience for this is someone checking
/// a number mid-task, not browsing.
public struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var onOpenSettings: (() -> Void)?

    public init(onOpenSettings: (() -> Void)? = nil) {
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reading = model.reading, model.config.isAnchored {
                content(reading)
            } else {
                SetupCard()
            }
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private func content(_ reading: Reading) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CreditGauge(reading: reading, low: model.config.lowThreshold,
                        critical: model.config.criticalThreshold, size: 128)
                .frame(maxWidth: .infinity)

            if reading.remaining < 0 {
                Banner(text: "Over the anchor by \(Money.formatted(-reading.remaining)) — raise it if you topped up",
                       tone: .warning)
            } else if reading.remaining <= model.config.criticalThreshold {
                Banner(text: "Critical — under your \(Money.formatted(model.config.criticalThreshold)) line",
                       tone: .critical)
            } else if reading.remaining <= model.config.lowThreshold {
                Banner(text: "Low credit — under your \(Money.formatted(model.config.lowThreshold)) line",
                       tone: .warning)
            }

            HStack(spacing: 8) {
                Tile(title: "Today", value: Money.formatted(reading.today),
                     note: averageNote(reading))
                Tile(title: "Pace", value: "\(Money.formatted(reading.dailyRate))/day",
                     note: reading.daysLeft.map { String(format: "~%.1f days left", $0) } ?? "no rate yet",
                     tint: reading.daysLeft.map { $0 < 3 ? Palette.red(scheme)
                                                    : ($0 < 7 ? Palette.amber(scheme) : Palette.green(scheme)) })
            }

            VStack(spacing: 6) {
                MetricRow(label: "Yesterday", value: Money.formatted(reading.days.dropLast().last?.cost ?? 0),
                          note: reading.days.dropLast().last.map { Time.displayLabel($0.date) })
                MetricRow(label: "Anchor", value: Money.formatted(reading.spend),
                          note: "\(Int(reading.hours))h · \(Money.formatted(reading.spend / max(reading.hours, 1) * 24))/d")
                MetricRow(label: "Last \(reading.days.count)d", value: Money.formatted(reading.windowTotal),
                          note: "\(Money.formatted(reading.windowDailyAverage))/day")
            }

            if reading.days.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Daily")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Time.displayLabel(reading.days.first?.date ?? "")) →")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    DayBars(days: reading.days)
                }
            }

            if !reading.models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("By model · since anchor")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ModelMix(reading: reading)
                }
            }

            AlertsRow()
        }
    }

    private func averageNote(_ reading: Reading) -> String {
        let priors = reading.days.dropLast()
        guard !priors.isEmpty else { return "no history yet" }
        let average = priors.reduce(0) { $0 + $1.cost } / Double(priors.count)
        return "avg \(Money.formatted(average))/day"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if case .refreshing = model.status {
                    ProgressView().controlSize(.small)
                } else if let reading = model.reading {
                    Circle()
                        .fill(Palette.ink(remaining: reading.remaining, low: model.config.lowThreshold,
                                          critical: model.config.criticalThreshold, scheme: scheme))
                        .frame(width: 7, height: 7)
                }
                Text(model.freshnessText())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }

            HStack(spacing: 10) {
                if let onOpenSettings {
                    Button("Settings…", action: onOpenSettings)
                        .buttonStyle(.borderless)
                }
                Link("Fireworks billing", destination: URL(string: "https://app.fireworks.ai/account/billing")!)
                    .buttonStyle(.borderless)
                Spacer()
                Link(destination: URL(string: "https://github.com/steveafrost/fireworks-app")!) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Why {remaining} is a subtraction, not a figure Fireworks reported")
            }
            .font(.system(size: 11))
        }
    }
}

/// The alerts line: what is armed, and a one-click way to change it. The plugin
/// had this row because a menu is the only UI it has; the app keeps it because
/// "is it going to warn me?" is a question you ask *after* the fact.
struct AlertsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.config.notify ? "bell" : "bell.slash")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(Alerts.armedSummary(config: model.config))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.config.notify },
                set: { value in model.update { $0.notify = value } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }
}

enum BannerTone { case warning, critical, info }

struct Banner: View {
    let text: String
    let tone: BannerTone

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colour: Color = switch tone {
        case .warning: Palette.amber(scheme)
        case .critical: Palette.red(scheme)
        case .info: Palette.accent(scheme)
        }
        HStack(spacing: 6) {
            Image(systemName: tone == .info ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Onboarding. It has one job: explain why the app needs a starting balance,
/// because "type in your balance" looks like a missing feature until you know the
/// API has no balance endpoint. The explanation comes *before* the field.
public struct SetupCard: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var balance = ""
    @State private var error: String?
    @State private var saved = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two things and you're done")
                .font(.system(size: 14, weight: .semibold))

            Text("Fireworks reports spending, not balance — there is no endpoint that returns your remaining credit, so no app can ask for it. Enter the balance you hold now and everything after this moment is measured spend, subtracted from it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("API key").font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField("paste from app.fireworks.ai → API keys", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if model.isConfigured || saved {
                    Label("stored in your Keychain", systemImage: "checkmark.seal")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.green(.light))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Balance you hold now").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("e.g. 11.21", text: $balance)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(save)
            }

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.red(.light))
            }

            HStack {
                Button("Start measuring", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Link("Get a key →", destination: URL(string: "https://app.fireworks.ai/settings/users/api-keys")!)
                .font(.system(size: 11))
        }
    }

    private func save() {
        error = nil
        do {
            if !key.trimmingCharacters(in: .whitespaces).isEmpty {
                try model.saveKey(key)
                saved = true
                key = ""
            }
            if let amount = Double(balance.replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)),
               amount > 0 {
                model.setAnchor(amount)
            } else if model.config.anchorBalance <= 0 {
                error = "Enter the balance you hold, e.g. 11.21"
                return
            }
            Task { await model.refresh() }
        } catch let failure as FireworksError {
            error = failure.errorDescription
        } catch {
            self.error = "\(error)"
        }
    }
}
