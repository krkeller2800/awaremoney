import SwiftUI

public struct DebtStrategyInfoView: View {
    public var useDisclosureStyle: Bool = true
    public var userCanToggle: Bool = true
    public var title: String = "Debt strategies"
    @State private var expandedState: Bool = false

    public init(useDisclosureStyle: Bool = true, userCanToggle: Bool = true, title: String = "Debt strategies") {
        self.useDisclosureStyle = useDisclosureStyle
        self.userCanToggle = userCanToggle
        self.title = title
    }

    public var body: some View {
        Group {
            if useDisclosureStyle {
                if userCanToggle {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.snappy) { expandedState.toggle() }
                        } label: {
                            HStack(spacing: 8) {
                                Text(title)
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(expandedState ? 90 : 0))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(title)
                        .accessibilityValue(expandedState ? "Expanded" : "Collapsed")
                        .accessibilityAddTraits(.isButton)

                        if expandedState {
                            content
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                                .foregroundStyle(.secondary)
                            Text(title)
                        }
                        content
                    }
                }
            } else {
                content
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Minimums Only: Pay only the minimum due on each debt. No extra beyond minimums.")
            Text("Snowball: After minimums, apply extra to the smallest balance first. Quick wins; may pay more interest.")
            Text("Avalanche: After minimums, apply extra to the highest APR first. Minimizes interest; first payoff may take longer.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
