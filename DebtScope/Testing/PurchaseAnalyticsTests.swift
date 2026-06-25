#if canImport(XCTest)
import XCTest
@testable import DebtScope

final class PurchaseAnalyticsTests: XCTestCase {
    func testEventEncodesWorkerCompatibleFieldsOnly() throws {
        let event = PurchaseAnalyticsEvent(
            installId: "00000000-0000-0000-0000-000000000001",
            sessionId: "session-1",
            eventName: .purchaseResult,
            paywallSource: .settings,
            purchaseResult: .cancelled,
            productLoadState: .loaded,
            storefrontCountry: "US",
            appVersion: "1.2.3",
            buildNumber: "42",
            platform: "iOS",
            osVersion: "18.5",
            channel: .testflight
        )

        let data = try JSONEncoder().encode(event)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["installId"] as? String, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(payload["sessionId"] as? String, "session-1")
        XCTAssertEqual(payload["eventName"] as? String, "purchase_result")
        XCTAssertEqual(payload["paywallSource"] as? String, "settings")
        XCTAssertEqual(payload["purchaseResult"] as? String, "cancelled")
        XCTAssertEqual(payload["productLoadState"] as? String, "loaded")
        XCTAssertEqual(payload["storefrontCountry"] as? String, "US")
        XCTAssertEqual(payload["appVersion"] as? String, "1.2.3")
        XCTAssertEqual(payload["buildNumber"] as? String, "42")
        XCTAssertEqual(payload["platform"] as? String, "iOS")
        XCTAssertEqual(payload["osVersion"] as? String, "18.5")
        XCTAssertEqual(payload["channel"] as? String, "testflight")
        XCTAssertNil(payload["financialData"])
        XCTAssertNil(payload["accountName"])
        XCTAssertNil(payload["payee"])
    }

    func testInstallIDPersistsRandomUUID() throws {
        let suiteName = "PurchaseAnalyticsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PurchaseAnalyticsInstallID.current(defaults: defaults)
        let second = PurchaseAnalyticsInstallID.current(defaults: defaults)

        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, second)
    }

    func testDefaultAnalyticsEnabledForDistributedBuilds() {
        XCTAssertTrue(PurchaseAnalyticsAppInfo.defaultAnalyticsEnabled(for: .testflight))
        XCTAssertTrue(PurchaseAnalyticsAppInfo.defaultAnalyticsEnabled(for: .production))
        XCTAssertFalse(PurchaseAnalyticsAppInfo.defaultAnalyticsEnabled(for: .debug))
        XCTAssertFalse(PurchaseAnalyticsAppInfo.defaultAnalyticsEnabled(for: .sandbox))
    }

    func testStoredAnalyticsPreferenceOverridesDefault() throws {
        let suiteName = "PurchaseAnalyticsPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            PurchaseAnalyticsAppInfo.analyticsEnabled(defaults: defaults),
            PurchaseAnalyticsAppInfo.defaultAnalyticsEnabled
        )

        defaults.set(false, forKey: PurchaseAnalyticsAppInfo.analyticsEnabledKey)
        XCTAssertFalse(PurchaseAnalyticsAppInfo.analyticsEnabled(defaults: defaults))

        defaults.set(true, forKey: PurchaseAnalyticsAppInfo.analyticsEnabledKey)
        XCTAssertTrue(PurchaseAnalyticsAppInfo.analyticsEnabled(defaults: defaults))
    }

    func testDisabledClientDropsEvents() async {
        let session = PurchaseAnalyticsStubSession()
        let client = PurchaseAnalyticsClient(
            session: session,
            isEnabled: { false },
            isSuppressed: { false }
        )

        await client.track(Self.sampleEvent)

        XCTAssertEqual(session.requestCount, 0)
    }

    func testEnabledClientPostsJSONEvent() async throws {
        let session = PurchaseAnalyticsStubSession()
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/api/debtscope/purchase-events"))
        let client = PurchaseAnalyticsClient(
            endpointURL: endpoint,
            session: session,
            isEnabled: { true },
            isSuppressed: { false }
        )

        await client.track(Self.sampleEvent)

        let request = try XCTUnwrap(session.requests.first)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["eventName"] as? String, "paywall_impression")
        XCTAssertEqual(payload["paywallSource"] as? String, "settings")
    }

    func testQueueCapsEventsAndDropsOldest() async {
        let queue = PurchaseAnalyticsQueue(maxEventCount: 2, maxEventAge: 60)

        await queue.enqueue(Self.sampleEvent(named: .paywallImpression))
        await queue.enqueue(Self.sampleEvent(named: .purchaseButtonTap))
        await queue.enqueue(Self.sampleEvent(named: .restoreTap))

        let pending = await queue.pendingEvents()
        XCTAssertEqual(pending.map(\.eventName), [.purchaseButtonTap, .restoreTap])
    }

    func testQueueDropsExpiredEvents() async {
        let queue = PurchaseAnalyticsQueue(maxEventCount: 5, maxEventAge: 60)
        let oldDate = Date(timeIntervalSinceNow: -120)

        await queue.enqueue(Self.sampleEvent(named: .paywallImpression), queuedAt: oldDate)
        await queue.enqueue(Self.sampleEvent(named: .restoreTap), queuedAt: Date())

        let pending = await queue.pendingEvents(now: Date())
        XCTAssertEqual(pending.map(\.eventName), [.restoreTap])
    }

    private static var sampleEvent: PurchaseAnalyticsEvent {
        sampleEvent(named: .paywallImpression)
    }

    private static func sampleEvent(named eventName: PurchaseAnalyticsEventName) -> PurchaseAnalyticsEvent {
        PurchaseAnalyticsEvent(
            installId: "00000000-0000-0000-0000-000000000001",
            eventName: eventName,
            paywallSource: .settings,
            appVersion: "1.0",
            buildNumber: "1",
            platform: "iOS",
            osVersion: "18.5",
            channel: .debug
        )
    }
}

private final class PurchaseAnalyticsStubSession: PurchaseAnalyticsHTTPSession, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    var requestCount: Int {
        lock.withLock { storedRequests.count }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { storedRequests.append(request) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data("{\"ok\":true}".utf8), response)
    }
}
#endif
