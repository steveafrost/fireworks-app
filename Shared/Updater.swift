import Foundation
import Combine
import FireworksCore
import UserNotifications
#if canImport(Sparkle)
import Sparkle
#endif

/// Sparkle, where the platform has it.
///
/// The Mac app is distributed outside the App Store, so updates arrive from an
/// appcast feed that Sparkle verifies against the Ed25519 key in Info.plist. The
/// iOS target is App-Store-shaped and has no Sparkle at all, so this type exists
/// in both targets and is inert in one of them: the Settings pane asks it whether
/// it is available instead of branching on the platform itself.
@MainActor
public final class Updater: ObservableObject {
    /// Whether this build can update itself at all.
    @Published public private(set) var isAvailable: Bool

    /// Sparkle's own setting, mirrored so a SwiftUI toggle can read it.
    @Published public var automaticallyChecks: Bool = true {
        didSet {
            #if canImport(Sparkle)
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
            #endif
        }
    }

    @Published public private(set) var lastCheck: Date?
    @Published public private(set) var canCheck = false

    /// The version string of an update Sparkle has found but that has not been
    /// installed yet, so Settings can offer it without the user having to go
    /// looking. Cleared when the user gives it attention or the session ends.
    @Published public private(set) var available: String?

    /// The feed this build would read, for Settings to show.
    public var feedURL: URL? { UpdateFeed.url(in: Bundle.main.infoDictionary ?? [:]) }

    /// A misconfigured feed or key, if this build has one.
    public var problem: String? {
        isAvailable ? UpdateFeed.problem(in: Bundle.main.infoDictionary ?? [:]) : nil
    }

    public var statusHint: String {
        UpdateFeed.statusHint(available: isAvailable, lastCheck: lastCheck)
    }

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    /// Held here because Sparkle keeps only a weak reference to its user driver
    /// delegate, and an update found while nobody is looking must not be lost to
    /// a deallocated reminder.
    private let reminders = UpdateReminders()
    #endif
    private var observers: [AnyCancellable] = []

    /// One per process, because a Sparkle user driver delegate has to be able to
    /// reach the updater that Sparkle itself is driving.
    public static let shared = Updater()

    public init() {
        #if canImport(Sparkle)
        isAvailable = true
        #else
        isAvailable = false
        #endif
    }

    /// Start checking. Deliberately not done in `init`: Sparkle installs its own
    /// menu item and may put a window on screen, and the offscreen render harness
    /// must do neither — it terminates before ever reaching this.
    public func start() {
        #if canImport(Sparkle)
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: reminders)
        self.controller = controller
        let updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        lastCheck = updater.lastUpdateCheckDate
        canCheck = updater.canCheckForUpdates

        // Sparkle is KVO-clean, so the pane follows the updater rather than
        // polling it: a check that finishes while Settings is open updates the
        // line the user is looking at.
        observers = [
            updater.publisher(for: \.lastUpdateCheckDate)
                .receive(on: RunLoop.main)
                .sink { [weak self] date in self?.lastCheck = date },
            updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] on in
                    guard let self, self.automaticallyChecks != on else { return }
                    self.automaticallyChecks = on
                },
            updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] can in self?.canCheck = can },
        ]
        #endif
    }

    /// Show Sparkle's update window. No-op where there is no Sparkle.
    public func checkForUpdates() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }

    // MARK: - gentle reminders

    /// Sparkle found an update. `showNow` says whether it is being put in front of
    /// the user already; when it is not, the reminder is what carries the news.
    func noteUpdate(version: String, showNow: Bool) {
        Diagnostics.log("update: found version=\(version) shownNow=\(showNow)")
        available = version
        guard !showNow else { return }
        postReminder(version: version)
    }

    /// The user has seen it, dismissed it, or the session ended.
    func noteUpdateSettled() {
        Diagnostics.log("update: settled")
        available = nil
    }

    /// Best-effort by design: if notifications are not allowed, nothing is posted
    /// and the update still shows up in Settings, which is the durable signal.
    private func postReminder(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Fireworks \(version) is available"
        content.body = "Open Fireworks ▸ Settings ▸ Updates to install it."
        content.sound = .default
        // Same identifier every time, so a daily check replaces its own reminder
        // instead of stacking a new one behind the last.
        let request = UNNotificationRequest(identifier: "fireworks.update",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

#if canImport(Sparkle)
/// Sparkle's standard user driver, made gentle.
///
/// A menu-bar app is a background app, and Sparkle says as much at launch:
/// "Background app automatically schedules for update checks but does not
/// implement gentle reminders. As a result, users may not take notice to update
/// alerts that show up in the background." Both halves of that are real — an
/// update window raised over whatever someone was doing, or an alert nobody ever
/// sees — so this is the documented answer to it: Sparkle takes the focus when it
/// already has the user's attention, and otherwise the reminder does the telling.
///
/// `MainActor.assumeIsolated` is a statement of fact rather than a shortcut:
/// Sparkle's user driver is a main-thread object and calls these from the main
/// thread. The class is separate from `Updater` because the protocol is
/// Objective-C and nonisolated, which a `@MainActor` type cannot satisfy directly.
final class UpdateReminders: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                             andInImmediateFocus immediateFocus: Bool) -> Bool {
        // True only when Sparkle would bring the alert into immediate focus — the
        // app was just launched, or the Mac has been idle. Otherwise this returns
        // false and `standardUserDriverWillHandleShowingUpdate` below is handed the
        // job, instead of a window appearing behind the user's work.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            // A check the user asked for always has its own window; there is
            // nothing to remind them about.
            guard !userInitiated else { return }
            Updater.shared.noteUpdate(version: version, showNow: handleShowingUpdate)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { Updater.shared.noteUpdateSettled() }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { Updater.shared.noteUpdateSettled() }
    }
}
#endif
