import Foundation

/// The settings window's panes, as data.
///
/// The window is a sidebar and a detail view, which means the navigation itself
/// is a thing that can be wrong — a pane with no title, two panes claiming the
/// same name, a badge that says something the app does not actually know. None of
/// that is visible to a test that draws the window (SwiftUI's `Form` renders as a
/// blank image offscreen, which is why this file exists), so the structure lives
/// here where `swift test` can hold it.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case account
    case balance
    case alerts
    case general
    case updates
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .account: "Account"
        case .balance: "Balance"
        case .alerts: "Alerts"
        case .general: "General"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    /// SF Symbols that have been in the system since long before macOS 14, so a
    /// name here cannot go missing on an older Mac and leave an empty row.
    public var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .balance: "dollarsign.circle"
        case .alerts: "bell"
        case .general: "gearshape"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }

    /// One line under the pane's title saying what the pane is for.
    public var subtitle: String {
        switch self {
        case .account: "The key the app reads, and the account it measures."
        case .balance: "What the menu bar figure is measured from."
        case .alerts: "When the app interrupts you."
        case .general: "How often it measures, and how much it keeps."
        case .updates: "Keeping the app current."
        case .about: "Version, data, and where the numbers come from."
        }
    }

    /// The one thing worth showing beside a pane's name, or nil for nothing.
    ///
    /// Only ever something the app actually knows: the balance it measured, and
    /// an update it has been offered. A badge on the other four would be
    /// decoration, and decoration in a navigation list reads as a status.
    public static func badge(for pane: SettingsPane, reading: Reading?, availableUpdate: String?) -> String? {
        switch pane {
        case .balance: reading.map { Money.formatted($0.remaining) }
        case .updates: availableUpdate
        case .account, .alerts, .general, .about: nil
        }
    }
}
