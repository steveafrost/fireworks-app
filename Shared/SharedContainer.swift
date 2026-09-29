import Foundation
import FireworksCore

/// Where the app and its widgets agree to meet.
///
/// Two candidate locations, *probed* rather than assumed:
///
/// * the **App Group container** — the only place a sandboxed iOS widget may
///   read, and the right answer on iOS. On macOS it exists only when the build is
///   signed with a profile that authorises the group, which an ad-hoc local build
///   is not.
/// * a plain **Application Support** folder — works on any Mac with no
///   entitlements at all, which is what a local build is.
///
/// The probe is why this is a function and not a `let`: a path that cannot be
/// written to must never be chosen silently, because the failure mode is an app
/// that launches perfectly and shows nothing forever.
public enum SharedContainer {
    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var cached: URL?

    public static var directory: URL {
        probeLock.lock()
        defer { probeLock.unlock() }
        if let cached { return cached }
        let chosen = candidates.first(where: isUsable) ?? preferred
        cached = chosen
        return chosen
    }

    /// The one to try first, and the one to report in diagnostics either way.
    private static var preferred: URL {
        #if os(iOS)
        if let group = AppGroup.containerURL {
            return group.appendingPathComponent("Fireworks", isDirectory: true)
        }
        #endif
        return supportDirectory.appendingPathComponent("Fireworks", isDirectory: true)
    }

    private static var candidates: [URL] {
        var list: [URL] = []
        if let group = AppGroup.containerURL {
            list.append(group.appendingPathComponent("Fireworks", isDirectory: true))
        }
        list.append(supportDirectory.appendingPathComponent("Fireworks", isDirectory: true))
        return list
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
    }

    /// Create it, then prove it can be written to: a directory that exists but is
    /// read-only is the same problem as one that does not exist.
    private static func isUsable(_ directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let probe = directory.appendingPathComponent(".probe")
        do {
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// The settings file: deliberately the *same name* the SwiftBar plugin used,
    /// so an app installed on a Mac that ran the plugin inherits the anchor,
    /// thresholds and alert history instead of asking for them again.
    public static var configURL: URL { ConfigStore.url(in: directory) }
    public static var cacheURL: URL { ReadingStore.url(in: directory) }

    public static func prepare() {
        // Touching `directory` runs the probe, which creates the folder.
        _ = directory
    }

    /// The Mac path the SwiftBar plugin used, if this Mac ever ran it.
    ///
    /// A user migrating from the plugin should not have to re-enter the balance
    /// they set, or find their key file again. The originals are left untouched —
    /// the app *copies*, so uninstalling the app cannot damage the plugin's setup.
    public static var pluginDirectory: URL? {
        #if os(macOS)
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/fireworks-menubar", isDirectory: true)
        #else
        return nil
        #endif
    }

    /// Copy the plugin's settings and key in, once, only where the app has none.
    ///
    /// Returns what was carried over, for the first-run UI and for diagnostics.
    @discardableResult
    public static func migrateFromPlugin() -> [String] {
        #if os(macOS)
        guard let pluginDirectory, FileManager.default.fileExists(atPath: pluginDirectory.path) else {
            return []
        }
        var carried: [String] = []
        for file in ["config.json", "api_key"] {
            let source = pluginDirectory.appendingPathComponent(file)
            let destination = directory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: source.path),
                  !FileManager.default.fileExists(atPath: destination.path),
                  let contents = try? Data(contentsOf: source) else { continue }
            do {
                try contents.write(to: destination, options: .atomic)
                if file == "api_key" {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                          ofItemAtPath: destination.path)
                }
                carried.append(file)
            } catch {
                continue
            }
        }
        return carried
        #else
        return []
        #endif
    }
}
