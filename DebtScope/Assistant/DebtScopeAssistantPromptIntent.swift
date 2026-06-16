import Foundation

enum AssistantPromptIntent {
    case debtPicture
    case payoffFocus
    case strategySavings
    case extraPaymentSimulation
    case importReview
    case cleanupRecommendations
    case upcomingBills
    case debtAffordability
    case transactionDetails
    case none

    init(prompt: String) {
        let normalized = prompt.lowercased()

        if normalized.containsAny(["raw transaction", "raw transactions", "transaction memo", "transaction memos", "full memo", "full memos", "show me my transactions", "show transactions"]) {
            self = .transactionDetails
        } else if normalized.contains("avalanche") && normalized.contains("snowball") && normalized.containsAny(["save", "savings", "interest", "versus", "vs", "compare", "comparison"]) {
            self = .strategySavings
        } else if normalized.containsAny(["can i afford", "afford to add", "extra", "additional"]) && normalized.containsAny(["debt payment", "debt payments", "monthly debt", "payment"]) {
            self = .debtAffordability
        } else if normalized.isExtraPaymentSimulationPrompt {
            self = .extraPaymentSimulation
        } else if normalized.containsAny(["cleanup", "clean up", "what should i fix", "what should i review", "recommended actions", "recommend actions", "suggest actions", "suggest cleanup", "needs attention", "how do i fix", "how do i resolve", "how do i complete", "missing APR", "missing minimum payment", "missing minimum payments", "complete bill", "complete income", "bill and income schedules"]) {
            self = .cleanupRecommendations
        } else if normalized.containsAny(["latest import", "recent import", "last import", "import review", "what changed after my import", "what changed after my latest import", "what needs review", "duplicates", "duplicate imports", "account mapping", "mapping issues"]) {
            self = .importReview
        } else if normalized.containsAny(["debt picture", "current debt", "debt summary", "how much debt", "total debt"]) {
            self = .debtPicture
        } else if normalized.containsAny(["focus on first", "focus first", "pay first", "which debt", "payoff first", "prioritize"]) {
            self = .payoffFocus
        } else if normalized.containsAny(["bills are coming", "coming up", "upcoming bills", "bills due", "due soon"]) {
            self = .upcomingBills
        } else {
            self = .none
        }
    }
}

private extension String {
    var isExtraPaymentSimulationPrompt: Bool {
        let asksWhatIf = containsAny(["what happens if", "what if", "if i add", "add $", "extra payment", "extra monthly", "additional payment", "additional monthly"])
        guard asksWhatIf else { return false }

        let namesDebtPaymentContext = containsAny(["debt", "payment", "payoff", "per month", "monthly"])
        let namesStrategyWithAmount = containsAny(["avalanche", "snowball", "minimum", "minimums"]) && containsCurrencyAmount
        return namesDebtPaymentContext || namesStrategyWithAmount
    }

    var containsCurrencyAmount: Bool {
        range(of: #"\$\s*\d"#, options: .regularExpression) != nil
    }

    func containsAny(_ needles: [String]) -> Bool {
        needles.contains { contains($0) }
    }
}
