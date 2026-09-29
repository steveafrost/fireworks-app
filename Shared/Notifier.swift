import Foundation
import UserNotifications
import FireworksCore

/// Desktop and iOS notifications through the system framework.
///
/// The SwiftBar plugin had to shell out to `osascript` because a plugin has no
/// app identity. An app does: it can ask once for permission, post alerts that
/// survive being ignored, and be clicked. The trade is that authorisation can be
/// refused, so every path here is best-effort and never blocks a refresh.
public actor Notifier {
    private var authorised = false

    public init() {}

    /// Ask for permission only when there is something to ask *about*.
    ///
    /// A prompt in the first second of a first run is the prompt people decline —
    /// and on iOS it lands on top of onboarding, before the user has entered
    /// anything, which is worse. So this is called when an alert actually needs
    /// posting, or when the user explicitly asks for one.
    @discardableResult
    public func ensureAuthorised() async -> Bool {
        if authorised { return true }
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorised = true
        case .notDetermined:
            authorised = (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorised = false
        }
        return authorised
    }

    /// Post every planned event. Returns the kinds that were actually posted.
    @discardableResult
    public func deliver(_ events: [AlertEvent], enabled: Bool) async -> [AlertEvent.Kind] {
        guard enabled, !events.isEmpty else { return [] }
        guard await ensureAuthorised() else { return [] }
        var posted: [AlertEvent.Kind] = []
        for event in events where await send(event) {
            posted.append(event.kind)
        }
        return posted
    }

    @discardableResult
    public func send(_ event: AlertEvent) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.message
        if !event.subtitle.isEmpty { content.subtitle = event.subtitle }
        content.sound = .default
        // Identified by kind so a repeated crossing replaces rather than stacks.
        let request = UNNotificationRequest(identifier: "fireworks.\(event.kind.rawValue)",
                                            content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    public func currentAuthorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
