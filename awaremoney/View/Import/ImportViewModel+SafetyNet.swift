import Foundation

extension ImportViewModel {
    public func applyLiabilityLabelSafetyNetIfNeeded() {
        guard var staged = self.staged else {
            AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded skipped: no staged data")
            return
        }
        
        let userHintIsCreditCard = (self.userSelectedDocHint == .creditCard)
        let suggestedLiability = (staged.suggestedAccountType == .loan || staged.suggestedAccountType == .creditCard)
        
        guard userHintIsCreditCard || suggestedLiability else {
            AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded skipped: no credit card hint or suggested liability")
            return
        }
        
        guard !staged.balances.isEmpty else {
            AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded skipped: no balances in staged")
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
            let sentinel = "__typical_payment__"
            for i in staged.balances.indices {
                let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lbl == sentinel {
                    AMLogging.log("SafetyNet: skipping relabel for typical payment sentinel at index=\(i)")
                    continue
                }
                staged.balances[i].sourceAccountLabel = "creditcard"
            }
            self.staged = staged
            self.infoMessage = "Mapped statement balances to a credit card based on your selection."
            AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded applied: all balances relabeled as creditcard")
        } else {
            AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded skipped: not all balances non-liability")
        }
    }
}
extension ImportViewModel {
    public func applyLiabilityLabelSafetyNetIfNeeded(to staged: inout StagedImport) {
        let userHintIsCreditCard = (self.userSelectedDocHint == .creditCard)
        let suggestedLiability = (staged.suggestedAccountType == .loan || staged.suggestedAccountType == .creditCard)
        guard userHintIsCreditCard || suggestedLiability else {
            AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded(to:) skipped: no credit card hint or suggested liability", component: "ImportViewModel")
            return
        }
        guard !staged.balances.isEmpty else {
            AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded(to:) skipped: no balances in staged", component: "ImportViewModel")
            return
        }
        let nonLiabilityLabels: Set<String> = ["checking", "savings", "brokerage", "investment"]
        let areAllNonLiability = staged.balances.allSatisfy { balance in
            let norm = self.normalizeSourceLabel(balance.sourceAccountLabel) ?? "default"
            return nonLiabilityLabels.contains(norm) || norm == "default"
        }
        if areAllNonLiability {
            let sentinel = "__typical_payment__"
            for i in staged.balances.indices {
                let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lbl == sentinel {
                    AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded(to:): skipping relabel for typical payment sentinel at index=\(i)", component: "ImportViewModel")
                    continue
                }
                // Normalize liability labels to a consistent token
                if self.userSelectedDocHint == .loan {
                    staged.balances[i].sourceAccountLabel = "loan"
                } else {
                    staged.balances[i].sourceAccountLabel = "creditcard"
                }
            }
            self.infoMessage = "Mapped statement balances to a credit card based on your selection."
            AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded(to:) applied: all balances relabeled as credit card", component: "ImportViewModel")
        } else {
            AMLogging.log("applyLiabilityLabelSafetyNetIfNeeded(to:) skipped: not all balances non-liability", component: "ImportViewModel")
        }
    }
}

