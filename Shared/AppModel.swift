import Foundation
import Observation
import WidgetKit
import FireworksCore

/// The one place that knows how to produce a reading, and the only thing the
/// views talk to.
///
/// It owns no rendering: a view asks for `model.reading` and draws it. That is
/// what lets the menu bar, the popover and the iOS screen show identical numbers
/// while being three separate view hierarchies.
@MainActor
@Observable
public final class AppModel {
    public enum Status: Equatable {
        case idle
        case refreshing
        case failed(String)
        /// Not a failure: the user still has to do something.
        case needsKey(String)
        case needsAnchor
    }

    public private(set) var config: FireworksConfig
    public private(set) var reading: Reading?
    /// True while the app is showing sample numbers rather than the account's.
    ///
    /// Session-only, and deliberately never persisted: quitting is a clean way out, and
    /// a later launch never opens onto figures that are not the user's. Everything that
    /// would make a demo *real* — saving a reading, writing the widget's snapshot,
    /// delivering an alert — is skipped while this is true, so a sample number cannot
    /// leak into the app's own data, into a notification, or onto the desktop.
    public private(set) var isDemo = false
    /// Whether the demo has to say so on screen. True for every path a person can reach;
    /// the harnesses that draw documentation and store screenshots turn it off, because
    /// they are showing what a *configured* app looks like, and the figures in those
    /// pictures are illustrative rather than anyone's.
    public private(set) var demoIsLabelled = true
    public private(set) var status: Status = .idle
    /// Where the key came from, shown in Settings so "which key am I using" is
    /// answerable without guessing.
    public private(set) var keySource: String = ""
    public private(set) var lastError: String?
    public private(set) var account: String = ""

    private let service = RefreshService()
    private var loop: Task<Void, Never>?
    private let notifier = Notifier()

    /// Sparkle, on the platform that has it. Owned by the model so the app
    /// delegate and the Settings pane drive the same updater.
    public let updater = Updater.shared

