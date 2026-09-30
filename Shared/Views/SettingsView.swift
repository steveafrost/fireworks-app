import SwiftUI
import FireworksCore

/// Settings, as a sidebar and a pane.
///
/// It was one flat `Form` — key, balance, alerts, behaviour, about — and the
/// problem with that was not length but adjacency: the key and the balance are
/// one concern (the account) split across sections one and two, while "Behaviour"
/// held the refresh cadence, the history length and the account-id override
/// together. The panes below are the same settings, sorted by what you would be
/// trying to do when you opened the window.
///
/// Two panes carry a badge, and only two, because a badge is a claim: Balance
/// shows the figure the app measured, Updates shows a version it has actually
/// been offered. The rest have nothing true to put there.
///
/// The anchor pane states plainly that setting a balance re-stamps the anchor to
/// *now*, because the subtraction is only honest if both numbers refer to the
/// same moment: a top-up that arrives without a new anchor makes the remaining
/// figure read too low, and that is the one direction of error worth being loud
/// about.
public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    @State private var pane: SettingsPane = .balance
    @State private var key = ""
    @State private var keyMessage: String?
    @State private var balance = ""
    @State private var anchorDate = Date()
    @State private var notifyStatus: String?

    /// Observed directly rather than reached through the model: it is an
    /// ObservableObject inside an @Observable one, and only a direct
    /// subscription repaints this pane when Sparkle reports a finished check.
    @ObservedObject private var updater = AppModel.shared.updater

    public init() {}

    public var body: some View {
        Group {
            #if os(macOS)
            split
            #else
            // iOS presents this in a sheet, where a sidebar would be a second
            // navigation for one job. Same sections, one list.
            Form { allSections }
                .formStyle(.grouped)
                .frame(minWidth: 440, minHeight: 560)
            #endif
        }
        .task { await load() }
    }

    // MARK: - the window

    #if os(macOS)
    private var split: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(SettingsPane.allCases) { item in
                    SettingsSidebarRow(pane: item,
                                       reading: model.reading,
                                       availableUpdate: updater.available)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 196, max: 230)
        } detail: {
            detail
        }
        .frame(minWidth: 700, minHeight: 520)
    }

    /// A pane is a title, a line saying what it is for, and its sections — the
    /// same grouped list as before, one screenful at a time.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(pane.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 6)

            Form {
                switch pane {
                case .account: accountSection; accountIDSection
                case .balance: balanceStatusSection; liveBalanceSection; anchorSection
                case .alerts: alertSection
                case .general: generalSection
                case .updates: updateSection
                case .about: aboutSection
                }
            }
            .formStyle(.grouped)
        }
    }
    #endif

    @ViewBuilder
    private var allSections: some View {
        accountSection
        accountIDSection
        balanceStatusSection
        liveBalanceSection
        anchorSection
        alertSection
        generalSection
        updateSection
        aboutSection
    }

    private func load() async {
        balance = model.config.anchorBalance > 0 ? String(format: "%.2f", model.config.anchorBalance) : ""
        anchorDate = model.config.anchorTime ?? Date()
        let status = await Notifier().currentAuthorization()
        notifyStatus = switch status {
        case .authorized, .provisional, .ephemeral: "Notifications are allowed"
        case .denied: "Notifications are denied — allow them in System Settings › Notifications › Fireworks"
        case .notDetermined: "You'll be asked the first time an alert fires"
        @unknown default: nil
        }
    }

    // MARK: - sections

    /// The figure itself, so the pane that explains the number starts with it.
    private var balanceStatusSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let reading = model.reading {
                    Text(Money.formatted(reading.remaining))
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                    Text(reading.sourceWord.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else {
                    Text("No reading yet").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Refresh") {
                    Task { await model.refresh() }
                }
            }
            if let reading = model.reading {
                Text(reading.footnote())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var accountSection: some View {
        Section("API key") {
            HStack {
                SecureField("paste a key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveKey() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(keyMessage ?? (model.keySource.isEmpty ? "No key found yet" : "Reading from \(model.keySource)"))
                .font(.system(size: 11))
                .foregroundStyle(keyMessage == nil ? .secondary : .primary)
                .textSelection(.enabled)
            HStack {
                Button("Forget key") {
                    model.forgetKey()
                    keyMessage = "Removed from the Keychain"
                }
                Link("Create a key →", destination: URL(string: "https://app.fireworks.ai/settings/users/api-keys")!)
            }
            Text("Stored in your Keychain under \"\(KeyStore.defaultService)\". The app also reads a key file, or the SwiftBar plugin's Keychain item, if one is already there.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountIDSection: some View {
        Section("Account") {
            HStack {
                TextField("Account (optional)", text: Binding(
                    get: { model.config.account },
                    set: { value in model.update { $0.account = value } }
                ))
                .textFieldStyle(.roundedBorder)
                Button("Detect") {
                    Task { await model.refresh() }
                }
            }
            // The field reads like a second key until the note says otherwise, and
            // it is not one — blank is the normal setting. The id the app worked out
            // is shown here rather than written into the field, so the field stays
            // empty and the app keeps asking the key. The wording lives in Core so
            // it can be tested; this pane is a Form, which the offscreen renderer
            // draws as nothing, so a picture is not available for it.
            Text(FireworksConfig.accountHint(configured: model.config.account,
                                             resolved: model.account))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var liveBalanceSection: some View {
        Section("Balance source") {
            Toggle("Ask Fireworks for the real balance", isOn: Binding(
                get: { model.config.liveBalance },
                set: { value in model.update { $0.liveBalance = value } }
            ))
            Text(FireworksConfig.balanceSourceHint(live: model.config.liveBalance))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var anchorSection: some View {
        Section("Anchor") {
            HStack {
                Text("Balance held")
                Spacer()
                TextField("e.g. 11.21", text: $balance)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                Text("USD").foregroundStyle(.secondary)
            }
            DatePicker("As of", selection: $anchorDate, displayedComponents: [.date, .hourAndMinute])
            HStack(alignment: .firstTextBaseline) {
                Text(currentAnchor)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Set anchor") { setAnchor() }
                    .disabled(Double(balance) == nil || Double(balance) ?? 0 <= 0)
            }
            if let reading = model.reading {
                Text("Measured spend since the anchor: \(Money.formatted(reading.spend)) · remaining \(Money.formatted(reading.remaining))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var alertSection: some View {
        Section("Alerts") {
            Toggle("Notify me when credit runs low", isOn: Binding(
                get: { model.config.notify },
                set: { value in model.update { $0.notify = value } }
            ))
            if let notifyStatus {
                Text(notifyStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Warn at")
                Spacer()
                TextField("70, 90", text: Binding(
                    get: { model.config.notifyPercent.map(String.init).joined(separator: ", ") },
                    set: { text in
                        let parsed = text.split(whereSeparator: { $0 == "," || $0 == " " })
                            .compactMap { Int($0) }
                        model.update { $0.notifyPercent = FireworksConfig.cleanPercents(parsed) }
                    }
                ))
                .frame(width: 110)
                .textFieldStyle(.roundedBorder)
                Text("% of the anchor spent").foregroundStyle(.secondary)
            }
            Toggle("Also notify every 10% of spend", isOn: Binding(
                get: { model.config.notifyEveryTen },
                set: { value in model.update { $0.notifyEveryTen = value } }
            ))
            Toggle("Warn under \(Money.formatted(model.config.lowThreshold)) and \(Money.formatted(model.config.criticalThreshold)) left",
                   isOn: Binding(
                       get: { model.config.lowThreshold > 0 },
                       set: { value in
                           model.update {
                               $0.lowThreshold = value ? 3.0 : 0
                               $0.criticalThreshold = value ? 1.0 : 0
                           }
                       }
                   ))
            HStack {
                // The one place the fire's horizon is set — three days by default,
                // 0 to switch the mark off.
                Text("Fire 🔥 under")
                Spacer()
                TextField("3", text: Binding(
                    get: { String(model.config.paceHorizonDays) },
                    set: { text in
                        let value = Int(text.filter(\.isNumber)) ?? 0
                        model.update { $0.paceHorizonDays = value }
                    }
                ))
                .frame(width: 44)
                .textFieldStyle(.roundedBorder)
                Text("days left").foregroundStyle(.secondary)
            }
            HStack {
                Button("Send a test alert") {
                    Task { _ = await model.testNotification() }
                }
                Text(Alerts.armedSummary(config: model.config))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var generalSection: some View {
        Section("Refresh & history") {
            Picker("Refresh every", selection: Binding(
                get: { model.config.refreshSeconds },
                set: { value in model.update { $0.refreshSeconds = value } }
            )) {
                Text("1 minute").tag(60)
                Text("2 minutes").tag(120)
                Text("5 minutes").tag(300)
                Text("10 minutes").tag(600)
                Text("30 minutes").tag(1800)
                Text("1 hour").tag(3600)
            }
            Picker("Daily history", selection: Binding(
                get: { model.config.historyDays },
                set: { value in model.update { $0.historyDays = value } }
            )) {
                ForEach([2, 3, 5, 7, 10, 14, 21, 30], id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
            HStack {
                Button("Refresh now") {
                    Task { await model.refresh() }
                }
                if let reading = model.reading {
                    Text(reading.footnote())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var updateSection: some View {
        Section("Updates") {
            if updater.isAvailable {
                if let available = updater.available {
                    // An update found in the background is offered here as well as
                    // in the notification: notifications can be denied, and this
                    // row is the signal that cannot be.
                    HStack(alignment: .firstTextBaseline) {
                        Text("Version \(available) is available")
                            .font(.system(size: 11))
                        Spacer(minLength: 8)
                        Button("Install…") { updater.checkForUpdates() }
                    }
                }
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }
                ))
                HStack(alignment: .firstTextBaseline) {
                    // A misconfigured feed or key is said out loud: that is the
                    // one fault in this app that would otherwise never announce
                    // itself, it would just mean updates stop arriving.
                    Text(updater.problem ?? updater.statusHint)
                        .font(.system(size: 10))
                        .foregroundStyle(updater.problem == nil ? .tertiary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                }
                if let feed = updater.feedURL {
                    Text("Feed: \(feed.absoluteString)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // iOS: the App Store owns updates, so there is nothing to toggle.
                Text(updater.statusHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.shortVersion)
            LabeledContent("Data", value: SharedContainer.directory.path)
            HStack {
                #if os(macOS)
                Button("Reveal data folder") {
                    NSWorkspace.shared.open(SharedContainer.directory)
                }
                #endif
                Button("Refresh now") {
                    Task { await model.refresh() }
                }
            }
            Text("Credit is measured by asking Fireworks for its rated cost per local day; the balance is read from the account gateway. Nothing here is estimated unless the gateway cannot be reached, and the popover says so when that happens.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - actions

    private var currentAnchor: String {
        guard let when = model.config.anchorTime, model.config.anchorBalance > 0 else {
            return "No anchor yet — without one there is no remaining figure to show"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Anchored at \(Money.formatted(model.config.anchorBalance)) on \(formatter.string(from: when))"
    }

    private func saveKey() {
        do {
            try model.saveKey(key)
            key = ""
            keyMessage = "Saved to the Keychain"
            Task { await model.refresh() }
        } catch let failure as FireworksError {
            keyMessage = failure.errorDescription
        } catch {
            keyMessage = "\(error)"
        }
    }

    private func setAnchor() {
        guard let amount = Double(balance.replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)), amount > 0 else { return }
        model.setAnchor(amount, at: anchorDate)
        Task { await model.refresh() }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// One row of the settings sidebar.
///
/// Pulled out of the `List` for one reason: the offscreen renderer can draw this
/// (it is a row, not a `Form`) and it is where the mistakes that no test can see
/// live — an SF Symbol name that resolves to nothing draws an empty space where an
/// icon should be, and nothing about the code looks wrong.
struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let reading: Reading?
    let availableUpdate: String?

    var body: some View {
        HStack(spacing: 8) {
            Label(pane.title, systemImage: pane.symbol)
            Spacer(minLength: 8)
            if let badge = SettingsPane.badge(for: pane, reading: reading,
                                              availableUpdate: availableUpdate) {
                Text(badge)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
