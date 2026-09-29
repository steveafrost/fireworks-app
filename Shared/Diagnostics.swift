import Foundation
import OSLog
import FireworksCore

/// A plain-text trail of what the app did, in the same folder as its data.
///
/// A menu-bar app has nowhere to show a stack trace: when a refresh produces no
/// number, the question is always "where did it stop — the key, the anchor, the
/// network?", and the popover can only show one line of it. This file answers that
/// and is the first thing to ask for in a bug report.
///
/// Two sinks on purpose. `os.Logger` cannot fail silently and is visible in
/// Console; the file is the one a user can send. Every write is best-effort —
/// logging must never be the reason a refresh did not happen.
public enum Diagnostics {
    private static let logger = Logger(subsystem: "com.whitebox.fireworks", category: "app")
    private static let fileName = "diagnostics.log"
    private static let maxBytes = 256 * 1024

    public static var url: URL { SharedContainer.directory.appendingPathComponent(fileName) }

    /// Where the log goes if the shared folder is not writable. A menu-bar app
    /// still owes the user a way to see what went wrong.
    private static var fallbackURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Fireworks", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        #if DEBUG
        // Visible when the binary is run from a terminal, which is how a launch
        // failure gets diagnosed.
        print("FIREWORKS \(message)")
        #endif
        append("\(ISO8601DateFormatter().string(from: Date()))  \(message)\n", to: url, fallback: fallbackURL)
    }

    private static func append(_ line: String, to file: URL, fallback: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if write(data, to: file) {
            trim(file)
            return
        }
        if write(data, to: fallback) {
            trim(fallback)
        }
    }

    private static func write(_ data: Data, to file: URL) -> Bool {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) != nil, (try? handle.write(contentsOf: data)) != nil {
                return true
            }
        }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// Keep the newest tail: a log that grows forever on a machine nobody looks at
    /// is a bug of its own.
    private static func trim(_ file: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int, size > maxBytes,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n").suffix(500).joined(separator: "\n")
        try? (kept + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// The last lines, for Settings → Diagnostics and for a bug report.
    public static func tail(_ lines: Int = 40) -> String {
        for candidate in [url, fallbackURL] {
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
            }
        }
        return "No diagnostics yet — the app has not written any."
    }
}
