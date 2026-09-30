import XCTest
@testable import FireworksCore

/// The update feed's configuration is the one part of the app whose mistakes are
/// invisible at launch and permanent afterwards, so it is checked here.
final class UpdateFeedTests: XCTestCase {
    private let goodKey = "7XYFIMpgTrJrclrx/iIiVK8pH1l5oz7WRnEEZS59Nqg="

    func testReadsAWellFormedFeed() {
        let info: [String: Any] = [
            UpdateFeed.feedKey: "https://steveafrost.github.io/fireworks-app/appcast.xml",
            UpdateFeed.publicKeyKey: goodKey,
        ]
        XCTAssertEqual(UpdateFeed.url(in: info)?.absoluteString,
                       "https://steveafrost.github.io/fireworks-app/appcast.xml")
        XCTAssertNil(UpdateFeed.problem(in: info))
    }

    func testRejectsAFeedThatIsMissingOrNotHttps() {
        XCTAssertNil(UpdateFeed.url(in: [:]))
        XCTAssertNil(UpdateFeed.url(in: [UpdateFeed.feedKey: ""]))
        XCTAssertNil(UpdateFeed.url(in: [UpdateFeed.feedKey: "not a url"]))
        // Plain http: an update feed anyone on the path can rewrite.
        XCTAssertNil(UpdateFeed.url(in: [UpdateFeed.feedKey: "http://example.com/appcast.xml"]))
        // A directory, not a feed.
        XCTAssertNil(UpdateFeed.url(in: [UpdateFeed.feedKey: "https://example.com/updates/"]))
        // Whitespace from a copy-paste is forgiven.
        XCTAssertNotNil(UpdateFeed.url(in: [UpdateFeed.feedKey: " https://example.com/appcast.xml\n"]))
    }

    func testRejectsASigningKeyThatIsNotThirtyTwoBytes() {
        XCTAssertNil(UpdateFeed.publicKey(in: [:]))
        // Valid base64, wrong length: this is the mistake that looks fine.
        XCTAssertNil(UpdateFeed.publicKey(in: [UpdateFeed.publicKeyKey: Data(repeating: 7, count: 16).base64EncodedString()]))
        // Valid length, not base64.
        XCTAssertNil(UpdateFeed.publicKey(in: [UpdateFeed.publicKeyKey: String(repeating: "!", count: 44)]))
        XCTAssertEqual(UpdateFeed.publicKey(in: [UpdateFeed.publicKeyKey: " \(goodKey)\n"]), goodKey)
    }

    func testSaysWhatIsWrongWithABuildThatCannotUpdate() {
        XCTAssertNotNil(UpdateFeed.problem(in: [:]))
        XCTAssertNotNil(UpdateFeed.problem(in: [UpdateFeed.feedKey: "https://example.com/appcast.xml"]))
        XCTAssertNil(UpdateFeed.problem(in: [UpdateFeed.feedKey: "https://example.com/appcast.xml",
                                             UpdateFeed.publicKeyKey: goodKey]))
    }

    func testTheStatusLineSaysWhenItLastChecked() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)  // fixed, so this is not a flaky test
        XCTAssertEqual(UpdateFeed.statusHint(available: false, lastCheck: nil, now: now),
                       "Updates are delivered by the App Store on iPhone and iPad.")
        XCTAssertTrue(UpdateFeed.statusHint(available: true, lastCheck: nil, now: now).hasPrefix("Not checked yet"))
        XCTAssertEqual(UpdateFeed.statusHint(available: true, lastCheck: now.addingTimeInterval(-10), now: now),
                       "Checked just now.")
        XCTAssertTrue(UpdateFeed.statusHint(available: true, lastCheck: now.addingTimeInterval(-3600), now: now)
            .hasPrefix("Last checked today at "))
        XCTAssertTrue(UpdateFeed.statusHint(available: true, lastCheck: now.addingTimeInterval(-90_000), now: now)
            .hasPrefix("Last checked yesterday at "))
        XCTAssertTrue(UpdateFeed.statusHint(available: true, lastCheck: now.addingTimeInterval(-9 * 86_400), now: now)
            .hasPrefix("Last checked on "))
    }
}
