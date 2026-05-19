import Foundation
import SwiftUI
import Charts

public struct IncomeScheduler {
    static func incomeFundingAllocationTotals(from allocations: [BillFundingAllocation]) -> [UUID: Decimal] {
        allocations.reduce(into: [UUID: Decimal]()) { totals, allocation in
            totals[allocation.incomeID, default: 0] += allocation.amount
        }
    }

    public enum BaselineSource {
        case recurringNet
        case fixedAmount(Decimal)
    }
    
    static func budgetByMonth(
        items: [CashFlowItem],
        start: Date,
        months: Int,
        includeSpreads: Bool,
        oneTimeDefaultSpreadMonths: Int,
        baselineSource: BaselineSource,
        incomeFundingAllocations: [UUID: Decimal] = [:],
        clampNegativeToZero: Bool = false
    ) -> [Date: Decimal] {
        let baseline = baselineByMonth(items: items, start: start, months: months, baselineSource: baselineSource)
        let firstOfMonth = startOfMonth(start)
        let monthStarts = buildMonthStarts(from: firstOfMonth, count: months)
        
        let incomeSpreads: [Date: Decimal]
        let billSpreads: [Date: Decimal]
        if includeSpreads {
            incomeSpreads = spreadsByMonth(
                incomes: items,
                start: start,
                months: months,
                oneTimeDefaultSpreadMonths: oneTimeDefaultSpreadMonths,
                incomeFundingAllocations: incomeFundingAllocations
            )
            let bills = items.filter { $0.kind == .bill }
            billSpreads = billSpreadsByMonth(
                bills: bills,
                start: start,
                months: months,
                defaultSpreadMonths: oneTimeDefaultSpreadMonths
            )
        } else {
            incomeSpreads = [:]
            billSpreads = [:]
        }
        
        var combined: [Date: Decimal] = [:]
        for m in monthStarts {
            let base = baseline[m] ?? 0
            let inc = incomeSpreads[m] ?? 0
            let bill = billSpreads[m] ?? 0
            let sum = base + inc + bill
            if clampNegativeToZero || !includeSpreads {
                combined[m] = round2(max(0, sum))
            } else {
                combined[m] = round2(sum)
            }
        }
        return combined
    }
    
    static func baselineByMonth(
        items: [CashFlowItem],
        start: Date,
        months: Int,
        baselineSource: BaselineSource
    ) -> [Date: Decimal] {
        let firstOfMonth = startOfMonth(start)
        let monthStarts = buildMonthStarts(from: firstOfMonth, count: months)
        
        switch baselineSource {
        case .fixedAmount(let d):
            let val = round2(d)
            return Dictionary(uniqueKeysWithValues: monthStarts.map { ($0, val) })
            
        case .recurringNet:
            // Filter recurring income items (monthly/semimonthly/biweekly/weekly/socialSecurity)
            let recurringIncomeItems = items.filter {
                $0.kind == .income && frequencyIsRecurringIncome($0.frequency)
            }
            let recurringIncomeMonthlyTotal = recurringIncomeItems.reduce(Decimal(0)) {
                $0 + $1.amount * $1.frequency.monthlyEquivalentFactor
            }

            // Include only truly recurring bills in baseline (exclude non-monthly bills)
            let recurringBillItems = items.filter {
                $0.kind == .bill && frequencyIsRecurringBill($0.frequency)
            }
            let billsMonthlyTotal = recurringBillItems.reduce(Decimal(0)) {
                $0 + $1.amount * $1.frequency.monthlyEquivalentFactor
            }

            // Baseline is constant per month: recurring income minus recurring bills
            let net = recurringIncomeMonthlyTotal - billsMonthlyTotal
            let value = round2(net)
            return Dictionary(uniqueKeysWithValues: monthStarts.map { ($0, value) })
        }
    }
    
