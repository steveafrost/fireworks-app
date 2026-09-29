import SwiftUI
import FireworksCore

/// The whole product in one panel: what is left, what it is costing, and what
/// that implies. Deliberately dense — the audience for this is someone checking
/// a number mid-task, not browsing.
///
/// The layout follows the SwiftBar plugin's dashboard, which got this right and
/// stayed the reference while the app was built: one horizontal lead (the figure,
/// then a progress bar, then the sentence that dates it), two tiles, then ruled
/// sections — MODEL MIX, then DAILY BURN — each with an uppercase eyebrow over it.
///
/// Two things this panel does that the first version did not:
///
/// * **It draws its own background.** A `MenuBarExtra` popover can come up on a
///   flat grey material, and a palette tuned for a lavender surface loses its
///   contrast on grey. The panel supplies `Palette.surface`, so what the user
///   sees is what the offscreen renderer draws.
/// * **Nothing is said twice.** The bar carries the share, the figure carries the
///   dollars, the pill carries the state, the sub-line carries the dates. The
///   ring this replaced spent 128pt of height repeating the bar.
public struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var onOpenSettings: (() -> Void)?

    public init(onOpenSettings: (() -> Void)? = nil) {
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.section) {
            if let reading = model.reading, model.config.isAnchored {
                content(reading)
            } else {
                SetupCard()
            }
            footer
        }
        .padding(Rhythm.inset)
        .frame(width: Rhythm.width, alignment: .leading)
        .background(Palette.surface(scheme))
    }

    // MARK: - sections

    @ViewBuilder
    private func content(_ reading: Reading) -> some View {
        VStack(alignment: .leading, spacing: Rhythm.section) {
            hero(reading)

            // A failed refresh is a state, not a footnote: the panel keeps
            // showing the last good reading, and this is what says so.
            if case .failed(let why) = model.status {
                Banner(text: "Showing the last good reading — \(why)", tone: .warning)
            }

            stateBanner(reading)

            HStack(spacing: 8) {
                Tile(title: "Today", value: Money.formatted(reading.today), note: averageNote(reading))
                Tile(title: "Pace", value: "\(Money.formatted(reading.dailyRate))/day",
                     note: paceNote(reading), tint: paceTint(reading))
            }

            if !reading.models.isEmpty {
                section("Model mix") {
                    ModelMix(reading: reading)
                }
            }

            if reading.days.count > 1 {
                section("Daily burn") {
                    DayChart(days: reading.days, height: 52, ink: ink(reading))
                }
            }
        }
    }

    /// The lead: what is left, as dollars and as a share, with the sentence that
    /// dates both.
    private func hero(_ reading: Reading) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Fireworks credit left")
                    .eyebrow()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                StatusPill(text: "\(Int((reading.share * 100).rounded()))% left · \(status(reading).word)",
                           tint: ink(reading))
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Money.formatted(reading.remaining))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ink(reading))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("of \(Money.formatted(reading.anchorBalance)) left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }

            CreditBar(fraction: reading.share, ink: ink(reading))

            Text("\(Money.formatted(reading.spend)) spent since \(Time.compactStamp(reading.anchorTime))"
                 + " · updated \(Time.clock(reading.fetchedAt))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A ruled section: hairline, eyebrow, content — the plugin panel's shape.
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Rhythm.inner) {
            Rule()
            SectionLabel(title)
            content()
        }
    }

    // MARK: - footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Rule()

            AlertsRow()

            HStack(spacing: 14) {
                if let onOpenSettings {
                    Button("Settings…", action: onOpenSettings)
                        .footerLink()
                }
                Link("Billing at Fireworks", destination: URL(string: "https://app.fireworks.ai/account/billing")!)
                    .footerLink()
                Spacer(minLength: 6)
                if case .refreshing = model.status {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
                Link(destination: URL(string: "https://github.com/steveafrost/fireworks-app")!) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Why {remaining} is a subtraction, not a figure Fireworks reported")
            }
            .font(.system(size: 11))
        }
    }

    // MARK: - small helpers

    private enum Status {
        case over, critical, low, healthy

        var word: String {
            switch self {
            case .over: return "over anchor"
            case .critical: return "critical"
            case .low: return "low"
            case .healthy: return "healthy"
            }
        }
    }

    private func status(_ reading: Reading) -> Status {
        if reading.remaining < 0 { return .over }
        if reading.remaining <= model.config.criticalThreshold { return .critical }
        if reading.remaining <= model.config.lowThreshold { return .low }
        return .healthy
    }

    @ViewBuilder
    private func stateBanner(_ reading: Reading) -> some View {
        switch status(reading) {
        case .over:
            Banner(text: "Over the anchor by \(Money.formatted(-reading.remaining)) — raise it if you topped up",
                   tone: .critical)
        case .critical:
            Banner(text: "Critical — under your \(Money.formatted(model.config.criticalThreshold)) line",
                   tone: .critical)
        case .low:
            Banner(text: "Low credit — under your \(Money.formatted(model.config.lowThreshold)) line",
                   tone: .warning)
        case .healthy:
            EmptyView()
        }
    }

    private func ink(_ reading: Reading) -> Color {
        Palette.ink(remaining: reading.remaining, low: model.config.lowThreshold,
                    critical: model.config.criticalThreshold, scheme: scheme)
    }

    private func averageNote(_ reading: Reading) -> String {
        let priors = reading.days.dropLast()
        guard !priors.isEmpty else { return "no history yet" }
        let average = priors.reduce(0) { $0 + $1.cost } / Double(priors.count)
        return "vs \(Money.formatted(average))/day average"
    }

    private func paceNote(_ reading: Reading) -> String {
        guard let left = reading.daysLeft else { return "no rate yet" }
        return String(format: "~%.1f days left", left)
    }

    /// The pace tile is the one place the app forecasts, and the panel left it
    /// untinted, so the ink appears only where it means something: a forecast
    /// under three days goes red. Amber a week out would put a warning colour on
    /// a week of credit, which is most of the time for most accounts.
    private func paceTint(_ reading: Reading) -> Color {
        guard let left = reading.daysLeft else { return .secondary }
        return left < 3 ? Palette.red(scheme) : Color.primary
    }
}

