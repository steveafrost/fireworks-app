import XCTest
@testable import FireworksCore

final class RoughEdgeRegressionTests: XCTestCase {
    func testModelNamesAreNotPreTruncatedBeforeLayout() {
        XCTAssertEqual(
            Reading.shortModel("accounts/fireworks/models/deepseek-v4p1-flash"),
            "deepseek-v4p1-flash"
        )
    }
}