    static func spreadsByMonth(
        incomes: [CashFlowItem],
        start: Date,
        months: Int,
        oneTimeDefaultSpreadMonths: Int,
        incomeFundingAllocations: [UUID: Decimal] = [:]
    ) -> [Date: Decimal] {
        let firstOfMonth = startOfMonth(start)
        let monthStarts = buildMonthStarts(from: firstOfMonth, count: months)
        let monthSet = Set(monthStarts)
        
        let filtered = incomes.filter {
            $0.kind == .income &&
            [.yearly, .quarterly, .semiAnnual, .oneTime].contains($0.frequency)
        }
        
        var result: [Date: Decimal] = [:]
        let lastMonthStart = monthStarts.last!
        
        for item in filtered {
            // Determine base pay date for the item
            var payDate: Date
            if let fpd = item.firstPaymentDate {
                payDate = fpd
            } else if let dom = item.dayOfMonth {
                // Construct date in plan start month with dayOfMonth clamped
                let calendar = Calendar(identifier: .gregorian)
                var comps = calendar.dateComponents([.year, .month], from: firstOfMonth)
                comps.day = min(dom, calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? dom)
                payDate = calendar.date(from: comps) ?? firstOfMonth
            } else {
                payDate = item.createdAt
            }
            
            let basePayMonth = startOfMonth(payDate)
            
            // Determine spread months count N and per-occurrence period
            let N = spreadMonthsForFrequency(item.frequency, oneTimeOverride: item.oneTimeSpreadMonthsOverride, defaultOneTime: oneTimeDefaultSpreadMonths)
            guard N > 0 else { continue }
            
            let periodMonths: Int
            switch item.frequency {
            case .yearly:      periodMonths = 12
            case .semiAnnual:  periodMonths = 6
            case .quarterly:   periodMonths = 3
            case .oneTime:     periodMonths = 0
            default:           periodMonths = 0
            }
            
            let allocatedToBills = incomeFundingAllocations[item.id] ?? 0
            let amount = round2(max(0, item.amount - allocatedToBills))
            guard amount > 0 else { continue }
            let even = round2(amount / Decimal(N))
            let remainder = amount - (even * Decimal(N - 1))
            
            // Helper to apply a single occurrence's spreading starting the month after pay month
            func applyOccurrence(at payMonth: Date) {
                for i in 1..<N {
                    let spreadMonthStart = addMonths(payMonth, i)
                    if monthSet.contains(spreadMonthStart) {
                        result[spreadMonthStart, default: 0] += even
                        result[spreadMonthStart] = round2(result[spreadMonthStart]!)
                    }
                }
                let lastMonth = addMonths(payMonth, N)
                if monthSet.contains(lastMonth) {
                    result[lastMonth, default: 0] += remainder
                    result[lastMonth] = round2(result[lastMonth]!)
                }
            }
            
            if periodMonths == 0 {
                // One-time: single occurrence
                applyOccurrence(at: basePayMonth)
            } else {
                // Recurring non-monthly: start from the first occurrence on/after the horizon start.
                // Do not include any prior occurrence tails and do not backfill before firstPaymentDate.
                var startOccurrence = basePayMonth
                while startOccurrence < firstOfMonth {
                    startOccurrence = addMonths(startOccurrence, periodMonths)
                }
                // Iterate forward through occurrences until beyond the horizon
                var occurrence = startOccurrence
                while occurrence <= lastMonthStart {
                    applyOccurrence(at: occurrence)
                    occurrence = addMonths(occurrence, periodMonths)
                }
            }
        }
        
        return result
    }

    struct IncomeContribution: Identifiable, Hashable {
        public let id: UUID
        public let itemId: UUID
        public let name: String
        public let amount: Decimal
        init(itemId: UUID, name: String, amount: Decimal) {
            self.id = itemId
            self.itemId = itemId
            self.name = name
            self.amount = amount
        }
    }

