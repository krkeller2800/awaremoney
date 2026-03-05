import Foundation
import SwiftData

// MARK: - Shared payoff/projection service

/// Bundled inputs for a payoff projection.
struct PayoffInputs {
    let startingBalance: Decimal
    let apr: Decimal?
    let payment: Decimal?
    let kind: DebtKind
    let startDate: Date
    let statementDay: Int
}

/// A single source of truth for payoff projections across the app.
/// Policies:
/// - Starting balance from the latest BalanceSnapshot (positive owed for liabilities)
/// - APR: prefer latest snapshot APR on/before the baseline; else loan terms APR
/// - Payment: for loans use loanTerms.paymentAmount if set; for credit cards, defer to CreditCardPaymentMode
/// - Start date: statement date on-or-before the latest snapshot date, preferring loanTerms.paymentDayOfMonth when set
/// - Projection: delegated to DebtProjectionEngine (maxMonths ~50 years)
/// - Payoff date: first zero balance mapped to the statement date for that month
enum PayoffCalculator {
    /// Compute unified inputs for a given account.
    static func computeInputs(for account: Account, asOf: Date = Date()) -> PayoffInputs? {
        guard let latest = latestSnapshot(for: account) else { return nil }
        let starting = owedAmount(from: latest, for: account)
        guard starting > 0 else { return nil }

        let apr = aprForProjection(for: account, asOf: latest.asOfDate)

        // Determine statement day preference
        let snapshotDay = Calendar.current.component(.day, from: latest.asOfDate)
        let preferredDay = clampDay(account.loanTerms?.paymentDayOfMonth ?? snapshotDay, around: latest.asOfDate)

        let start = statementDate(onOrBefore: latest.asOfDate, day: preferredDay)
        let kind = debtKind(for: account)
        let payment = paymentFor(account: account, startingBalance: starting)

        return PayoffInputs(
            startingBalance: starting,
            apr: apr,
            payment: payment,
            kind: kind,
            startDate: start,
            statementDay: preferredDay
        )
    }

    /// Project using the engine and return points plus payoff date aligned to the statement day.
    static func project(for account: Account, asOf: Date = Date()) throws -> (points: [DebtProjectionPoint], payoffDate: Date?) {
        guard let inputs = computeInputs(for: account, asOf: asOf) else {
            return ([], nil)
        }
        let points = try DebtProjectionEngine.project(
            kind: inputs.kind,
            startingBalance: inputs.startingBalance,
            apr: inputs.apr,
            payment: inputs.payment,
            startDate: inputs.startDate,
            maxMonths: 600
        )
        if let idx = points.firstIndex(where: { $0.balance == 0 }) {
            let zero = points[idx].date
            let payoff = statementDate(onOrBefore: zero, day: inputs.statementDay)
            return (points, payoff)
        } else {
            return (points, nil)
        }
    }

    /// Convenience when only the payoff date is needed.
    static func payoffDate(for account: Account, asOf: Date = Date()) -> Date? {
        do { return try project(for: account, asOf: asOf).payoffDate } catch { return nil }
    }
}

// MARK: - Private helpers

private extension PayoffCalculator {
    static func latestSnapshot(for account: Account) -> BalanceSnapshot? {
        account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first
    }

    static func owedAmount(from snapshot: BalanceSnapshot, for account: Account) -> Decimal {
        let bal = snapshot.balance
        switch account.type {
        case .loan, .creditCard:
            return bal < 0 ? -bal : bal
        default:
            return bal
        }
    }

    static func aprForProjection(for account: Account, asOf date: Date) -> Decimal? {
        if let snapAPR = account.balanceSnapshots
            .sorted(by: { $0.asOfDate > $1.asOfDate })
            .first(where: { $0.asOfDate <= date })?
            .interestRateAPR {
            return snapAPR
        }
        return account.loanTerms?.apr
    }

    static func debtKind(for account: Account) -> DebtKind {
        switch account.type {
        case .loan:
            return .loan
        case .creditCard:
            return .creditCard(account.creditCardPaymentMode ?? .minimum)
        default:
            return .loan
        }
    }

    static func paymentFor(account: Account, startingBalance: Decimal) -> Decimal? {
        switch account.type {
        case .loan:
            if let p = account.loanTerms?.paymentAmount, p > 0 { return p }
            return nil
        case .creditCard:
            let mode = account.creditCardPaymentMode ?? .minimum
            switch mode {
            case .payInFull:
                // Let engine handle pay-in-full via DebtKind; do not force amount.
                return nil
            case .fixedAmount:
                if let p = account.loanTerms?.paymentAmount, p > 0 { return p }
                return nil
            case .minimum:
                // If a typical payment is provided, treat it as the minimum payment due and use it.
                if let p = account.loanTerms?.paymentAmount, p > 0 {
                    return p
                }
                // Otherwise, leave nil so the engine computes a fallback minimum.
                return nil
            }
        default:
            if let p = account.loanTerms?.paymentAmount, p > 0 { return p }
            return nil
        }
    }

    static func clampDay(_ day: Int, around referenceDate: Date) -> Int {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: referenceDate))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        return min(max(1, day), range.count)
    }

    static func statementDate(onOrBefore date: Date, day: Int) -> Date {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, day), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        let candidate = cal.date(from: comps)!
        if candidate <= date { return candidate }
        let prevMonth = cal.date(byAdding: DateComponents(month: -1), to: monthStart)!
        let prevRange = cal.range(of: .day, in: .month, for: prevMonth)!
        let prevClamped = min(max(1, day), prevRange.count)
        var prevComps = cal.dateComponents([.year, .month], from: prevMonth)
        prevComps.day = prevClamped
        return cal.date(from: prevComps)!
    }

    static func nextStatementDate(after date: Date, day: Int) -> Date {
        let cal = Calendar.current
        let nextMonth = cal.date(byAdding: DateComponents(month: 1), to: date)!
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: nextMonth))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, day), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        return cal.date(from: comps)!
    }
}
