import Foundation
import Combine
import FireworksCore
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
    #endif
    private var observers: [AnyCancellable] = []

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
                                                      userDriverDelegate: nil)
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
}