    /// Builds a per-month breakdown of non-monthly income contributions by individual income item.
    /// - Parameters:
    ///   - items: All cash flow items; income items will be filtered internally.
    ///   - start: First month to include (normalized to month start internally).
    ///   - months: Number of months to include.
    ///   - oneTimeDefaultSpreadMonths: Default spread months for one-time income (allowed: 3, 6, 12; others treated as 12).
    /// - Returns: Dictionary keyed by month start date to an array of contributions for that month.
    static func contributionsByMonth(
        items: [CashFlowItem],
        start: Date,
        months: Int,
        oneTimeDefaultSpreadMonths: Int,
        incomeFundingAllocations: [UUID: Decimal] = [:]
    ) -> [Date: [IncomeContribution]] {
        let firstOfMonth = startOfMonth(start)
        let monthStarts = buildMonthStarts(from: firstOfMonth, count: months)
        let monthSet = Set(monthStarts)
        let lastMonthStart = monthStarts.last ?? firstOfMonth

        // Filter to non-monthly and one-time income sources
        let incomes = items.filter { $0.kind == .income && [.yearly, .quarterly, .semiAnnual, .oneTime].contains($0.frequency) }

        var result: [Date: [IncomeContribution]] = [:]

        for item in incomes {
            // Resolve pay date
            let payDate: Date
            if let fpd = item.firstPaymentDate {
                payDate = fpd
            } else if let dom = item.dayOfMonth {
                let calendar = Calendar(identifier: .gregorian)
                var comps = calendar.dateComponents([.year, .month], from: firstOfMonth)
                let range = calendar.range(of: .day, in: .month, for: firstOfMonth) ?? 1..<29
                comps.day = min(dom, range.count)
                payDate = calendar.date(from: comps) ?? firstOfMonth
            } else {
                payDate = item.createdAt
            }
            let basePayMonth = startOfMonth(payDate)

            // Determine spread window length and recurrence period
            let N = spreadMonthsForFrequency(item.frequency, oneTimeOverride: item.oneTimeSpreadMonthsOverride, defaultOneTime: oneTimeDefaultSpreadMonths)
            guard N > 0 else { continue }

            let periodMonths: Int
            switch item.frequency {
            case .yearly:      periodMonths = 12
            case .semiAnnual:  periodMonths = 6
            case .quarterly:   periodMonths = 3
            case .oneTime:     periodMonths = 0
            default:           periodMonths = 0
            }

            let allocatedToBills = incomeFundingAllocations[item.id] ?? 0
            let total = round2(max(0, item.amount - allocatedToBills))
            guard total > 0 else { continue }
            let even = round2(total / Decimal(N))
            let remainder = total - (even * Decimal(N - 1))

            func append(_ date: Date, amount: Decimal) {
                guard monthSet.contains(date) else { return }
                let contrib = IncomeContribution(itemId: item.id, name: item.name, amount: round2(amount))
                result[date, default: []].append(contrib)
            }

            func applyOccurrence(at payMonth: Date) {
                for i in 1..<N {
                    let m = addMonths(payMonth, i)
                    append(m, amount: even)
                }
                let lastM = addMonths(payMonth, N)
                append(lastM, amount: remainder)
            }

            if periodMonths == 0 {
                // One-time
                applyOccurrence(at: basePayMonth)
            } else {
                // Recurring non-monthly: start from the first occurrence on/after the horizon start.
                // Do not include any prior occurrence tails and do not backfill before firstPaymentDate.
                var startOccurrence = basePayMonth
                while startOccurrence < firstOfMonth {
                    startOccurrence = addMonths(startOccurrence, periodMonths)
                }
                var occurrence = startOccurrence
                while occurrence <= lastMonthStart {
                    applyOccurrence(at: occurrence)
                    occurrence = addMonths(occurrence, periodMonths)
                }
            }
        }
        return result
    }
    
