import Foundation
import Security

/// Where the API key comes from, in a fixed order, with the Keychain first
/// whenever the user has opted into it.
///
/// The key is a bearer token for billing data: it gets a Keychain item, never
/// the settings file, never `UserDefaults`, and never a log line.
public enum KeyStore {
    public static let defaultService = "fireworks-app"
    public static let envVar = "FIREWORKS_API_KEY"
    public static let fileName = "api_key"

    /// A key the API can actually be called with: one line, ASCII, plausible length.
    ///
    /// A pasted paragraph, a stray arrow from a copy-paste, or two keys must be
    /// reported as a key problem — not allowed through to fail as an encoding
    /// error inside the HTTP layer.
    public static func validate(_ raw: String, source: String) throws -> String {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
        guard let key = lines.first else {
            throw FireworksError(kind: .setup("The API key in \(source) is empty"))
        }
        guard lines.count == 1 else {
            throw FireworksError(kind: .setup(
                "\(source) must contain one line — the API key — but it has \(lines.count) lines "
                + "of text. Replace it with just the key"))
        }
        guard key.allSatisfy({ $0.isASCII }) else {
            throw FireworksError(kind: .setup(
                "The API key in \(source) contains a non-ASCII character (a stray arrow or a "
                + "smart quote often creeps in from a copy-paste). Re-copy just the key itself"))
        }
        guard !key.contains(where: { $0.isWhitespace }) else {
            throw FireworksError(kind: .setup(
                "The API key in \(source) has whitespace inside it — it should be a single "
                + "unbroken token"))
        }
        guard key.count >= 16 else {
            throw FireworksError(kind: .setup(
                "The API key in \(source) is too short (\(key.count) characters) to be a "
                + "Fireworks key"))
        }
        guard key.count <= 512 else {
            throw FireworksError(kind: .setup(
                "The API key in \(source) is implausibly long (\(key.count) characters) — "
                + "is more than the key in that file?"))
        }
        return key
    }

    /// `(key, where it came from)`. Throws a setup error naming the fix when there
    /// is no usable key anywhere — a missing key must never look like an outage,
    /// and must never fall back to a stale reading.
    public static func read(service: String?, directory: URL,
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (key: String, source: String) {
        if let service, !service.isEmpty {
            guard let key = keychainKey(service: service) else {
                throw FireworksError(kind: .setup(
                    "No API key in the Keychain under \"\(service)\". Save it from Settings, or "
                    + "paste the key again"))
            }
            return (try validate(key, source: "the Keychain item \"\(service)\""),
                    "keychain:\(service)")
        }
        let file = directory.appendingPathComponent(fileName)
        if let raw = try? String(contentsOf: file, encoding: .utf8) {
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw FireworksError(kind: .setup(
                    "The API key file at \(file.path) exists but is empty — paste your key in "
                    + "Settings"))
            }
            return (try validate(raw, source: file.path), file.path)
        }
        if let raw = environment[envVar], !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return (try validate(raw, source: "the \(envVar) environment variable"), envVar)
        }
        throw FireworksError(kind: .setup(
            "No Fireworks API key yet. Paste one from app.fireworks.ai → API keys"))
    }

    public static func writeFile(_ key: String, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try key.write(to: url, atomically: true, encoding: .utf8)
        // mode 600: the key is a bearer token for billing data
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Keychain

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: service]
    }

    /// The stored key, or nil when there is no item (or access was refused), so a
    /// denied prompt reads as "no key here" instead of crashing a refresh.
    public static func keychainKey(service: String) -> String? {
        var lookup = query(service: service)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Store (or replace) the key. `-U` semantics: a re-save replaces in place
    /// rather than leaving two items for the same service.
    @discardableResult
    public static func saveKeychain(_ key: String, service: String) -> Bool {
        let lookup = query(service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let update = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        var insert = lookup
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func deleteKeychain(service: String) -> Bool {
        let status = SecItemDelete(query(service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
