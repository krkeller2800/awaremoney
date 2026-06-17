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

    // MARK: - Published state
    @Published var product: Product?
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
    private let debugConversionCounterPrefix = "DebugConversionCounter"
    @Published var debugPremiumOverride: DebugPremiumOverride = .useStoreKit {
        didSet {
            UserDefaults.standard.set(debugPremiumOverride.rawValue, forKey: debugPremiumOverrideKey)
        }
    }
    @Published private(set) var debugConversionSummary: String = ""
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

    func synchronizeInitialFreeImportUsage(existingImportCount: Int) {
        guard !hasMigratedFreeImportAllowance else { return }
        let migratedUsage = min(max(existingImportCount, 0), freeImportLimit)
        if migratedUsage > freeImportsUsed {
            setFreeImportsUsed(migratedUsage)
        }
        ImportAllowanceKeychain.saveBool(true, account: freeImportMigrationKey)
    }

    @discardableResult
    func recordCompletedImportIfNeeded() -> Bool {
        if hasPremiumAccess { return true }
        guard canUseFreeImport else { return false }
        setFreeImportsUsed(freeImportsUsed + 1)
        return true
    }

    func resetFreeImportAllowanceForDebug() {
        setFreeImportsUsed(0)
        ImportAllowanceKeychain.saveBool(true, account: freeImportMigrationKey)
    }

    private func setFreeImportsUsed(_ value: Int) {
        freeImportsUsed = max(0, min(value, freeImportLimit))
        ImportAllowanceKeychain.saveInt(freeImportsUsed, account: freeImportsUsedKey)
    }

    // MARK: - Init
    init() {
        freeImportsUsed = ImportAllowanceKeychain.loadInt(account: freeImportsUsedKey) ?? 0
        #if DEBUG
        if let storedOverride = UserDefaults.standard.string(forKey: debugPremiumOverrideKey),
           let override = DebugPremiumOverride(rawValue: storedOverride) {
            debugPremiumOverride = override
        }
        refreshDebugConversionSummary()
        #endif
        Task { await configure() }
    }

    // MARK: - Public API
    func purchase() async {
        guard let product else {
            recordPurchaseOutcomeForDebug(.failed)
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
                    recordPurchaseOutcomeForDebug(.success)
                    await transaction.finish()
                case .unverified(_, let error):
                    self.errorMessage = error.localizedDescription
                    recordPurchaseOutcomeForDebug(.unverified)
                }
            case .userCancelled:
                recordPurchaseOutcomeForDebug(.cancelled)
                break
            case .pending:
                // Pending (SCA or parental approval). Keep UI as-is.
                recordPurchaseOutcomeForDebug(.pending)
                break
            @unknown default:
                recordPurchaseOutcomeForDebug(.failed)
                break
            }
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recordPurchaseOutcomeForDebug(.failed)
        }
    }

    func recordPaywallImpression(source: PaywallSource) {
        #if DEBUG
        incrementDebugCounter("paywall.impression.\(source.rawValue)")
        #endif
    }

    func recordPurchaseButtonTap(source: PaywallSource) {
        #if DEBUG
        incrementDebugCounter("purchase.tap.\(source.rawValue)")
        #endif
    }

    func restorePurchases() async {
        do {
            try await StoreKit.AppStore.sync()
            await updatePurchasedStatus()
            if isPurchased {
                self.userMessage = "Your Premium purchase is already active on this device."
            } else {
                self.userMessage = "No previous purchases were found for your Apple ID."
            }
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        for attempt in 1...maxAttempts {
            do {
                let products = try await Product.products(for: [productID])
                if let first = products.first {
                    self.product = first
                    self.errorMessage = nil
                    let sf: String = await currentStorefrontID()
                    self.iapDiagnosticSummary = "IAP: ok • pid=\(productShortCode) • sf=\(sf)"
                    recordProductLoadOutcomeForDebug(.success)
                    return
                } else {
                    let sf: String = await currentStorefrontID()
                    self.iapDiagnosticSummary = "IAP: empty • pid=\(productShortCode) • sf=\(sf)"
                    recordProductLoadOutcomeForDebug(.empty)
                    // No products returned; will retry after a short delay
                }
            } catch {
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let msg: String = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.iapDiagnosticSummary = "IAP: error • pid=\(productShortCode) • \(msg)"
                recordProductLoadOutcomeForDebug(.error)
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

    private enum DebugPurchaseOutcome: String, CaseIterable {
        case success
        case cancelled
        case pending
        case unverified
        case failed
    }

    private enum DebugProductLoadOutcome: String, CaseIterable {
        case success
        case empty
        case error
    }

    private func recordPurchaseOutcomeForDebug(_ outcome: DebugPurchaseOutcome) {
        #if DEBUG
        incrementDebugCounter("purchase.outcome.\(outcome.rawValue)")
        #endif
    }

    private func recordProductLoadOutcomeForDebug(_ outcome: DebugProductLoadOutcome) {
        #if DEBUG
        incrementDebugCounter("product.load.\(outcome.rawValue)")
        #endif
    }

    #if DEBUG
    private func incrementDebugCounter(_ name: String) {
        let key = "\(debugConversionCounterPrefix).\(name)"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        refreshDebugConversionSummary()
    }

    private func debugCounter(_ name: String) -> Int {
        UserDefaults.standard.integer(forKey: "\(debugConversionCounterPrefix).\(name)")
    }

    private func refreshDebugConversionSummary() {
        let impressionSummary = PaywallSource.allCases
            .map { source in "\(source.rawValue): \(debugCounter("paywall.impression.\(source.rawValue)"))" }
            .joined(separator: ", ")

        let tapSummary = PaywallSource.allCases
            .map { source in "\(source.rawValue): \(debugCounter("purchase.tap.\(source.rawValue)"))" }
            .joined(separator: ", ")

        let purchaseSummary = DebugPurchaseOutcome.allCases
            .map { outcome in "\(outcome.rawValue): \(debugCounter("purchase.outcome.\(outcome.rawValue)"))" }
            .joined(separator: ", ")

        let productLoadSummary = DebugProductLoadOutcome.allCases
            .map { outcome in "\(outcome.rawValue): \(debugCounter("product.load.\(outcome.rawValue)"))" }
            .joined(separator: ", ")

        debugConversionSummary = """
        Paywall impressions: \(impressionSummary)
        Purchase taps: \(tapSummary)
        Purchase outcomes: \(purchaseSummary)
        Product loads: \(productLoadSummary)
        """
    }
    #endif
}
