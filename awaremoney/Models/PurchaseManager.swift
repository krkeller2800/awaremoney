import Foundation
import StoreKit
import SwiftUI
import Combine
import Security

private enum TrialKeychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "com.awaremoney.app" }
    private static let account = "PremiumTrialStartDate"

    static func save(date: Date) {
        let seconds = date.timeIntervalSince1970
        let data = withUnsafeBytes(of: seconds) { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Replace if exists
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load() -> Date? {
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
        guard data.count == MemoryLayout<TimeInterval>.size else { return nil }
        let seconds = data.withUnsafeBytes { $0.load(as: TimeInterval.self) }
        return Date(timeIntervalSince1970: seconds)
    }

    static func delete() {
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

    // Trial configuration (app-side; not an App Store trial)
    private let trialLengthDays: Int = 10
    private let trialStartKey = "PremiumTrialStartDate"

    // MARK: - Published state
    @Published var product: Product?
    @Published var isPurchased: Bool = false
    @Published var isPurchasing: Bool = false
    @Published var errorMessage: String?

    // Derived entitlement: purchased OR within trial window
    var isPremiumUnlocked: Bool { isPurchased || isInTrial }

    // MARK: - Trial state
    var trialStartDate: Date? {
        get {
            // Prefer Keychain value
            if let kc = TrialKeychain.load() { return kc }
            // Legacy migration from UserDefaults if present
            if let time = UserDefaults.standard.object(forKey: trialStartKey) as? TimeInterval {
                let date = Date(timeIntervalSince1970: time)
                TrialKeychain.save(date: date)
                UserDefaults.standard.removeObject(forKey: trialStartKey)
                return date
            }
            return nil
        }
        set {
            if let date = newValue {
                TrialKeychain.save(date: date)
            } else {
                TrialKeychain.delete()
            }
        }
    }

    var trialEndDate: Date? {
        guard let start = trialStartDate else { return nil }
        return Calendar(identifier: .gregorian).date(byAdding: .day, value: trialLengthDays, to: start)
    }

    var isInTrial: Bool {
        guard let end = trialEndDate else { return false }
        return Date() < end
    }

    var trialDaysRemaining: Int {
        guard let end = trialEndDate else { return 0 }
        let cal = Calendar(identifier: .gregorian)
        let startOfToday = cal.startOfDay(for: Date())
        let startOfEnd = cal.startOfDay(for: end)
        let comps = cal.dateComponents([.day], from: startOfToday, to: startOfEnd)
        return max(0, (comps.day ?? 0))
    }

    // MARK: - Init
    init() {
        Task { await configure() }
    }

    // MARK: - Public API
    func purchase() async {
        guard let product else { return }
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
                    await transaction.finish()
                case .unverified(_, let error):
                    self.errorMessage = error.localizedDescription
                }
            case .userCancelled:
                break
            case .pending:
                // Pending (SCA or parental approval). Keep UI as-is.
                break
            @unknown default:
                break
            }
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Setup
    private func configure() async {
        startTrialIfNeeded()
        await loadProduct()
        await updatePurchasedStatus()
        listenForTransactions()
    }

    private func startTrialIfNeeded() {
        // Start the trial on first run if the user hasn't purchased yet and has no existing trial
        if !isPurchased && trialStartDate == nil {
            trialStartDate = Date()
        }
    }

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [productID])
            self.product = products.first
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func updatePurchasedStatus() async {
        // Prefer latest transaction API for the specific product
        if let latest = try? await StoreKit.Transaction.latest(for: productID) {
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
}