    public init() {
        SharedContainer.prepare()
        let carried = SharedContainer.migrateFromPlugin()
        config = ConfigStore.load(from: SharedContainer.directory)
        reading = ReadingStore.load(from: SharedContainer.directory)
        // Headless seeding, so a fresh device can be brought up (and verified)
        // without typing into the UI — a simulator, a CI run, or a second Mac.
        // Only ever fills a gap: a real setting on disk always wins.
        SharedContainer.applyEnvironmentSeed(to: &config)
        status = config.isAnchored ? .idle : .needsAnchor
        let dataPath = SharedContainer.directory.path
        // Name the plugin directory only when it is actually there. It is a
        // one-time migration source, and printing the path on a Mac that never ran
        // the plugin (or has since deleted it) reads as if the app were reading it
        // every launch.
        let pluginURL = SharedContainer.pluginDirectory
        let pluginPath = pluginURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil
        } ?? "none"
        let migrated = carried.isEmpty ? "nothing" : carried.joined(separator: ",")
        let anchorStamp = config.anchorTime.map { Time.isoUTC($0) } ?? "—"
        Diagnostics.log("launch: data=\(dataPath) plugin=\(pluginPath) migrated=\(migrated) "
                        + "remembered=\(config.isAnchored) balance=\(config.anchorBalance)@\(anchorStamp) "
                        + "cached_reading=\(reading != nil)")
    }

    /// One instance per process. The Mac app's refresh loop is started by the app
    /// delegate, so the popover and the menu-bar label have to observe the *same*
    /// model rather than each creating one on first draw.
    public static let shared = AppModel()

    // MARK: - lifecycle

    /// Refresh now, then keep refreshing on the configured cadence.
    public func start() async {
        updater.start()
        #if DEBUG
        // Two harness paths, neither of them reachable in a shipped build. `--demo` is
        // the labelled demo a person can also reach by tapping; `--render-ui-sample` is
        // the same figures with the label off, for the store listing and the README,
        // which show the app as it looks once it is configured.
        if CommandLine.arguments.contains("--demo"), !isDemo {
            startDemo()
        } else if CommandLine.arguments.contains("--render-ui-sample") {
            previewInstallSampleReading()
        }
        #endif
        await refresh()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = await self?.config.refreshSeconds ?? 300
                try? await Task.sleep(for: .seconds(max(30, seconds)))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: - measuring

    public func refresh() async {
        // Nothing to measure in the demo, and a refresh would either fail for want of a
        // key or replace the sample with a real reading nobody asked for while they were
        // looking at it.
        if isDemo {
            Diagnostics.log("refresh: skipped — showing the demo")
            return
        }
        // The balance comes from Fireworks now, so a fresh install fills it in rather
        // than stopping to ask for a number the gateway will hand over.
        if !config.isAnchored, let adopted = await rememberLiveBalance() {
            Diagnostics.log("refresh: remembered the live balance \(Money.formatted(adopted))")
        }
        guard config.isAnchored else {
            status = .needsAnchor
            Diagnostics.log("refresh: skipped — no balance has been read yet")
            return
        }
        let key: String
        do {
            let found = try resolveKey()
            key = found.key
            keySource = found.source
        } catch let error as FireworksError {
            status = .needsKey(error.errorDescription ?? "No API key")
            lastError = error.errorDescription
            return
        } catch {
            status = .needsKey("\(error)")
            return
        }

        status = .refreshing
        let client = FireworksClient(apiKey: key, account: config.account)
        do {
            let resolved = try await client.resolvedAccount()
            account = resolved
            config.account = resolved
            Diagnostics.log("refresh: key=\(keySource) account=\(resolved)")
            let outcome = await service.refresh(config: config, previous: reading, source: client)
            if let fresh = outcome.reading {
                reading = fresh
                ReadingStore.save(fresh, to: SharedContainer.directory)
                ReadingStore.save(snapshot: ReadingStore.Snapshot(reading: fresh, account: resolved),
                                  to: SharedContainer.directory)
                // The widget renders a file, so a new file *is* the update.
                WidgetCenter.shared.reloadAllTimelines()
                // Remember what Fireworks last said, so a later outage has a figure to
                // show instead of a blank. Written only when it changes: this is the
                // fallback, not a setting.
                var changed = false
                if let live = fresh.liveBalance, live != config.anchorBalance {
                    config.anchorBalance = live
                    config.anchorTime = config.anchorTime ?? fresh.balanceSeenAt ?? Date()
                    changed = true
                }
                // The cycle is persisted for the same reason: it is what the
                // percentages divide by, and without it a relaunch would fall back to
                // the lifetime total and the dial would refill for no reason.
                if let cycle = fresh.cycleBalance, cycle != config.cycleBalance {
                    config.cycleBalance = cycle
                    config.cycleStart = fresh.cycleStart
                    changed = true
                }
                if changed { _ = try? ConfigStore.save(config, to: SharedContainer.directory) }
            }
            if let failure = outcome.error {
                lastError = failure.errorDescription
                status = .failed(failure.errorDescription ?? "Refresh failed")
                Diagnostics.log("refresh: FAILED \(failure.errorDescription ?? "") "
                                + "(stale=\(outcome.isStale))")
            } else {
                lastError = nil
                status = .idle
                Diagnostics.log("refresh: ok remaining=\(Money.formatted(reading?.remaining ?? 0)) "
                                + "spend=\(Money.formatted(reading?.spend ?? 0)) "
                                + "today=\(Money.formatted(reading?.today ?? 0)) "
                                + "balance=\(reading?.sourceWord ?? "—") "
                                + "credited=\(reading?.credited.map { Money.formatted($0) } ?? "—") "
                                + "cycle=\(reading?.cycleBalance.map { Money.formatted($0) } ?? "—") "
                                + "account=\(resolved) events=\(outcome.events.count)")
                await notifier.deliver(outcome.events, enabled: config.notify)
            }
        } catch let error as FireworksError {
            lastError = error.errorDescription
            status = error.isSetup ? .needsKey(error.errorDescription ?? "") : .failed(error.errorDescription ?? "")
        } catch {
            lastError = "\(error)"
            status = .failed("\(error)")
        }
    }

    /// The countdown text under the header: either "updated 2m ago" or why not.
    public func freshnessText(now: Date = Date()) -> String {
        // Only when the label is on. The harness that draws the store listing runs the
        // same sample data with the label off, because a listing shows the app as it
        // looks once it is configured — the caveat belongs to the demo a person can
        // reach, where it is the whole point.
        if isDemo { return demoIsLabelled ? "Demo data — not from Fireworks" : "updated just now" }
        guard let reading else {
            switch status {
            case .needsKey(let reason): return reason
            case .needsAnchor:
                return keySource.isEmpty
                    ? "Paste your Fireworks API key to fetch your first balance"
                    : "Waiting for the first balance from Fireworks"
            default: return "No reading yet"
            }
        }
        let age = Time.humanAge(reading.age(now: now))
        switch status {
        case .refreshing: return "refreshing… · last good reading \(age)"
        case .failed(let why): return "refresh failed (\(why)) · showing \(age)"
        default: return "updated \(age)"
        }
    }

    /// Whether there is a reading to draw: a measured one, or the demo's. The views ask
    /// this rather than `config.isAnchored`, because the demo has no anchor and is still
    /// meant to be drawn.
    public var showsReading: Bool {
        reading != nil && (config.isAnchored || isDemo)
    }

    public var isConfigured: Bool {
        if case .needsAnchor = status { return false }
        if case .needsKey = status { return false }
        return true
    }

    // MARK: - the key

    /// Items holding the same key: the SwiftBar plugin's service name is tried
    /// first, so an app installed over the plugin uses the key the user already
    /// trusted instead of asking for it again.
    private var keychainServices: [String] { ["fireworks-menubar", KeyStore.defaultService] }

    /// Keychain first (both services), then the key file, then the environment. `KeyStore.read` owns the validation and the wording
    /// of each failure, so this only decides *which* place to look in.
    private func resolveKey() throws -> (key: String, source: String) {
        for service in keychainServices where KeyStore.keychainKey(service: service) != nil {
            return try KeyStore.read(service: service, directory: SharedContainer.directory)
        }
        return try KeyStore.read(service: nil, directory: SharedContainer.directory)
    }

    /// First run: take the balance Fireworks reports and remember it.
    ///
    /// The figure is the gateway's, not the user's, so there is nothing to fill in.
    /// This only fills the gap — a balance already remembered is never overwritten
    /// here — so a fresh install measures something immediately and has a fallback
    /// ready if the gateway later goes quiet.
    private func rememberLiveBalance() async -> Double? {
        guard !config.isAnchored else { return nil }
        guard let found = try? resolveKey() else { return nil }
        keySource = found.source
        let client = FireworksClient(apiKey: found.key, account: config.account)
        guard let resolved = try? await client.resolvedAccount(),
              let balance = try? await client.balance(),
              balance.amount > 0 else { return nil }
        account = resolved
        config.account = resolved
        rememberBalance(balance.amount, at: balance.fetchedAt)
        return balance.amount
    }

    // MARK: - settings

    /// Fill the one gap a fresh install has: no figure to show until the first refresh
    /// lands. The value is Fireworks', never the user's — there is no setting here, and
    /// a balance already remembered is not overwritten.
    public func rememberBalance(_ amount: Double, at when: Date = Date()) {
        config.anchorBalance = amount
        config.anchorTime = when
        config.normalise()
        _ = try? ConfigStore.save(config, to: SharedContainer.directory)
        if case .needsAnchor = status { status = .idle }
    }

    public func saveKey(_ key: String) throws {
        let cleaned = try KeyStore.validate(key, source: "the key you pasted")
        guard KeyStore.saveKeychain(cleaned, service: KeyStore.defaultService) else {
            throw FireworksError(kind: .setup(
                "Could not save the key to the Keychain — the prompt may have been denied"))
        }
        // A real key ends the demo: the next refresh measures the account, and leaving
        // the sample on screen until it lands would mix the two.
        if isDemo { exitDemo() }
        keySource = "keychain:\(KeyStore.defaultService)"
    }

    public func forgetKey() {
        KeyStore.deleteKeychain(service: KeyStore.defaultService)
        keySource = ""
    }

    // MARK: - demo

    /// Show sample numbers so the app can be read without a key — what an App Review
    /// reviewer sees, and what someone deciding whether to paste a key sees.
    ///
    /// Deliberately a button and never a default. A shipped build must not install a
    /// fake balance on its own, because these figures are indistinguishable from
    /// measured ones; so this only happens because someone asked for it, and everything
    /// drawn while it is on says what it is.
    public func startDemo() {
        reading = DemoReading.make()
        isDemo = true
        demoIsLabelled = true
        status = .idle
        lastError = nil
        Diagnostics.log("demo: on (sample reading; nothing is saved and no alert is sent)")
    }

    /// Back to whatever is real: the remembered reading, or the setup card.
    public func exitDemo() {
        guard isDemo else { return }
        isDemo = false
        demoIsLabelled = true
        reading = ReadingStore.load(from: SharedContainer.directory)
        status = config.isAnchored ? .idle : .needsAnchor
        Diagnostics.log("demo: off (reading=\(reading != nil ? "remembered" : "none"))")
    }

    public func update(_ mutate: (inout FireworksConfig) -> Void) {
        mutate(&config)
        config.normalise()
        _ = try? ConfigStore.save(config, to: SharedContainer.directory)
        // Turning alerts on is the one moment the user has asked for them, so
        // that — not launch — is when the permission prompt makes sense.
        if config.notify {
            Task { await notifier.ensureAuthorised() }
        }
    }

    public func testNotification() async -> Bool {
        _ = await notifier.ensureAuthorised()
        // A notification outlives the screen it came from, so in the demo the test alert
        // carries no figure at all: a sample balance in a notification is the one place
        // it could be mistaken for the account's.
        let message = isDemo ? "Fireworks alerts are on"
                             : "Fireworks \(Money.formatted(reading?.remaining ?? 0)) left"
        let subtitle = isDemo ? "Demo mode — no real balance is used"
                              : "This is what a credit alert looks like"
        return await notifier.send(AlertEvent(kind: .spend, message: message, subtitle: subtitle))
    }

    #if DEBUG
    /// Replace the reading with the sample one, for `--render-ui-sample`.
    ///
    /// The same figures the demo shows, from `DemoReading`, but installed without the
    /// demo label: this path exists to draw the panels used in the README, and a badge
    /// on every documentation screenshot would be noise. It stays `#if DEBUG` — a
    /// shipped build must never install a fake balance on its own, and the path a person
    /// can actually reach is `startDemo()`, which says what it is.
    public func previewInstallSampleReading() {
        reading = DemoReading.make()
        // Sample data with the label off: the harness is drawing what a configured app
        // looks like, and the safety rules still apply because `isDemo` is set.
        isDemo = true
        demoIsLabelled = false
        status = .idle
    }
    #endif
}
