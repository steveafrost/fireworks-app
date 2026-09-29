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
    public private(set) var status: Status = .idle
    /// Where the key came from, shown in Settings so "which key am I using" is
    /// answerable without guessing.
    public private(set) var keySource: String = ""
    public private(set) var lastError: String?
    public private(set) var account: String = ""

    private let service = RefreshService()
    private var loop: Task<Void, Never>?
    private let notifier = Notifier()

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
        let pluginPath = SharedContainer.pluginDirectory?.path ?? "—"
        let migrated = carried.isEmpty ? "nothing" : carried.joined(separator: ",")
        let anchorStamp = config.anchorTime.map { Time.isoUTC($0) } ?? "—"
        Diagnostics.log("launch: data=\(dataPath) plugin=\(pluginPath) migrated=\(migrated) "
                        + "anchored=\(config.isAnchored) anchor=\(config.anchorBalance)@\(anchorStamp) "
                        + "cached_reading=\(reading != nil)")
    }

    /// One instance per process. The Mac app's refresh loop is started by the app
    /// delegate, so the popover and the menu-bar label have to observe the *same*
    /// model rather than each creating one on first draw.
    public static let shared = AppModel()

    // MARK: - lifecycle

    /// Refresh now, then keep refreshing on the configured cadence.
    public func start() async {
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
        guard config.isAnchored else {
            status = .needsAnchor
            Diagnostics.log("refresh: skipped — no anchor yet (balance=\(config.anchorBalance))")
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
        guard let reading else {
            switch status {
            case .needsKey(let reason): return reason
            case .needsAnchor: return "Set the balance you hold to start measuring"
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

    // MARK: - settings

    public func setAnchor(_ amount: Double, at when: Date = Date()) {
        config.anchorBalance = amount
        config.anchorTime = when
        config.normalise()
        _ = try? ConfigStore.save(config, to: SharedContainer.directory)
        if case .needsAnchor = status { status = .idle }
    }

    public func reanchorTime(_ when: Date) {
        config.anchorTime = when
        _ = try? ConfigStore.save(config, to: SharedContainer.directory)
    }

    public func saveKey(_ key: String) throws {
        let cleaned = try KeyStore.validate(key, source: "the key you pasted")
        guard KeyStore.saveKeychain(cleaned, service: KeyStore.defaultService) else {
            throw FireworksError(kind: .setup(
                "Could not save the key to the Keychain — the prompt may have been denied"))
        }
        keySource = "keychain:\(KeyStore.defaultService)"
    }

    public func forgetKey() {
        KeyStore.deleteKeychain(service: KeyStore.defaultService)
        keySource = ""
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
        return await notifier.send(AlertEvent(kind: .spend,
                                              message: "Fireworks \(Money.formatted(reading?.remaining ?? 0)) left",
                                              subtitle: "This is what a credit alert looks like"))
    }

    #if DEBUG
    /// Replace the reading with a synthetic one, for `--render-ui-sample`.
    /// Deliberately loud about it: a preview state must never be mistaken for
    /// measured data.
    public func previewInstallSampleReading() {
        let now = Date()
        reading = Reading(remaining: 2.34, spend: 17.66, today: 1.94, models: [
            "accounts/fireworks/models/deepseek-v4p1-flash": 9.42,
            "accounts/fireworks/models/glm-5p3-flash": 6.10,
            "accounts/fireworks/models/qwen3-coder-480b": 1.64,
            "accounts/fireworks/models/llama-v3p3-70b": 0.50
        ], days: (0..<7).map { offset in
            let day = Calendar.current.date(byAdding: .day, value: offset - 6, to: now) ?? now
            return DayTotal(date: Time.label(for: day),
                            cost: [0.11, 1.94, 1.27, 0.11, 0, 0.09, 1.94][offset],
                            today: offset == 6)
        }, hours: 96, hoursToday: 14, anchorBalance: 20.00,
           anchorTime: now.addingTimeInterval(-4 * 86_400), fetchedAt: now)
        status = .idle
    }
    #endif
}
