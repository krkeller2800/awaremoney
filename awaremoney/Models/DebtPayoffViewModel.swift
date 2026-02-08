// DebtPayoffViewModel.swift
// Integrates projections with the app's SwiftData Account model and Decimal math

import Foundation
import SwiftUI
import SwiftData
import Combine

@MainActor
final class DebtPayoffViewModel: ObservableObject {
    @Published var account: Account
    @Published private(set) var projection: [DebtProjectionPoint] = []
    @Published private(set) var payoffDate: Date? = nil
    @Published private(set) var confidence: Double = 1.0
    @Published private(set) var varianceMessage: String? = nil

    private let context: ModelContext

    init(account: Account, context: ModelContext) {
        self.account = account
        self.context = context
        recompute()
    }

    // MARK: - Inputs and persistence

    func setCreditCardMode(_ mode: CreditCardPaymentMode) {
        account.creditCardPaymentMode = mode
        try? context.save()
        recompute()
    }

    func setTypicalPaymentAmount(_ amount: Decimal?) {
        var terms = account.loanTerms ?? LoanTerms()
        terms.paymentAmount = amount
        account.loanTerms = terms
        try? context.save()
        recompute()
    }

    func setAPR(_ apr: Decimal?) {
        var terms = account.loanTerms ?? LoanTerms()
        terms.apr = apr
        account.loanTerms = terms
        try? context.save()
        recompute()
    }

    // MARK: - Projection

    func recompute(asOf: Date = Date()) {
        varianceMessage = nil
        // Establish baseline from the most recent BalanceSnapshot
        guard let latest = latestSnapshot() else {
            projection = []
            payoffDate = nil
            confidence = 0.2
            return
        }

        let startingBalance = owedAmount(fromSnapshot: latest)
        let apr = aprForProjection(asOf: latest.asOfDate)
        let payment = typicalPaymentAmount()
        let kind = debtKind()

        do {
            let sDay = Calendar.current.component(.day, from: latest.asOfDate)
            let start = statementDate(onOrBefore: latest.asOfDate, day: sDay)
            let points = try DebtProjectionEngine.project(
                kind: kind,
                startingBalance: startingBalance,
                apr: apr,
                payment: payment,
                startDate: start,
                maxMonths: 600
            )
            projection = points
            if let idx = points.firstIndex(where: { $0.balance == 0 }) {
                let zeroDate = points[idx].date
                payoffDate = statementDate(onOrBefore: zeroDate, day: sDay)
            } else {
                payoffDate = nil
            }
            confidence = computeConfidence(since: latest.asOfDate, asOf: asOf)
        } catch {
            projection = []
            payoffDate = nil
            confidence = 0.2
        }
    }

    // Computes variance using the latest BalanceSnapshot vs the projection as of that date
    func computeVarianceAgainstLatestStatement() {
        guard let latest = latestSnapshot(), !projection.isEmpty else {
            varianceMessage = nil
            return
        }
        let targetDate = normalizeToMonth(latest.asOfDate)
        let projectedAtStatement = projectionPoint(closestTo: targetDate)?.balance ?? 0
        let actualOwed = owedAmount(fromSnapshot: latest)
        let variance = (actualOwed - projectedAtStatement)
        let absVar = (variance < 0) ? -variance : variance
        let formatted = currency(absVar)
        let prefix = (variance >= 0) ? "+" : "-"

        let hint: String
        if absVar < 0.01 {
            hint = "No material difference."
        } else if let p = projection.first?.balance, absVar < max(Decimal(5), p * 0.005) {
            hint = "Likely rounding or timing differences."
        } else {
            hint = "Could be APR changes, fees, or different payment timing."
        }
        varianceMessage = "Projection variance: \(prefix)\(formatted). \(hint)"
    }

    // MARK: - Helpers

    private func latestSnapshot() -> BalanceSnapshot? {
        account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first
    }

    private func owedAmount(fromSnapshot snap: BalanceSnapshot) -> Decimal {
        // In this app, liabilities are stored as negative balances. Convert to positive owed.
        let bal = snap.balance
        if account.type == .loan || account.type == .creditCard {
            return bal < 0 ? -bal : bal
        } else {
            return bal
        }
    }

    private func aprForProjection(asOf date: Date) -> Decimal? {
        // Prefer APR from latest snapshot; fall back to stored loan terms
        if let latestAPR = account.balanceSnapshots
            .sorted(by: { $0.asOfDate > $1.asOfDate })
            .first(where: { $0.asOfDate <= date })?
            .interestRateAPR {
            return latestAPR
        }
        return account.loanTerms?.apr
    }

    private func typicalPaymentAmount() -> Decimal? {
        // Use stored typical payment if available
        if let amt = account.loanTerms?.paymentAmount, amt > 0 { return amt }
        return nil
    }

    private func debtKind() -> DebtKind {
        switch account.type {
        case .loan:
            return .loan
        case .creditCard:
            let mode = account.creditCardPaymentMode ?? .minimum
            return .creditCard(mode)
        default:
            // Treat other types as loans for projection fallback
            return .loan
        }
    }

    private func statementDate(onOrBefore date: Date, day: Int) -> Date {
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

    private func normalizeToMonth(_ date: Date) -> Date {
        // Align to the first day of month to match monthly projection stepping
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    private func projectionPoint(closestTo date: Date) -> DebtProjectionPoint? {
        // Find exact match by month or nearest prior
        let cal = Calendar.current
        let filtered = projection.sorted { $0.date < $1.date }
        if let exact = filtered.first(where: { cal.isDate($0.date, equalTo: date, toGranularity: .month) }) {
            return exact
        }
        // nearest prior
        return filtered.last(where: { $0.date <= date }) ?? filtered.first
    }

    private func computeConfidence(since baseline: Date, asOf: Date) -> Double {
        let days = max(0, Calendar.current.dateComponents([.day], from: baseline, to: asOf).day ?? 0)
        let raw = 1.0 - (Double(days) / 120.0)
        return max(0.2, min(1.0, raw))
    }

    // MARK: - Formatting

    func currency(_ value: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = account.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }
}

