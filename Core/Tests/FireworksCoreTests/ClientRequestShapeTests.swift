import XCTest
@testable import FireworksCore

/// A session that answers from a table instead of the network, and records what
/// was asked for. The engine takes its `URLSession` as a parameter precisely so
/// this is possible: the request shapes — which URL, which method — are the part
/// that broke in the field, not the arithmetic.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let path = request.url?.path ?? ""
        let (status, body) = Self.routes[path] ?? (501, #"{"message":"Method Not Allowed"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/2", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        routes = [:]
        requests = []
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// The account id has to survive from resolution into every later request.
///
/// This is a regression test for a bug that only appeared on a device with no
/// pinned account: the client resolved the account, reported it, and then built
/// `POST /v1/accounts/usageCosts:query` without it — which the API answers with
/// 501 Method Not Allowed. Pinning an account in the config hid it completely.
final class ClientRequestShapeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        StubProtocol.routes["/v1/accounts"] = (200, #"{"accounts":[{"name":"accounts/f12057"}]}"#)
        StubProtocol.routes["/v1/accounts/f12057/usageCosts:query"] = (200, #"{"rows":[]}"#)
    }

    func testAResolvedAccountIsUsedInEveryLaterRequest() async throws {
        // no account configured — the fresh-install and phone case
        let client = FireworksClient(apiKey: "fw_test_key", account: "", session: StubProtocol.session)
        let resolved = try await client.resolvedAccount()
        XCTAssertEqual(resolved, "f12057")

        _ = try await client.costs(start: Date(timeIntervalSince1970: 0),
                                   end: Date(timeIntervalSince1970: 3600))

        let paths = StubProtocol.requests.compactMap { $0.url?.path }
        XCTAssertTrue(paths.contains("/v1/accounts/f12057/usageCosts:query"),
                      "the resolved account must be in the cost URL, got \(paths)")
        XCTAssertFalse(paths.contains("/v1/accounts/usageCosts:query"),
                       "an account-less cost URL is the 501 bug")
    }

    func testAPinnedAccountSkipsResolutionEntirely() async throws {
        let client = FireworksClient(apiKey: "fw_test_key", account: "f12057", session: StubProtocol.session)
        let resolved = try await client.resolvedAccount()
        XCTAssertEqual(resolved, "f12057")
        XCTAssertTrue(StubProtocol.requests.isEmpty, "a pinned account needs no lookup")
    }

    func testACostQueryPostsItsWindowAsJSON() async throws {
        let client = FireworksClient(apiKey: "fw_test_key", account: "f12057", session: StubProtocol.session)
        _ = try await client.costs(start: Date(timeIntervalSince1970: 0),
                                   end: Date(timeIntervalSince1970: 3600))
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testA501NamesTheRequestSoItCanBeActedOn() async throws {
        // nothing routes, so the stub answers 501 the way the API did
        StubProtocol.routes["/v1/accounts/f12057/usageCosts:query"] = (501, #"{"message":"Method Not Allowed"}"#)
        let client = FireworksClient(apiKey: "fw_test_key", account: "f12057", session: StubProtocol.session)
        do {
            _ = try await client.costs(start: Date(timeIntervalSince1970: 0),
                                       end: Date(timeIntervalSince1970: 3600))
            XCTFail("expected a 501 to throw")
        } catch let error as FireworksError {
            let text = error.errorDescription ?? ""
            XCTAssertTrue(text.contains("501"), text)
            XCTAssertTrue(text.contains("usageCosts:query"), text)
        }
    }
}
