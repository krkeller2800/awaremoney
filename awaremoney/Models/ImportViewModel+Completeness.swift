import Foundation

extension ImportViewModel {
    public enum CompletenessSeverity {
        case required
        case recommended
    }

    public struct CompletenessIssue: Identifiable, Equatable {
        public let id = UUID()
        public let severity: CompletenessSeverity
        public let title: String
        public let detail: String?

        public init(severity: CompletenessSeverity, title: String, detail: String? = nil) {
            self.severity = severity
            self.title = title
            self.detail = detail
        }
    }

    /// Computes missing/weak fields for the current staged import based on the selected account type.
    /// - Returns: A list of issues. `required` items should be satisfied before saving; `recommended` items help improve projections.
    public func computeCompletenessIssues() -> [CompletenessIssue] {
        guard let staged = self.staged else { return [] }
        var issues: [CompletenessIssue] = []

        // Convenience helpers
        let hasAnyBalance: Bool = !staged.balances.isEmpty
        let hasAnyTx: Bool = !staged.transactions.isEmpty
        let hasAnyHoldings: Bool = !staged.holdings.isEmpty
        let hasAPR: Bool = staged.balances.contains { $0.interestRateAPR != nil }
        let hasTypicalPaymentSnapshot: Bool = staged.balances.contains { ($0.typicalPaymentAmount ?? 0) > 0 }
        let hasTypicalPaymentSentinel: Bool = staged.balances.contains { ($0.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "__typical_payment__" }
        let hasTypicalPayment: Bool = hasTypicalPaymentSnapshot || hasTypicalPaymentSentinel

        switch self.newAccountType {
        case .creditCard, .loan:
            if !hasAnyBalance {
                issues.append(CompletenessIssue(
                    severity: .required,
                    title: "Add a statement balance",
                    detail: "Enter the balance as of the statement date."
                ))
            }
            if !hasAPR {
                issues.append(CompletenessIssue(
                    severity: .recommended,
                    title: "Enter APR",
                    detail: "APR improves interest and payoff projections."
                ))
            }
            if !hasTypicalPayment {
                issues.append(CompletenessIssue(
                    severity: .recommended,
                    title: "Set a typical monthly payment",
                    detail: "Used for payoff estimates and budgeting."
                ))
            }
        case .checking:
            if !hasAnyTx && !hasAnyBalance {
                issues.append(CompletenessIssue(
                    severity: .required,
                    title: "Add transactions or a balance",
                    detail: "Provide at least one to proceed."
                ))
            } else if hasAnyTx && !hasAnyBalance {
                issues.append(CompletenessIssue(
                    severity: .recommended,
                    title: "Add a statement balance",
                    detail: "Helps reconcile your account."
                ))
            }
        case .brokerage:
            if !hasAnyTx && !hasAnyHoldings && !hasAnyBalance {
                issues.append(CompletenessIssue(
                    severity: .required,
                    title: "Add holdings, transactions, or a balance",
                    detail: "Provide at least one to proceed."
                ))
            } else if !hasAnyHoldings {
                issues.append(CompletenessIssue(
                    severity: .recommended,
                    title: "Add holdings",
                    detail: "Holdings help track market value."
                ))
            }
        default:
            break
        }
        return issues
    }

    /// True if any `required` issue remains unresolved for the current staged import.
    public var hasBlockingCompletenessIssues: Bool {
        return computeCompletenessIssues().contains { $0.severity == .required }
    }
}