    /// Builds a per-month breakdown of non-monthly bill contributions by individual bill item.
    /// Uses the same sinking-fund allocation as billSpreadsByMonth, but returns signed
    /// contributions (negative amounts) suitable for drill-down views.
    /// - Parameters:
    ///   - items: All cash flow items; bill items will be filtered internally.
    ///   - start: First month to include (normalized to month start internally).
    ///   - months: Number of months to include.
    ///   - defaultSpreadMonths: Default spread months for one-time bills (allowed: 3, 6, 12; others treated as 12).
    /// - Returns: Dictionary keyed by month start date to an array of negative contributions for that month.
    static func billContributionsByMonth(
        items: [CashFlowItem],
        start: Date,
        months: Int,
        defaultSpreadMonths: Int
    ) -> [Date: [IncomeContribution]] {
        let firstOfMonth = startOfMonth(start)
        let monthStarts = buildMonthStarts(from: firstOfMonth, count: months)
        let monthSet = Set(monthStarts)
        let lastMonthStart = monthStarts.last ?? firstOfMonth

        // Filter to non-monthly and one-time bills
        let bills = items.filter { $0.kind == .bill && [.yearly, .semiAnnual, .quarterly, .oneTime].contains($0.frequency) }

        var result: [Date: [IncomeContribution]] = [:]

        for item in bills {
            // Resolve due date similar to billSpreadsByMonth
            let dueDate: Date
            if let fpd = item.firstPaymentDate {
                dueDate = fpd
            } else if let dom = item.dayOfMonth {
                let calendar = Calendar(identifier: .gregorian)
                var comps = calendar.dateComponents([.year, .month], from: firstOfMonth)
                let rangeCount = (calendar.range(of: .day, in: .month, for: firstOfMonth)?.count) ?? 28
                comps.day = min(dom, rangeCount)
                dueDate = calendar.date(from: comps) ?? firstOfMonth
            } else {
                dueDate = item.createdAt
            }
            let baseDueMonth = startOfMonth(dueDate)

            // Determine spread window length and recurrence period
            let N = spreadMonthsForFrequency(item.frequency, oneTimeOverride: item.oneTimeSpreadMonthsOverride, defaultOneTime: defaultSpreadMonths)
            guard N > 0 else { continue }

            let periodMonths: Int
            switch item.frequency {
            case .yearly:      periodMonths = 12
            case .semiAnnual:  periodMonths = 6
            case .quarterly:   periodMonths = 3
            case .oneTime:     periodMonths = 0
            default:           periodMonths = 0
            }

            let total = round2(max(0, item.amount - item.fundingAmount))
            let even = round2(total / Decimal(N))
            let remainder = total - (even * Decimal(N - 1))

            func append(_ month: Date, amount: Decimal) {
                guard monthSet.contains(month) else { return }
                let contrib = IncomeContribution(itemId: item.id, name: item.name, amount: round2(amount))
                result[month, default: []].append(contrib)
            }

            // Apply sinking-fund allocation for a single occurrence ending in dueMonth
            func applyOccurrence(endingIn dueMonth: Date) {
                // Allocate even amounts to the N-1 months before the due month
                if N > 1 {
                    for i in 1..<(N) {
                        let m = addMonths(dueMonth, -i)
                        append(m, amount: -even)
                    }
                }
                // Allocate remainder in the due month so totals sum exactly to -total
                append(dueMonth, amount: -remainder)
            }

            if periodMonths == 0 {
                // One-time bill
                applyOccurrence(endingIn: baseDueMonth)
            } else {
                // Recurring non-monthly bills: iterate occurrences whose due month falls within the horizon only.
                // Do not expand to include pre-due months for the next occurrence beyond the horizon.
                var firstOccurrence = baseDueMonth
                while firstOccurrence > firstOfMonth {
                    firstOccurrence = addMonths(firstOccurrence, -periodMonths)
                }
                var occurrence = firstOccurrence
                while occurrence <= lastMonthStart {
                    applyOccurrence(endingIn: occurrence)
                    occurrence = addMonths(occurrence, periodMonths)
                }
            }
        }

        return result
    }
    
