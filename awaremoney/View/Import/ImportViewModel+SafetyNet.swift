import Foundation

extension ImportViewModel {
    public func applyLiabilityLabelSafetyNetIfNeeded() {
        guard var staged = self.staged else {
            AMLogging.always("applyLiabilityLabelSafetyNetIfNeeded skipped: no staged data")
            return
        }
        
        let userHintIsCreditCard = (self.userSelectedDocHint == .creditCard)
        let suggestedLiability = (staged.suggestedAccountType == .loan || staged.suggestedAccountType == .creditCard)
        
        guard userHintIsCreditCard || suggestedLiability else {
            AMLogging.always("applyLiabilityLabelSafetyNetIfNeeded skipped: no credit card hint or suggested liability")
            return
        }
        
        guard !staged.balances.isEmpty else {
            AMLogging.always("applyLiabilityLabelSafetyNetIfNeeded skipped: no balances in staged")
            return
        }
        
        let nonLiabilityLabels: Set<String> = ["checking", "savings", "brokerage", "investment"]
        
        let areAllNonLiability = staged.balances.allSatisfy { balance in
            guard let label = balance.sourceAccountLabel?.lowercased() else {
                return true
            }
            return nonLiabilityLabels.contains(label)
        }
        
        if areAllNonLiability {
            for i in staged.balances.indices {
                staged.balances[i].sourceAccountLabel = "creditcard"
            }
            self.staged = staged
            self.infoMessage = "Mapped statement balances to a credit card based on your selection."
            AMLogging.always("applyLiabilityLabelSafetyNetIfNeeded applied: all balances relabeled as creditcard")
        } else {
            AMLogging.always("applyLiabilityLabelSafetyNetIfNeeded skipped: not all balances non-liability")
        }
    }
}
extension ImportViewModel {
    public func applyLiabilityLabelSafetyNetIfNeeded(to staged: inout StagedImport) {
        let userHintIsCreditCard = (self.userSelectedDocHint == .creditCard)
        let suggestedLiability = (staged.suggestedAccountType == .loan || staged.suggestedAccountType == .creditCard)
        guard userHintIsCreditCard || suggestedLiability else {
            AMLogging.always("applyLiabilityLabelSafetyNetIfNeeded(to:) skipped: no credit card hint or suggested liability", component: "ImportViewModel")
            return
        }
        guard !staged.balances.isEmpty else {
            AMLogging.always("applyLiabilityLabelSafetyNetIfNeeded(to:) skipped: no balances in staged", component: "ImportViewModel")
            return
        }
        let nonLiabilityLabels: Set<String> = ["checking", "savings", "brokerage", "investment"]
        let areAllNonLiability = staged.balances.allSatisfy { balance in
            let norm = self.normalizeSourceLabel(balance.sourceAccountLabel) ?? "default"
            return nonLiabilityLabels.contains(norm) || norm == "default"
        }
        if areAllNonLiability {
            for i in staged.balances.indices {
                staged.balances[i].sourceAccountLabel = "credit card"
            }
            self.infoMessage = "Mapped statement balances to a credit card based on your selection."
            AMLogging.always("applyLiabilityLabelSafetyNetIfNeeded(to:) applied: all balances relabeled as credit card", component: "ImportViewModel")
        } else {
            AMLogging.always("applyLiabilityLabelSafetyNetIfNeeded(to:) skipped: not all balances non-liability", component: "ImportViewModel")
        }
    }
}

