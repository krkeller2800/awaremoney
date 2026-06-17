import SwiftUI
import StoreKit

struct PaywallView: View {
    let source: PaywallSource

    @EnvironmentObject var purchases: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var showLongPurchaseHint = false
    @State private var didRecordImpression = false

    init(source: PaywallSource = .unknown) {
        self.source = source
    }
    
    private var isActivelyLoading: Bool {
        // Only show the spinner during initial/active load when no product is available
        // and there is no known error/empty diagnostic yet.
        if purchases.product != nil { return false }
        let diag = purchases.iapDiagnosticSummary?.lowercased() ?? ""
        let hasKnownFailure = diag.contains("error") || diag.contains("empty")
        let hasError = purchases.errorMessage != nil
        return !(hasKnownFailure || hasError)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                sourceMessage
                valueBullets
                allowanceStatus
                purchaseSection
                restoreSection
                footer
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.large])
        .task {
            if !didRecordImpression {
                didRecordImpression = true
                purchases.recordPaywallImpression(source: source)
            }
            if purchases.product == nil {
                await purchases.reloadProducts()
            }
        }
        .onChange(of: purchases.isPremiumUnlocked) { _, newValue in
            if newValue { dismiss() }
        }
        .onChange(of: purchases.isPurchasing) { _, purchasing in
            showLongPurchaseHint = false
            if purchasing {
                Task {
                    try? await Task.sleep(nanoseconds: 12_000_000_000) // ~12 seconds
                    if purchases.isPurchasing {
                        showLongPurchaseHint = true
                    }
                }
            }
        }
        .alert(item: Binding(get: { purchases.errorMessage.map { IdentifiedError(message: $0) } }, set: { _ in purchases.errorMessage = nil })) { item in
            Alert(title: Text("Error"), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)
            Text("Unlock Lifetime Premium")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Unlimited local finance planning with no subscription, ads, or bank login.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var sourceMessage: some View {
        Group {
            if let message = source.contextMessage {
                Label(message, systemImage: source.contextSystemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var valueBullets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Unlimited statement imports and review history", systemImage: "tray.and.arrow.down.fill")
            Label("Debt payoff plans, strategy comparisons, and extra-payment impact", systemImage: "chart.line.uptrend.xyaxis")
            Label("Cash flow, bills, reserves, and net worth in one place", systemImage: "list.bullet.rectangle.fill")
            Label("Backup, restore, local search, Spotlight, and optional on-device assistant", systemImage: "lock.shield.fill")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var allowanceStatus: some View {
        Group {
            if purchases.hasPremiumAccess {
                Label("Purchased — Thank you!", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if purchases.canUseFreeImport {
                Label(purchases.freeImportStatusText, systemImage: "tray.and.arrow.down")
                    .foregroundStyle(.blue)
            } else {
                Label(purchases.freeImportStatusText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.headline)
    }

    private var purchaseSection: some View {
        VStack(spacing: 8) {
            if let product = purchases.product {
                Button {
                    purchases.recordPurchaseButtonTap(source: source)
                    Task { await purchases.purchase() }
                } label: {
                    HStack {
                        Spacer()
                        Text(purchaseButtonTitle(for: product))
                            .bold()
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(purchases.isPurchasing || purchases.hasPremiumAccess)
            } else {
                VStack(spacing: 8) {
                    if isActivelyLoading {
                        ProgressView("Contacting the App Store…")
                    } else {
                        Label("We couldn’t load purchase information.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("You can try again or restore purchases if you previously bought Premium.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("Try Again") {
                        Task { await purchases.reloadProducts() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(purchases.isPurchasing)

                    if let diag = purchases.iapDiagnosticSummary {
                        Text(diag)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("iapDiagnosticSummary")
                    }
                }
            }
        }
    }

    private func purchaseButtonTitle(for product: Product) -> String {
        "Unlock Lifetime - \(product.displayPrice)"
    }

    private var restoreSection: some View {
        Button("Restore Purchases") {
            Task { await purchases.restorePurchases() }
        }
        .buttonStyle(.bordered)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if showLongPurchaseHint {
                Label("This is taking longer than expected. If the App Store sheet is spinning, cancel and try again, or tap Restore Purchases if you already bought Premium.", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text("One-time purchase. No subscription. Your financial data stays local unless you choose to export or share it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text("Purchases are tied to your Apple ID and can be restored on new devices.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}

private extension PaywallSource {
    var contextMessage: String? {
        switch self {
        case .fifthImport:
            return "Your trial imports are used. Unlock Premium to keep importing statements and building your plan."
        case .externalImport:
            return "Unlock Premium to import this file and continue your local financial history."
        case .backupRestore:
            return "Unlock Premium to protect and move your local DebtScope data."
        case .assistant:
            return "Unlock Premium for private on-device finance assistance where supported."
        case .payoffResult:
            return "Unlock Premium to keep comparing payoff strategies and refining your plan."
        case .settings, .about, .unknown:
            return nil
        }
    }

    var contextSystemImage: String {
        switch self {
        case .fifthImport, .externalImport:
            return "doc.badge.plus"
        case .backupRestore:
            return "externaldrive.badge.timemachine"
        case .assistant:
            return "sparkles"
        case .payoffResult:
            return "chart.line.uptrend.xyaxis"
        case .settings, .about, .unknown:
            return "star.circle"
        }
    }
}

private struct IdentifiedError: Identifiable { let id = UUID(); let message: String }

// MARK: - Premium gating helper
extension View {
    /// Wrap premium-only content. Presents the paywall if the user is not entitled.
    /// - Parameters:
    ///   - isPresented: A binding you control to show the paywall.
    ///   - purchases: A purchase manager instance.
    /// - Returns: A view that conditionally overlays a paywall sheet.
    func paywalled(
        isPresented: Binding<Bool>,
        purchases: PurchaseManager,
        source: PaywallSource = .unknown
    ) -> some View {
        self
            .sheet(isPresented: isPresented) {
                PaywallView(source: source)
                    .environmentObject(purchases)
            }
    }

    /// Convenience overload that uses the shared PurchaseManager. Kept @MainActor to safely access `.shared`.
    @MainActor
    func paywalled(isPresented: Binding<Bool>, source: PaywallSource = .unknown) -> some View {
        paywalled(isPresented: isPresented, purchases: PurchaseManager.shared, source: source)
    }
}