    static func billSpreadsByMonth(
        bills: [CashFlowItem],
        start: Date,
        months: Int,
        defaultSpreadMonths: Int
    ) -> [Date: Decimal] {
        let firstOfMonth = startOfMonth(start)
        let monthStarts = buildMonthStarts(from: firstOfMonth, count: months)
        let monthSet = Set(monthStarts)
        let lastMonthStart = monthStarts.last ?? firstOfMonth

        // Filter to non-monthly bills
        let nonMonthlyBills = bills.filter {
            $0.kind == .bill && [.yearly, .semiAnnual, .quarterly, .oneTime].contains($0.frequency)
        }

        var result: [Date: Decimal] = [:]

        for item in nonMonthlyBills {
            // Resolve due date: prefer firstPaymentDate, else clamp dayOfMonth in plan start month, else createdAt
            let dueDate: Date
            if let fpd = item.firstPaymentDate {
                dueDate = fpd
            } else if let dom = item.dayOfMonth {
                let calendar = Calendar(identifier: .gregorian)
                var comps = calendar.dateComponents([.year, .month], from: firstOfMonth)
                let rangeCount = (calendar.range(of: .day, in: .month, for: firstOfMonth)?.count) ?? 28
                comps.day = min(dom, rangeCount)
                dueDate = calendar.date(from: comps) ?? firstOfMonth
            } else {
                dueDate = item.createdAt
            }
            let baseDueMonth = startOfMonth(dueDate)

            // Determine spread window length and recurrence period
            let N = spreadMonthsForFrequency(item.frequency, oneTimeOverride: item.oneTimeSpreadMonthsOverride, defaultOneTime: defaultSpreadMonths)
            guard N > 0 else { continue }

            let periodMonths: Int
            switch item.frequency {
            case .yearly:      periodMonths = 12
            case .semiAnnual:  periodMonths = 6
            case .quarterly:   periodMonths = 3
            case .oneTime:     periodMonths = 0
            default:           periodMonths = 0
            }

            let total = round2(max(0, item.amount - item.fundingAmount))
            let even = round2(total / Decimal(N))
            let remainder = total - (even * Decimal(N - 1))

            func allocate(_ month: Date, amount: Decimal) {
                guard monthSet.contains(month) else { return }
                result[month, default: 0] += amount
                result[month] = round2(result[month]!)
            }

            // Apply sinking-fund allocation for a single occurrence ending in dueMonth
            func applyOccurrence(endingIn dueMonth: Date) {
                // Allocate even amounts to the N-1 months before the due month
                if N > 1 {
                    for i in 1..<(N) {
                        let m = addMonths(dueMonth, -i)
                        allocate(m, amount: -even)
                    }
                }
                // Allocate remainder in the due month so totals sum exactly to -total
                allocate(dueMonth, amount: -remainder)
            }

            if periodMonths == 0 {
                // One-time bill
                applyOccurrence(endingIn: baseDueMonth)
            } else {
                // Recurring non-monthly bills: apply only occurrences whose due month is within the horizon.
                // Do not pre-allocate for the next cycle beyond the horizon.
                var firstOccurrence = baseDueMonth
                while firstOccurrence > firstOfMonth {
                    firstOccurrence = addMonths(firstOccurrence, -periodMonths)
                }
                var occurrence = firstOccurrence
                while occurrence <= lastMonthStart {
                    applyOccurrence(endingIn: occurrence)
                    occurrence = addMonths(occurrence, periodMonths)
                }
            }
        }

        return result
    }
    
    // MARK: - Private Helpers
    
    private static func startOfMonth(_ date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps)!
    }
    
    private static func addMonths(_ date: Date, _ n: Int) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        guard let result = calendar.date(byAdding: .month, value: n, to: startOfMonth(date)) else {
            return startOfMonth(date)
        }
        return startOfMonth(result)
    }
    
    private static func buildMonthStarts(from start: Date, count: Int) -> [Date] {
        (0..<count).map { addMonths(start, $0) }
    }
    
    private static func round2(_ d: Decimal) -> Decimal {
        var val = d
        var rounded = Decimal()
        NSDecimalRound(&rounded, &val, 2, .plain)
        return rounded
    }
    
    private static func frequencyIsRecurringIncome(_ f: PaymentFrequency) -> Bool {
        switch f {
        case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
            return true
        default:
            return false
        }
    }
    
    private static func frequencyIsRecurringBill(_ f: PaymentFrequency) -> Bool {
        switch f {
        case .monthly:
            return true
        default:
            return false
        }
    }
    
    private static func spreadMonthsForFrequency(_ f: PaymentFrequency, oneTimeOverride: Int?, defaultOneTime: Int) -> Int {
        // Allow overrides (3/6/12) for all non-monthly income types, not just one-time
        let candidate = oneTimeOverride ?? defaultOneTime
        let override: Int? = ([3,6,12].contains(candidate) ? candidate : nil)
        switch f {
        case .yearly:
            return override ?? 12
        case .semiAnnual:
            return override ?? 6
        case .quarterly:
            return override ?? 3
        case .oneTime:
            return override ?? 12
        default:
            return 0
        }
    }
}

