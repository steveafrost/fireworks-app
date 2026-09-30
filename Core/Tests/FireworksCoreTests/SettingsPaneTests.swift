import XCTest
@testable import FireworksCore

/// The settings window's navigation, held to what the app can actually say.
final class SettingsPaneTests: XCTestCase {
    func testEveryPaneIsPresentableAndDistinct() {
        XCTAssertEqual(SettingsPane.allCases.count, 6)
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.title.isEmpty, "\(pane) has no title")
            XCTAssertFalse(pane.subtitle.isEmpty, "\(pane) has no subtitle")
            // SF Symbols are dotted paths or single lowercase words ("gearshape"),
            // so the check is the character set, not a dot: a name with a space or
            // a capital in it is a typo that draws an empty row rather than an
            // error anyone would see.
            XCTAssertFalse(pane.symbol.isEmpty, "\(pane) has no symbol")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._")
            XCTAssertTrue(pane.symbol.unicodeScalars.allSatisfy(allowed.contains),
                          "\(pane.symbol) is not shaped like a symbol name")
        }
        let titles = SettingsPane.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two panes share a title")
        let symbols = SettingsPane.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "two panes share a symbol")
    }

    func testOnlyThePanesWithSomethingToSayCarryABadge() {
        // A badge is a claim about the world, so the four panes that have no
        // measurement behind them must not have one.
        for pane in [SettingsPane.account, .alerts, .general, .about] {
            XCTAssertNil(SettingsPane.badge(for: pane, reading: nil, availableUpdate: "1.1"))
        }
        XCTAssertNil(SettingsPane.badge(for: .balance, reading: nil, availableUpdate: nil))
        XCTAssertNil(SettingsPane.badge(for: .updates, reading: nil, availableUpdate: nil))
    }

    func testTheBalanceBadgeIsTheRemainingFigureAndTheUpdateBadgeIsTheVersion() {
        let reading = Reading(remaining: 7.36, spend: 3.85, today: 3.65, models: [:], days: [],
                              hours: 96, hoursToday: 14, anchorBalance: 11.21,
                              anchorTime: .init(timeIntervalSince1970: 1_760_000_000),
                              fetchedAt: .init(timeIntervalSince1970: 1_760_400_000),
                              liveBalance: 7.36)
        XCTAssertEqual(SettingsPane.badge(for: .balance, reading: reading, availableUpdate: nil),
                       Money.formatted(7.36))
        XCTAssertEqual(SettingsPane.badge(for: .updates, reading: reading, availableUpdate: "1.1"), "1.1")
        // An offered update does not leak into the balance badge, and a balance
        // does not appear beside Updates.
        XCTAssertEqual(SettingsPane.badge(for: .balance, reading: reading, availableUpdate: "1.1"),
                       Money.formatted(7.36))
        XCTAssertNil(SettingsPane.badge(for: .updates, reading: reading, availableUpdate: nil))
    }
}
