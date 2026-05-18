import Foundation

/// Result describing the next due date computation for a bill.
public struct NextDueResult: Equatable {
    /// The computed next due date strictly after `asOf`.
    public let nextDueDate: Date
    /// Whole months until due (minimum 1).
    public let monthsUntilDue: Int
}

/// Result describing a reserve plan for a non-monthly bill.
public struct ReservePlan: Equatable {
    /// Monthly contribution needed to be on track by the next due date.
    public let monthlyContribution: Decimal
    /// One-time seed to compensate for missing months (if any).
    public let seedAmount: Decimal
}

public enum BillReservePlanner {
    /// Compute the next due date for a bill and months-until-due.
    /// - Parameters:
    ///   - item: The cash flow item (bill or income). Uses `firstPaymentDate` if present; otherwise falls back to `dayOfMonth` within `asOf` month; otherwise `asOf`.
    ///   - asOf: Reference date for the computation.
    /// - Returns: `NextDueResult` with a next date strictly after `asOf` and months-until-due >= 1.
    static func nextDue(for item: CashFlowItem, asOf: Date = Date()) -> NextDueResult {
        let cal = Calendar.current
        let monthsPer = item.frequency.monthsPerCycle

        // Establish a base reference date
        var base: Date
        if let first = item.firstPaymentDate {
            base = cal.startOfDay(for: first)
        } else if let dom = item.dayOfMonth, dom > 0 {
            // Construct a date in the current month, clamped to the month's length
            let comps = cal.dateComponents([.year, .month], from: asOf)
            let openRange = cal.range(of: .day, in: .month, for: asOf)
            let range: ClosedRange<Int> = openRange.map { $0.lowerBound...$0.upperBound - 1 } ?? 1...28
            let clamped = min(max(dom, range.lowerBound), range.upperBound)
            base = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: clamped)) ?? cal.startOfDay(for: asOf)
        } else {
            base = cal.startOfDay(for: asOf)
        }

        // Step forward by monthsPerCycle until strictly after asOf
        var next = base
        if next <= asOf {
            next = cal.date(byAdding: .month, value: monthsPer, to: next) ?? next
            while next <= asOf {
                next = cal.date(byAdding: .month, value: monthsPer, to: next) ?? next
            }
        }

        // Whole months between asOf and next; clamp to >= 1
        let monthsUntil = max(1, wholeMonths(between: asOf, and: next, calendar: cal))
        return NextDueResult(nextDueDate: next, monthsUntilDue: monthsUntil)
    }

    /// Plan a reserve strategy for a non-monthly bill.
    /// - Parameters:
    ///   - item: The bill item. If income or not reserve-eligible, returns `nil`.
    ///   - asOf: Reference date.
    ///   - currentReserve: Current saved amount toward this bill.
    /// - Returns: `ReservePlan` or `nil` when not applicable.
    static func planReserve(for item: CashFlowItem, asOf: Date = Date(), currentReserve: Decimal) -> ReservePlan? {
        guard item.kind == .bill, item.frequency.isReserveEligible else { return nil }
        let freqMonths = max(1, item.frequency.monthsPerCycle)
        let next = nextDue(for: item, asOf: asOf)
        let monthsUntil = next.monthsUntilDue

        let reserveTarget = max(0, item.amount - item.fundingAmount)

        // If already fully funded
        if currentReserve >= reserveTarget { return ReservePlan(monthlyContribution: 0, seedAmount: 0) }

        // Monthly contribution based on remaining need divided by frequency months
        let remaining = max(0, reserveTarget - currentReserve)
        var monthly = remaining / Decimal(freqMonths)
        monthly = monthly.rounded(scale: 2)
        if monthly < 0 { monthly = 0 }

        // Missing months: how many cycles already passed since the last saving opportunity
        // Example: if due in 1 month for a yearly bill, missing = 11; seed = monthly * missing
        let missingMonths = max(0, freqMonths - monthsUntil)
        var seed = monthly * Decimal(missingMonths)
        seed = seed.rounded(scale: 2)

        return ReservePlan(monthlyContribution: monthly, seedAmount: seed)
    }
}

// MARK: - Utilities
private func wholeMonths(between start: Date, and end: Date, calendar: Calendar) -> Int {
    let s = calendar.dateComponents([.year, .month], from: start)
    let e = calendar.dateComponents([.year, .month], from: end)
    let years = (e.year ?? 0) - (s.year ?? 0)
    let months = (e.month ?? 0) - (s.month ?? 0)
    return max(0, years * 12 + months)
}

public extension Decimal {
    /// Round to a given number of fraction digits using plain rounding (half-up).
    func rounded(scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}
