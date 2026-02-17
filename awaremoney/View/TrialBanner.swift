import SwiftUI

@MainActor
struct TrialBanner: View {
    @ObservedObject private var purchases: PurchaseManager

    init(purchases: PurchaseManager) {
        self.purchases = purchases
    }

    @MainActor
    init() {
        self.purchases = .shared
    }

    var body: some View {
        Group {
            if shouldShow {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "hourglass")
                        .imageScale(.medium)
                        .foregroundStyle(.blue)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.blue)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal)
                .accessibilityIdentifier("trialBanner")
            }
        }
    }

    private var shouldShow: Bool {
        return !purchases.isPurchased && purchases.isInTrial
    }

    private var message: String {
        let days = purchases.trialDaysRemaining
        return "Free trial active — \(days) day\(days == 1 ? "" : "s") remaining"
    }
}

#Preview {
    VStack(spacing: 12) {
        TrialBanner(purchases: .shared)
        Text("Content below")
        Spacer()
    }
}

