import SwiftUI

@MainActor
struct TrialBanner: View {
    @ObservedObject private var purchases: PurchaseManager
    private let horizontalPadding: CGFloat
    private let textLineLimit: Int?
    private let action: (() -> Void)?

    init(
        purchases: PurchaseManager,
        horizontalPadding: CGFloat = 16,
        textLineLimit: Int? = 2,
        action: (() -> Void)? = nil
    ) {
        self.purchases = purchases
        self.horizontalPadding = horizontalPadding
        self.textLineLimit = textLineLimit
        self.action = action
    }

    @MainActor
    init(
        horizontalPadding: CGFloat = 16,
        textLineLimit: Int? = 2,
        action: (() -> Void)? = nil
    ) {
        self.purchases = .shared
        self.horizontalPadding = horizontalPadding
        self.textLineLimit = textLineLimit
        self.action = action
    }

    var body: some View {
        Group {
            if shouldShow {
                if let action {
                    Button(action: action) {
                        bannerContent
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
                } else {
                    bannerContent
                }
            }
        }
    }

    private var bannerContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .imageScale(.medium)
                .foregroundStyle(.blue)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.blue)
                .lineLimit(textLineLimit)
                .minimumScaleFactor(0.8)
            if action != nil {
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.blue.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, horizontalPadding)
        .accessibilityIdentifier("trialBanner")
    }

    private var shouldShow: Bool {
        return !purchases.hasPremiumAccess && purchases.canUseFreeImport
    }

    private var message: String {
        purchases.freeImportStatusText
    }
}

#Preview {
    VStack(spacing: 12) {
        TrialBanner(purchases: .shared)
        Text("Content below")
        Spacer()
    }
}
