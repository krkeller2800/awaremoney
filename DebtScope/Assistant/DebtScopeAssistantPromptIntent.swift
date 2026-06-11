import Foundation

enum AssistantPromptIntent {
    case debtPicture
    case payoffFocus
    case strategySavings
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
        } else if normalized.containsAny(["debt picture", "current debt", "debt summary", "how much debt", "total debt"]) {
            self = .debtPicture
        } else if normalized.containsAny(["focus on first", "focus first", "pay first", "which debt", "payoff first", "prioritize"]) {
            self = .payoffFocus
        } else if normalized.containsAny(["bills are coming", "coming up", "upcoming bills", "bills due", "due soon"]) {
            self = .upcomingBills
        } else if normalized.containsAny(["can i afford", "afford to add", "extra", "additional"]) && normalized.containsAny(["debt payment", "debt payments", "monthly debt", "payment"]) {
            self = .debtAffordability
        } else {
            self = .none
        }
    }
}

private extension String {
    func containsAny(_ needles: [String]) -> Bool {
        needles.contains { contains($0) }
    }
}