extension IncomeScheduler {
    struct BudgetBreakdownPreviewView: View {
        struct Segment: Identifiable {
            let id = UUID()
            let part: String
            let value: Double
        }
        
        struct MonthNetValue: Identifiable {
            let id = UUID()
            let month: Date
            let baseline: Decimal
            let spreads: Decimal
            let net: Decimal
        }
        
        let items: [CashFlowItem]
        let start: Date
        let months: Int
        let oneTimeSpreadMonths: Int
        
        func computeMonthNetValues() -> [MonthNetValue] {
            let baseline = IncomeScheduler.baselineByMonth(
                items: items,
                start: start,
                months: months,
                baselineSource: .recurringNet
            )
            let incomeSpreads = IncomeScheduler.spreadsByMonth(
                incomes: items,
                start: start,
                months: months,
                oneTimeDefaultSpreadMonths: oneTimeSpreadMonths
            )
            let billSpreads = IncomeScheduler.billSpreadsByMonth(
                bills: items.filter { $0.kind == .bill },
                start: start,
                months: months,
                defaultSpreadMonths: oneTimeSpreadMonths
            )
            
            let monthStarts = IncomeScheduler.buildMonthStarts(from: IncomeScheduler.startOfMonth(start), count: months)
            
            return monthStarts.map { month in
                let base = baseline[month] ?? 0
                let spreadsSum = (incomeSpreads[month] ?? 0) + (billSpreads[month] ?? 0)
                let net = base + spreadsSum
                // Allow spreads to be negative to render below zero/baseline
                let spreads = net - base
                return MonthNetValue(month: month, baseline: base, spreads: spreads, net: net)
            }
        }
        
        func computeSegments(from values: [MonthNetValue]) -> [Segment] {
            var segments: [Segment] = []
            for v in values {
                // Baseline portion
                segments.append(Segment(part: "Base", value: NSDecimalNumber(decimal: v.baseline).doubleValue))
                
                // Positive spreads (income)
                if v.spreads > 0 {
                    segments.append(Segment(part: "Income Spreads", value: NSDecimalNumber(decimal: v.spreads).doubleValue))
                }
                // Negative spreads (bills) — keep negative so bars render below zero
                if v.spreads < 0 {
                    segments.append(Segment(part: "Bill Spreads", value: NSDecimalNumber(decimal: v.spreads).doubleValue))
                }
            }
            return segments
        }
        
        var body: some View {
            let monthNetValues = computeMonthNetValues()
            
            // Dynamic Y-axis domain based on min/max net with padding
            let netDoubles = monthNetValues.map { NSDecimalNumber(decimal: $0.net).doubleValue }
            let minNetDouble = netDoubles.min() ?? 0
            let maxNetDouble = netDoubles.max() ?? 0
            
            Chart {
                ForEach(monthNetValues) { v in
                    // Baseline segment
                    BarMark(
                        x: .value("Month", v.month, unit: .month),
                        y: .value("Base", NSDecimalNumber(decimal: v.baseline).doubleValue)
                    )
                    // Positive spreads stack above
                    if v.spreads > 0 {
                        BarMark(
                            x: .value("Month", v.month, unit: .month),
                            y: .value("Income Spreads", NSDecimalNumber(decimal: v.spreads).doubleValue)
                        )
                    }
                    // Negative spreads render below zero/baseline
                    if v.spreads < 0 {
                        BarMark(
                            x: .value("Month", v.month, unit: .month),
                            y: .value("Bill Spreads", NSDecimalNumber(decimal: v.spreads).doubleValue)
                        )
                    }
                }
            }
            .chartForegroundStyleScale([
                "Base": Color.accentColor,
                "Income Spreads": Color.green,
                "Bill Spreads": Color.red.opacity(0.6)
            ])
            .chartYScale(domain: (minNetDouble - 25)...(maxNetDouble + 25))
        }
    }
}

