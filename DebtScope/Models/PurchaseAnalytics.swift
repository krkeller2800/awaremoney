import Foundation

extension PaywallSource: Sendable {}

enum PurchaseAnalyticsEventName: String, Codable, CaseIterable, Sendable {
    case paywallImpression = "paywall_impression"
    case purchaseButtonTap = "purchase_button_tap"
    case purchaseResult = "purchase_result"
    case productLoadResult = "product_load_result"
    case restoreTap = "restore_tap"
    case restoreResult = "restore_result"
}

enum PurchaseAnalyticsResult: String, Codable, CaseIterable, Sendable {
    case success
    case cancelled
    case pending
    case unverified
    case failed
    case restored
    case noneFound = "none_found"
}

enum PurchaseAnalyticsProductLoadResult: String, Codable, CaseIterable, Sendable {
    case loaded
    case empty
    case failed
}

enum PurchaseAnalyticsProductLoadState: String, Codable, CaseIterable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed
}

enum PurchaseAnalyticsChannel: String, Codable, CaseIterable, Sendable {
    case production
    case testflight
    case debug
    case sandbox
}

struct PurchaseAnalyticsEvent: Codable, Equatable, Sendable {
    var installId: String
    var sessionId: String?
    var eventName: PurchaseAnalyticsEventName
    var paywallSource: PaywallSource?
    var purchaseResult: PurchaseAnalyticsResult?
    var productLoadResult: PurchaseAnalyticsProductLoadResult?
    var productLoadState: PurchaseAnalyticsProductLoadState?
    var storefrontCountry: String?
    var appVersion: String?
    var buildNumber: String?
    var platform: String
    var osVersion: String
    var channel: PurchaseAnalyticsChannel

    init(
        installId: String,
        sessionId: String? = nil,
        eventName: PurchaseAnalyticsEventName,
        paywallSource: PaywallSource? = nil,
        purchaseResult: PurchaseAnalyticsResult? = nil,
        productLoadResult: PurchaseAnalyticsProductLoadResult? = nil,
        productLoadState: PurchaseAnalyticsProductLoadState? = nil,
        storefrontCountry: String? = nil,
        appVersion: String? = PurchaseAnalyticsAppInfo.appVersion,
        buildNumber: String? = PurchaseAnalyticsAppInfo.buildNumber,
        platform: String = PurchaseAnalyticsAppInfo.platform,
        osVersion: String = PurchaseAnalyticsAppInfo.osVersion,
        channel: PurchaseAnalyticsChannel = PurchaseAnalyticsAppInfo.channel
    ) {
        self.installId = installId
        self.sessionId = sessionId
        self.eventName = eventName
        self.paywallSource = paywallSource
        self.purchaseResult = purchaseResult
        self.productLoadResult = productLoadResult
        self.productLoadState = productLoadState
        self.storefrontCountry = storefrontCountry
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.platform = platform
        self.osVersion = osVersion
        self.channel = channel
    }
}

enum PurchaseAnalyticsInstallID {
    private static let key = "purchase_analytics_install_id"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: key), UUID(uuidString: stored) != nil {
            return stored
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }
}

enum PurchaseAnalyticsAppInfo {
    nonisolated static let analyticsEnabledKey = "analytics_enabled"

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var platform: String {
        "iOS"
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    nonisolated static var channel: PurchaseAnalyticsChannel {
        #if DEBUG
        return .debug
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return .testflight
        }
        return .production
        #endif
    }

    nonisolated static var defaultAnalyticsEnabled: Bool {
        defaultAnalyticsEnabled(for: channel)
    }

    nonisolated static func defaultAnalyticsEnabled(for channel: PurchaseAnalyticsChannel) -> Bool {
        channel == .testflight || channel == .production
    }

    nonisolated static func analyticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        if let storedValue = defaults.object(forKey: analyticsEnabledKey) as? Bool {
            return storedValue
        }
        return defaultAnalyticsEnabled
    }
}

protocol PurchaseAnalyticsHTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: PurchaseAnalyticsHTTPSession {}

actor PurchaseAnalyticsQueue {
    private struct QueuedEvent: Sendable {
        var event: PurchaseAnalyticsEvent
        var queuedAt: Date
    }

    private let maxEventCount: Int
    private let maxEventAge: TimeInterval
    private var events: [QueuedEvent] = []

    init(maxEventCount: Int = 50, maxEventAge: TimeInterval = 3 * 24 * 60 * 60) {
        self.maxEventCount = max(1, maxEventCount)
        self.maxEventAge = max(60, maxEventAge)
    }

    func enqueue(_ event: PurchaseAnalyticsEvent, queuedAt: Date = Date()) {
        purgeExpired(now: queuedAt)
        events.append(QueuedEvent(event: event, queuedAt: queuedAt))
        if events.count > maxEventCount {
            events.removeFirst(events.count - maxEventCount)
        }
    }

    func pendingEvents(now: Date = Date()) -> [PurchaseAnalyticsEvent] {
        purgeExpired(now: now)
        return events.map(\.event)
    }

    func replacePendingEvents(with pendingEvents: [PurchaseAnalyticsEvent], now: Date = Date()) {
        events = pendingEvents.map { QueuedEvent(event: $0, queuedAt: now) }
        if events.count > maxEventCount {
            events.removeFirst(events.count - maxEventCount)
        }
    }

    func removeAll() {
        events.removeAll()
    }

    var count: Int {
        events.count
    }

    private func purgeExpired(now: Date) {
        events.removeAll { now.timeIntervalSince($0.queuedAt) > maxEventAge }
    }
}

actor PurchaseAnalyticsClient {
    static let defaultEndpointURL = URL(string: "https://komakode.com/api/debtscope/purchase-events")!

    private let endpointURL: URL
    private let session: PurchaseAnalyticsHTTPSession
    private let queue: PurchaseAnalyticsQueue
    private let isEnabled: @Sendable () -> Bool
    private let isSuppressed: @Sendable () -> Bool
    init(
        endpointURL: URL = PurchaseAnalyticsClient.defaultEndpointURL,
        session: PurchaseAnalyticsHTTPSession? = nil,
        queue: PurchaseAnalyticsQueue = PurchaseAnalyticsQueue(),
        isEnabled: @escaping @Sendable () -> Bool = { false },
        isSuppressed: @escaping @Sendable () -> Bool = PurchaseAnalyticsClient.shouldSuppressAnalytics
    ) {
        self.endpointURL = endpointURL
        self.session = session ?? Self.makeDefaultSession()
        self.queue = queue
        self.isEnabled = isEnabled
        self.isSuppressed = isSuppressed
    }

    func track(_ event: PurchaseAnalyticsEvent) async {
        guard isEnabled(), !isSuppressed() else { return }
        await queue.enqueue(event)
        await flush()
    }

    func flush() async {
        guard isEnabled(), !isSuppressed() else { return }

        let pendingEvents = await queue.pendingEvents()
        guard !pendingEvents.isEmpty else { return }

        var unsentEvents: [PurchaseAnalyticsEvent] = []
        for (index, event) in pendingEvents.enumerated() {
            do {
                try await send(event)
            } catch {
                unsentEvents.append(event)
                unsentEvents.append(contentsOf: pendingEvents.dropFirst(index + 1))
                break
            }
        }

        await queue.replacePendingEvents(with: unsentEvents)
    }

    private func send(_ event: PurchaseAnalyticsEvent) async throws {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try await MainActor.run {
            try JSONEncoder().encode(event)
        }

        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    private nonisolated static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private static func shouldSuppressAnalytics() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }
}
