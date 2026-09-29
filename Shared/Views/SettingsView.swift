import SwiftUI
import FireworksCore

/// Settings, including the two things the app cannot measure for you: the key and
/// the starting balance.
///
/// The anchor section states plainly that setting a balance re-stamps the anchor
/// to *now*, because the subtraction is only honest if both numbers refer to the
/// same moment: a top-up that arrives without a new anchor makes the remaining
/// figure read too low, and that is the one direction of error worth being loud
/// about.
public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    @State private var key = ""
    @State private var keyMessage: String?
    @State private var balance = ""
    @State private var anchorDate = Date()
    @State private var notifyStatus: String?

    public init() {}

    public var body: some View {
        Form {
            keySection
            anchorSection
            alertSection
            behaviourSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 560)
        .task {
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
    }

    // MARK: - sections

    private var keySection: some View {
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

    private var anchorSection: some View {
        Section("Balance anchor") {
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
            Text("Fireworks has no balance endpoint, so the app cannot ask what is left. It subtracts measured spend from this anchor instead, and always shows the anchor alongside the figure.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var behaviourSection: some View {
        Section("Behaviour") {
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
