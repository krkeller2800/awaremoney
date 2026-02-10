import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var purchases: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            header
            trialStatus
            purchaseSection
            restoreSection
            footer
        }
        .padding()
        .presentationDetents([.medium, .large])
        .onChange(of: purchases.isPremiumUnlocked) { _, newValue in
            if newValue { dismiss() }
        }
        .alert(item: Binding(get: { purchases.errorMessage.map { IdentifiedError(message: $0) } }, set: { _ in purchases.errorMessage = nil })) { item in
            Alert(title: Text("Error"), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)
            Text("Premium Access")
                .font(.title.bold())
            Text("Unlock lifetime premium features")
                .foregroundStyle(.secondary)
        }
    }

    private var trialStatus: some View {
        Group {
            if purchases.isPurchased {
                Label("Purchased — Thank you!", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if purchases.isInTrial {
                let days = purchases.trialDaysRemaining
                Label("Free trial active — \(days) day\(days == 1 ? "" : "s") remaining", systemImage: "hourglass")
                    .foregroundStyle(.blue)
            } else {
                Label("Free trial expired", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.headline)
    }

    private var purchaseSection: some View {
        VStack(spacing: 8) {
            if let product = purchases.product {
                Button {
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
                .disabled(purchases.isPurchasing || purchases.isPurchased)
            } else {
                ProgressView("Loading…")
            }
        }
    }

    private func purchaseButtonTitle(for product: Product) -> String {
        "Buy Lifetime — \(product.displayPrice)"
    }

    private var restoreSection: some View {
        Button("Restore Purchases") {
            Task { await purchases.restorePurchases() }
        }
        .buttonStyle(.bordered)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Includes a 10-day free trial. After the trial, a one-time purchase is required to continue using premium features.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Purchases are tied to your Apple ID and can be restored on new devices.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }
}

private struct IdentifiedError: Identifiable { let id = UUID(); let message: String }

// MARK: - Premium gating helper
extension View {
    /// Wrap premium-only content. Presents the paywall if the user is not entitled (neither purchased nor in trial).
    /// - Parameters:
    ///   - isPresented: A binding you control to show the paywall.
    ///   - purchases: A shared purchase manager (default: shared singleton).
    /// - Returns: A view that conditionally overlays a paywall sheet.
    func paywalled(isPresented: Binding<Bool>, purchases: PurchaseManager = .shared) -> some View {
        self
            .sheet(isPresented: isPresented) {
                PaywallView()
                    .environmentObject(purchases)
            }
    }
}
