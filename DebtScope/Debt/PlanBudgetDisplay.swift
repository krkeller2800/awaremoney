import Foundation
import SwiftData

/// Central helper to compute the displayable plan budget amount for a given month,
/// honoring baseline selection, fixed amount, and non-monthly income/bill spreading.
enum PlanBudgetDisplay {
    static func discretionaryReserve(from storedAmount: Double) -> Decimal {
        guard storedAmount > 0 else { return 0 }
        return NSDecimalNumber(value: storedAmount).decimalValue
    }

    static func availableForDebt(availableCash: Decimal, discretionaryReserve: Decimal) -> Decimal {
        max(0, availableCash - max(0, discretionaryReserve))
    }

    static func reserveGap(discretionaryReserve: Decimal, discretionaryRemaining: Decimal) -> Decimal {
        max(0, max(0, discretionaryReserve) - discretionaryRemaining)
    }

    static func reserveAdjustedBudgetSchedule(
        _ schedule: [Date: Decimal],
        discretionaryReserve: Decimal,
        appliesReserve: Bool
    ) -> [Date: Decimal] {
        guard appliesReserve, discretionaryReserve > 0 else { return schedule }
        return schedule.mapValues { availableForDebt(availableCash: $0, discretionaryReserve: discretionaryReserve) }
    }

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
        oneTimeIncomeDefaultSpreadMonths: Int,
        discretionaryReserveAmount: Double = 0
    ) -> Decimal? {
        let discretionaryReserve = self.discretionaryReserve(from: discretionaryReserveAmount)

        // Fixed baseline: either show the fixed amount directly, or net via schedule when spreads are enabled.
        if baselineBudgetSourceRaw == "fixed",
           useFixedDebtBudget,
           debtBudgetOverrideAmount > 0 {
            let fixed = Decimal(debtBudgetOverrideAmount)
            if includeNonMonthlyIncomeSpreads {
                let items = (try? modelContext.fetch(FetchDescriptor<CashFlowItem>())) ?? []
                let allocations = incomeFundingAllocationTotals(modelContext: modelContext)
                let schedule = IncomeScheduler.budgetByMonth(
                    items: items,
                    start: startMonth,
                    months: 12,
                    includeSpreads: true,
                    oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths),
                    baselineSource: .fixedAmount(fixed),
                    incomeFundingAllocations: allocations
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
            let allocations = incomeFundingAllocationTotals(modelContext: modelContext)
            let schedule = IncomeScheduler.budgetByMonth(
                items: items,
                start: startMonth,
                months: 12,
                includeSpreads: includeNonMonthlyIncomeSpreads,
                oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths),
                baselineSource: .recurringNet,
                incomeFundingAllocations: allocations
            )
            guard let availableCash = schedule[startMonth] else { return nil }
            return availableForDebt(availableCash: availableCash, discretionaryReserve: discretionaryReserve)
        }

        // Unknown baseline
        return nil
    }

    private static func sanitizedDefaultSpread(_ v: Int) -> Int {
        [3, 6, 12].contains(v) ? v : 12
    }

    private static func incomeFundingAllocationTotals(modelContext: ModelContext) -> [UUID: Decimal] {
        let allocations = (try? modelContext.fetch(FetchDescriptor<BillFundingAllocation>())) ?? []
        return allocations.reduce(into: [UUID: Decimal]()) { totals, allocation in
            totals[allocation.incomeID, default: 0] += allocation.amount
        }
    }
}
