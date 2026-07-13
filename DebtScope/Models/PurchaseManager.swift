import Foundation
import StoreKit
import SwiftUI
import Combine
import Security

private enum ImportAllowanceKeychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "com.debtscope.app" }

    static func saveInt(_ value: Int, account: String) {
        var raw = Int64(value)
        let data = withUnsafeBytes(of: &raw) { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func loadInt(account: String) -> Int? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        guard data.count == MemoryLayout<Int64>.size else { return nil }
        let value = data.withUnsafeBytes { $0.load(as: Int64.self) }
        return Int(value)
    }

    static func saveBool(_ value: Bool, account: String) {
        saveInt(value ? 1 : 0, account: account)
    }

    static func loadBool(account: String) -> Bool {
        loadInt(account: account) == 1
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#if DEBUG
struct PurchaseConversionDiagnostics: Codable, Equatable {
    var paywallImpressionsTotal: Int = 0
    var paywallImpressionsBySource: [PaywallSource: Int] = [:]
    var purchaseButtonTaps: Int = 0
    var successfulPurchases: Int = 0
    var cancelledPurchases: Int = 0
    var productLoadFailures: Int = 0

    mutating func recordPaywallImpression(source: PaywallSource) {
        paywallImpressionsTotal += 1
        paywallImpressionsBySource[source, default: 0] += 1
    }

    mutating func recordPurchaseButtonTap() {
        purchaseButtonTaps += 1
    }

    mutating func recordPurchaseSuccess() {
        successfulPurchases += 1
    }

    mutating func recordPurchaseCancellation() {
        cancelledPurchases += 1
    }

    mutating func recordProductLoadFailure() {
        productLoadFailures += 1
    }
}
#endif

@MainActor
final class PurchaseManager: ObservableObject {
    // MARK: - Configuration
    static let shared = PurchaseManager()

    // Non-consumable lifetime product
    private let productID = "com.komakode.awaremoney.lifetime"

    // App-side free import allowance; this is not an App Store trial.
    let freeImportLimit: Int = 4
    private let freeImportsUsedKey = "FreeImportsUsedCount"
    private let freeImportMigrationKey = "FreeImportAllowanceMigratedFromExistingImports"

    private var productShortCode: String {
        let parts = productID.split(separator: ".")
        return parts.last.map(String.init) ?? productID
    }

    private let analyticsClient: PurchaseAnalyticsClient
    private let analyticsSessionID = UUID().uuidString

    // MARK: - Published state
    @Published var product: Product?
    @Published private(set) var productLoadState: ProductLoadState = .idle
    @Published var isPurchased: Bool = false
    @Published var isPurchasing: Bool = false
    @Published var errorMessage: String?
    @Published var iapDiagnosticSummary: String? = nil
    @Published var userMessage: String? = nil
    @Published private(set) var freeImportsUsed: Int = 0

    #if DEBUG
    enum DebugPremiumOverride: String, CaseIterable, Identifiable {
        case useStoreKit
        case forcePremiumOn
        case forcePremiumOff

        var id: String { rawValue }

        var title: String {
            switch self {
            case .useStoreKit: return "Use StoreKit"
            case .forcePremiumOn: return "Force Premium On"
            case .forcePremiumOff: return "Force Premium Off"
            }
        }
    }

    private let debugPremiumOverrideKey = "DebugPremiumOverride"
    private let conversionDiagnosticsKey = "PurchaseConversionDiagnostics"
    @Published private(set) var conversionDiagnostics = PurchaseConversionDiagnostics() {
        didSet { saveConversionDiagnostics() }
    }

    @Published var debugPremiumOverride: DebugPremiumOverride = .useStoreKit {
        didSet {
            UserDefaults.standard.set(debugPremiumOverride.rawValue, forKey: debugPremiumOverrideKey)
        }
    }
    #endif

    /// The entitlement the rest of the app should honor. In debug builds this can be overridden for QA.
    var hasPremiumAccess: Bool {
        #if DEBUG
        switch debugPremiumOverride {
        case .useStoreKit:
            return isPurchased
        case .forcePremiumOn:
            return true
        case .forcePremiumOff:
            return false
        }
        #else
        return isPurchased
        #endif
    }

    enum ProductLoadState: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)

        var displayValue: String {
            switch self {
            case .idle:
                return "Not started"
            case .loading:
                return "Loading"
            case .loaded:
                return "Loaded"
            case .empty:
                return "No product returned"
            case .failed:
                return "Failed"
            }
        }
    }

    // Derived entitlement: premium access OR still has a free import available.
    var isPremiumUnlocked: Bool { hasPremiumAccess || canUseFreeImport }

    var canUseFreeImport: Bool {
        freeImportsRemaining > 0
    }

    var freeImportsRemaining: Int {
        max(0, freeImportLimit - freeImportsUsed)
    }

    var hasMigratedFreeImportAllowance: Bool {
        ImportAllowanceKeychain.loadBool(account: freeImportMigrationKey)
    }

    var freeImportStatusText: String {
        if hasPremiumAccess {
            return "Lifetime access active"
        }
        let remaining = freeImportsRemaining
        if remaining > 0 {
            return "Trial active: \(remaining) statement import\(remaining == 1 ? "" : "s") included"
        }
        return "Trial imports used. Unlock Lifetime Premium for unlimited local planning."
    }

    func synchronizeInitialFreeImportUsage(
        existingImportCount: Int,
        source: String = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let alreadyMigrated = hasMigratedFreeImportAllowance
        let migratedUsage = min(max(existingImportCount, 0), freeImportLimit)
        AMLogging.log(
            "Free import sync requested source=\(source) location=\(file):\(line) existingImportCount=\(existingImportCount) migratedUsage=\(migratedUsage) currentUsed=\(self.freeImportsUsed) alreadyMigrated=\(alreadyMigrated)",
            component: "PurchaseManager"
        )
        guard !alreadyMigrated else { return }
        if migratedUsage > freeImportsUsed {
            setFreeImportsUsed(
                migratedUsage,
                reason: "migration existingImportCount=\(existingImportCount)",
                source: source,
                file: file,
                line: line
            )
        }
        ImportAllowanceKeychain.saveBool(true, account: freeImportMigrationKey)
        AMLogging.log(
            "Free import migration flag saved source=\(source) location=\(file):\(line) used=\(self.freeImportsUsed)",
            component: "PurchaseManager"
        )
    }

    @discardableResult
    func recordCompletedImportIfNeeded(
        source: String = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Bool {
        AMLogging.log(
            "Free import record requested source=\(source) location=\(file):\(line) currentUsed=\(self.freeImportsUsed) remaining=\(self.freeImportsRemaining) hasPremiumAccess=\(self.hasPremiumAccess)",
            component: "PurchaseManager"
        )
        if hasPremiumAccess { return true }
        guard canUseFreeImport else { return false }
        setFreeImportsUsed(
            freeImportsUsed + 1,
            reason: "completed import",
            source: source,
            file: file,
            line: line
        )
        return true
    }

    func resetFreeImportAllowanceForDebug() {
        setFreeImportsUsed(0, reason: "debug reset")
        ImportAllowanceKeychain.saveBool(true, account: freeImportMigrationKey)
        AMLogging.log("Free import migration flag marked migrated after debug reset", component: "PurchaseManager")
    }

    #if DEBUG
    func resetConversionDiagnosticsForDebug() {
        conversionDiagnostics = PurchaseConversionDiagnostics()
    }

    private func updateConversionDiagnostics(_ update: (inout PurchaseConversionDiagnostics) -> Void) {
        update(&conversionDiagnostics)
    }

    private func saveConversionDiagnostics() {
        guard let data = try? JSONEncoder().encode(conversionDiagnostics) else { return }
        UserDefaults.standard.set(data, forKey: conversionDiagnosticsKey)
    }
    #endif

    private func setFreeImportsUsed(
        _ value: Int,
        reason: String,
        source: String = #function,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let previousValue = freeImportsUsed
        freeImportsUsed = max(0, min(value, freeImportLimit))
        ImportAllowanceKeychain.saveInt(freeImportsUsed, account: freeImportsUsedKey)
        AMLogging.log(
            "Free imports used changed reason=\(reason) source=\(source) location=\(file):\(line) previous=\(previousValue) requested=\(value) saved=\(self.freeImportsUsed) remaining=\(self.freeImportsRemaining)",
            component: "PurchaseManager"
        )
    }

    // MARK: - Init
    init(analyticsClient: PurchaseAnalyticsClient? = nil) {
        self.analyticsClient = analyticsClient ?? PurchaseAnalyticsClient(
            isEnabled: {
                PurchaseAnalyticsAppInfo.analyticsEnabled()
            }
        )
        freeImportsUsed = ImportAllowanceKeychain.loadInt(account: freeImportsUsedKey) ?? 0
        AMLogging.log(
            "Free imports loaded from Keychain used=\(self.freeImportsUsed) remaining=\(self.freeImportsRemaining) migrationFlag=\(self.hasMigratedFreeImportAllowance)",
            component: "PurchaseManager"
        )
        #if DEBUG
        if let data = UserDefaults.standard.data(forKey: conversionDiagnosticsKey),
           let diagnostics = try? JSONDecoder().decode(PurchaseConversionDiagnostics.self, from: data) {
            conversionDiagnostics = diagnostics
        }
        if let storedOverride = UserDefaults.standard.string(forKey: debugPremiumOverrideKey),
           let override = DebugPremiumOverride(rawValue: storedOverride) {
            debugPremiumOverride = override
        }
        #endif
        Task { await configure() }
    }

    // MARK: - Public API
    func purchase(source: PaywallSource = .unknown) async {
        guard let product else {
            recordPurchaseOutcome(.failed, source: source)
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    // Non-consumable purchased successfully
                    isPurchased = true
                    recordPurchaseOutcome(.success, source: source)
                    await transaction.finish()
                case .unverified(_, let error):
                    self.errorMessage = error.localizedDescription
                    recordPurchaseOutcome(.unverified, source: source)
                }
            case .userCancelled:
                recordPurchaseOutcome(.cancelled, source: source)
                break
            case .pending:
                // Pending (SCA or parental approval). Keep UI as-is.
                recordPurchaseOutcome(.pending, source: source)
                break
            @unknown default:
                recordPurchaseOutcome(.failed, source: source)
                break
            }
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recordPurchaseOutcome(.failed, source: source)
        }
    }

    func recordPaywallImpression(source: PaywallSource) {
        #if DEBUG
        updateConversionDiagnostics { $0.recordPaywallImpression(source: source) }
        #endif
        trackPurchaseAnalyticsEvent(.paywallImpression, paywallSource: source, productLoadState: analyticsProductLoadState)
    }

    func recordPurchaseButtonTap(source: PaywallSource) {
        #if DEBUG
        updateConversionDiagnostics { $0.recordPurchaseButtonTap() }
        #endif
        trackPurchaseAnalyticsEvent(.purchaseButtonTap, paywallSource: source, productLoadState: analyticsProductLoadState)
    }

    func restorePurchases(source: PaywallSource = .unknown) async {
        trackPurchaseAnalyticsEvent(.restoreTap, paywallSource: source)
        do {
            try await StoreKit.AppStore.sync()
            await updatePurchasedStatus()
            if isPurchased {
                self.userMessage = "Your Premium purchase is already active on this device."
                trackPurchaseAnalyticsEvent(.restoreResult, paywallSource: source, purchaseResult: .restored)
            } else {
                self.userMessage = "No previous purchases were found for your Apple ID."
                trackPurchaseAnalyticsEvent(.restoreResult, paywallSource: source, purchaseResult: .noneFound)
            }
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            trackPurchaseAnalyticsEvent(.restoreResult, paywallSource: source, purchaseResult: .failed)
        }
    }

    // MARK: - Setup
    private func configure() async {
        await loadProductWithRetry()
        await updatePurchasedStatus()
        listenForTransactions()
    }

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [productID])
            self.product = products.first
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
    
    @available(iOS 13.4, *)
    private func currentStorefrontID() async -> String {
        if #available(iOS 18.0, *) {
            if let sf = await Storefront.current {
                // Prefer country code for a short diagnostic label; identifier is also available.
                return sf.countryCode
            }
            return "-"
        } else {
            // Fallback for older systems (< iOS 18)
            if let sf = SKPaymentQueue.default().storefront {
                // Prefer country code for a short diagnostic label; identifier is also available.
                return sf.countryCode
            }
            return "-"
        }
    }
    
    private func loadProductWithRetry(maxAttempts: Int = 3, delay: TimeInterval = 1.5) async {
        self.iapDiagnosticSummary = "IAP: fetching • pid=\(productShortCode)"
        self.productLoadState = .loading
        self.product = nil
        self.errorMessage = nil
        var finalLoadOutcome: ProductLoadOutcome?
        for attempt in 1...maxAttempts {
            do {
                let products = try await Product.products(for: [productID])
                if let first = products.first {
                    self.product = first
                    self.productLoadState = .loaded
                    self.errorMessage = nil
                    let sf: String = await currentStorefrontID()
                    self.iapDiagnosticSummary = "IAP: ok • pid=\(productShortCode) • sf=\(sf)"
                    recordProductLoadOutcome(.success, storefrontCountry: sf)
                    return
                } else {
                    let sf: String = await currentStorefrontID()
                    self.iapDiagnosticSummary = "IAP: empty • pid=\(productShortCode) • sf=\(sf)"
                    finalLoadOutcome = .empty
                    // No products returned; will retry after a short delay
                }
            } catch {
                let msg: String = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.errorMessage = msg
                self.iapDiagnosticSummary = "IAP: error • pid=\(productShortCode) • \(msg)"
                finalLoadOutcome = .error
            }
            if attempt < maxAttempts {
                let ns: UInt64 = UInt64(delay * 1_000_000_000.0)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
        if self.product == nil && self.errorMessage == nil {
            self.errorMessage = "We couldn’t load purchase information. Please try again."
        }
        if self.product == nil {
            let sf: String = await currentStorefrontID()
            switch finalLoadOutcome {
            case .empty:
                self.productLoadState = .empty
                recordProductLoadOutcome(.empty, storefrontCountry: sf)
            case .error:
                self.productLoadState = .failed(self.errorMessage ?? "Unknown StoreKit error")
                recordProductLoadOutcome(.error, storefrontCountry: sf)
            case .success:
                self.productLoadState = .loaded
            case .none:
                self.productLoadState = .empty
                recordProductLoadOutcome(.empty, storefrontCountry: sf)
            }
            if self.iapDiagnosticSummary == nil || self.iapDiagnosticSummary?.isEmpty == true {
                self.iapDiagnosticSummary = "IAP: empty • pid=\(productShortCode) • sf=\(sf)"
            }
        }
    }

    func reloadProducts() async {
        await loadProductWithRetry()
    }

    private func updatePurchasedStatus() async {
        // Prefer latest transaction API for the specific product
        if let latest = await StoreKit.Transaction.latest(for: productID) {
            switch latest {
            case .verified(let transaction):
                // Non-consumable remains entitled unless revoked
                self.isPurchased = (transaction.revocationDate == nil)
            case .unverified(_, _):
                self.isPurchased = false
            }
            return
        }
        // Fallback: scan current entitlements
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            switch entitlement {
            case .verified(let transaction) where transaction.productID == productID:
                self.isPurchased = (transaction.revocationDate == nil)
                return
            default:
                continue
            }
        }
        self.isPurchased = false
    }

    private func listenForTransactions() {
        Task.detached { [weak self] in
            guard let self else { return }
            for await result in StoreKit.Transaction.updates {
                switch result {
                case .verified(let transaction) where transaction.productID == self.productID:
                    await MainActor.run {
                        self.isPurchased = (transaction.revocationDate == nil)
                    }
                    await transaction.finish()
                case .unverified(_, _):
                    continue
                default:
                    continue
                }
            }
        }
    }

    private enum PurchaseOutcome {
        case success
        case cancelled
        case pending
        case unverified
        case failed
    }

    private enum ProductLoadOutcome {
        case success
        case empty
        case error
    }

    private func recordPurchaseOutcome(_ outcome: PurchaseOutcome, source: PaywallSource) {
        #if DEBUG
        switch outcome {
        case .success:
            updateConversionDiagnostics { $0.recordPurchaseSuccess() }
        case .cancelled:
            updateConversionDiagnostics { $0.recordPurchaseCancellation() }
        case .pending, .unverified, .failed:
            break
        }
        #endif
        trackPurchaseAnalyticsEvent(.purchaseResult, paywallSource: source, purchaseResult: analyticsResult(for: outcome))
    }

    private func recordProductLoadOutcome(_ outcome: ProductLoadOutcome, storefrontCountry: String?) {
        #if DEBUG
        switch outcome {
        case .empty, .error:
            updateConversionDiagnostics { $0.recordProductLoadFailure() }
        case .success:
            break
        }
        #endif
        trackPurchaseAnalyticsEvent(
            .productLoadResult,
            productLoadResult: analyticsProductLoadResult(for: outcome),
            productLoadState: analyticsProductLoadState,
            storefrontCountry: storefrontCountry
        )
    }

    private var analyticsProductLoadState: PurchaseAnalyticsProductLoadState {
        switch productLoadState {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case .loaded:
            return .loaded
        case .empty:
            return .empty
        case .failed:
            return .failed
        }
    }

    private func trackPurchaseAnalyticsEvent(
        _ eventName: PurchaseAnalyticsEventName,
        paywallSource: PaywallSource? = nil,
        purchaseResult: PurchaseAnalyticsResult? = nil,
        productLoadResult: PurchaseAnalyticsProductLoadResult? = nil,
        productLoadState: PurchaseAnalyticsProductLoadState? = nil,
        storefrontCountry: String? = nil
    ) {
        // Purchase analytics intentionally stays app-facing and opt-out via Settings.
        guard PurchaseAnalyticsAppInfo.analyticsEnabled() else { return }

        // Field names are part of the KomoKode Worker compatibility contract.
        let event = PurchaseAnalyticsEvent(
            installId: PurchaseAnalyticsInstallID.current(),
            sessionId: analyticsSessionID,
            eventName: eventName,
            paywallSource: paywallSource,
            purchaseResult: purchaseResult,
            productLoadResult: productLoadResult,
            productLoadState: productLoadState,
            storefrontCountry: storefrontCountry == "-" ? nil : storefrontCountry
        )
        Task {
            await analyticsClient.track(event)
        }
    }

    private func analyticsResult(for outcome: PurchaseOutcome) -> PurchaseAnalyticsResult {
        switch outcome {
        case .success:
            return .success
        case .cancelled:
            return .cancelled
        case .pending:
            return .pending
        case .unverified:
            return .unverified
        case .failed:
            return .failed
        }
    }

    private func analyticsProductLoadResult(for outcome: ProductLoadOutcome) -> PurchaseAnalyticsProductLoadResult {
        switch outcome {
        case .success:
            return .loaded
        case .empty:
            return .empty
        case .error:
            return .failed
        }
    }
}
