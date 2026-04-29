import Foundation
import SwiftData

/// Central helper to compute the displayable plan budget amount for a given month,
/// honoring baseline selection, fixed amount, and non-monthly income/bill spreading.
enum PlanBudgetDisplay {
    /// Computes the budget amount to display for the given plan start month,
    /// honoring baseline source, fixed amount, and the include-spreads toggle.
    /// - Returns: The amount to show for the label (already net-of-non-monthly when applicable), or nil when not applicable.
    static func availableBudget(
        for startMonth: Date,
        modelContext: ModelContext,
        baselineBudgetSourceRaw: String,
        useFixedDebtBudget: Bool,
        debtBudgetOverrideAmount: Double,
        includeNonMonthlyIncomeSpreads: Bool,
        oneTimeIncomeDefaultSpreadMonths: Int
    ) -> Decimal? {
        // Fixed baseline: either show the fixed amount directly, or net via schedule when spreads are enabled.
        if baselineBudgetSourceRaw == "fixed",
           useFixedDebtBudget,
           debtBudgetOverrideAmount > 0 {
            let fixed = Decimal(debtBudgetOverrideAmount)
            if includeNonMonthlyIncomeSpreads {
                let items = (try? modelContext.fetch(FetchDescriptor<CashFlowItem>())) ?? []
                let schedule = IncomeScheduler.budgetByMonth(
                    items: items,
                    start: startMonth,
                    months: 12,
                    includeSpreads: true,
                    oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths),
                    baselineSource: .fixedAmount(fixed)
                )
                // Fallback to the raw fixed amount if schedule is missing the month
                return schedule[startMonth] ?? fixed
            } else {
                return fixed
            }
        }

        // Recurring Net baseline: compute the available amount for the month.
        if baselineBudgetSourceRaw == "recurringNet" {
            let items = (try? modelContext.fetch(FetchDescriptor<CashFlowItem>())) ?? []
            let schedule = IncomeScheduler.budgetByMonth(
                items: items,
                start: startMonth,
                months: 12,
                includeSpreads: includeNonMonthlyIncomeSpreads,
                oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths),
                baselineSource: .recurringNet
            )
            return schedule[startMonth]
        }

        // Unknown baseline
        return nil
    }

    private static func sanitizedDefaultSpread(_ v: Int) -> Int {
        [3, 6, 12].contains(v) ? v : 12
    }
}