/// The footer's plain-text links. macOS has a link button style that paints the
/// accent colour and underlines on hover — exactly what a popover footer wants —
/// and it does not exist on iOS, where these rows are never drawn (the phone has
/// its own root view). Hence the `#if`, rather than a borderless button that
/// looks like a label on the Mac.
private extension View {
    @ViewBuilder
    func footerLink() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
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
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: tone == .info ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        VStack(alignment: .leading, spacing: Rhythm.section) {
            VStack(alignment: .leading, spacing: 6) {
                // The eyebrow the live panel carries, so first run and every run
                // after it read as one screen rather than two.
                Text("Fireworks credit left")
                    .eyebrow()
                    .foregroundStyle(.secondary)
                Text("Two things and you're done")
                    .font(.system(size: 15, weight: .semibold))
                Text("Fireworks reports spending, not balance — there is no endpoint that returns your remaining credit, so no app can ask for it. Enter the balance you hold now and everything after this moment is measured spend, subtracted from it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("API key") {
                SecureField("paste from app.fireworks.ai → API keys", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if model.isConfigured || saved {
                    Label("stored in your Keychain", systemImage: "checkmark.seal")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.green(.light))
                }
            }

            field("Balance you hold now") {
                TextField("e.g. 11.21", text: $balance)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(save)
            }

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.red(.light))
            }

            HStack(spacing: 12) {
                Button("Start measuring", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Link("Get a key →", destination: URL(string: "https://app.fireworks.ai/settings/users/api-keys")!)
                    .font(.system(size: 11))
                Spacer(minLength: 0)
            }
        }
    }

    /// A labelled input, so the two fields look like the same kind of thing.
    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .eyebrow()
                .foregroundStyle(.secondary)
            content()
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
