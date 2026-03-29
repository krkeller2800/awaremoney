import Foundation

public struct IncomeScheduler {
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
        baselineSource: BaselineSource
    ) -> [Date: Decimal] {
        let baseline = baselineByMonth(items: items, start: start, months: months, baselineSource: baselineSource)
        let firstOfMonth = startOfMonth(start)
        let monthStarts = buildMonthStarts(from: firstOfMonth, count: months)
        
        let spreads: [Date: Decimal]
        if includeSpreads {
            spreads = spreadsByMonth(
                incomes: items,
                start: start,
                months: months,
                oneTimeDefaultSpreadMonths: oneTimeDefaultSpreadMonths
            )
        } else {
            spreads = [:]
        }
        
        var combined: [Date: Decimal] = [:]
        for m in monthStarts {
            let base = baseline[m] ?? 0
            let spread = spreads[m] ?? 0
            combined[m] = round2(max(0, base + spread))
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
            // Filter recurring income items
            let recurringIncomeItems = items.filter {
                $0.kind == .income && frequencyIsRecurringIncome($0.frequency)
            }
            // Sum recurring income monthly equivalent per month (same amount each month)
            let recurringIncomeMonthlyTotal = recurringIncomeItems.reduce(Decimal(0)) {
                $0 + $1.amount * $1.frequency.monthlyEquivalentFactor
            }
            // Filter bill items (kind == .bill)
            let billItems = items.filter { $0.kind == .bill }
            // For each month compute reserve seeds sum
            var reserveSeedsByMonth: [Date: Decimal] = [:]
            for monthStart in monthStarts {
                var reserveSeedSum = Decimal(0)
                for item in billItems {
                    if let plan = BillReservePlanner.planReserve(for: item, asOf: monthStart, currentReserve: item.reserveBalance) {
                        reserveSeedSum += plan.seedAmount
                    }
                }
                reserveSeedsByMonth[monthStart] = reserveSeedSum
            }
            
            // Sum bill monthly equivalent total
            let billsMonthlyTotal = billItems.reduce(Decimal(0)) {
                $0 + $1.amount * $1.frequency.monthlyEquivalentFactor
            }
            
            var result: [Date: Decimal] = [:]
            for monthStart in monthStarts {
                let reserveSeed = reserveSeedsByMonth[monthStart] ?? 0
                let net = recurringIncomeMonthlyTotal - billsMonthlyTotal - reserveSeed
                result[monthStart] = round2(net)
            }
            return result
        }
    }
    
    static func spreadsByMonth(
        incomes: [CashFlowItem],
        start: Date,
        months: Int,
        oneTimeDefaultSpreadMonths: Int
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
            
            let amount = round2(item.amount)
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
                // Recurring non-monthly: include multiple occurrences across the horizon
                // Find the nearest occurrence at or before the horizon start
                var firstOccurrence = basePayMonth
                while firstOccurrence > firstOfMonth {
                    firstOccurrence = addMonths(firstOccurrence, -periodMonths)
                }
                // Start from the occurrence at or before the horizon start; do not backfill the previous occurrence
                let startOccurrence = firstOccurrence

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
        oneTimeDefaultSpreadMonths: Int
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

            let total = round2(item.amount)
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
                // Recurring non-monthly
                var firstOccurrence = basePayMonth
                while firstOccurrence > firstOfMonth {
                    firstOccurrence = addMonths(firstOccurrence, -periodMonths)
                }
                // Start from the occurrence at or before the horizon start; do not backfill the previous occurrence
                let startOccurrence = firstOccurrence
                var occurrence = startOccurrence
                while occurrence <= lastMonthStart {
                    applyOccurrence(at: occurrence)
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

