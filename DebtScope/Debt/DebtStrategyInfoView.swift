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
                    DisclosureGroup(isExpanded: $expandedState) {
                        content
                    } label: {
                        Label(title, systemImage: "info.circle")
                    }
                } else {
                    DisclosureGroup(isExpanded: .constant(true)) {
                        content
                    } label: {
                        Label(title, systemImage: "info.circle")
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
