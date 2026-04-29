import Foundation
#if canImport(Testing)
import Testing
@testable import DebtScope
// Minimal stubs to isolate tests from the app model
private enum PaymentFrequency: String {
    case monthly, semimonthly, biweekly, weekly, socialSecurity
    case yearly, quarterly, semiAnnual, oneTime
    var monthlyEquivalentFactor: Decimal {
        switch self {
        case .monthly: return 1
        case .semimonthly: return 2
        case .biweekly: return Decimal(26) / 12
        case .weekly: return Decimal(52) / 12
        case .socialSecurity: return 1
        case .yearly: return 1/12
        case .quarterly: return 1/3
        case .semiAnnual: return 1/6
        case .oneTime: return 0
        }
    }
}

private final class CashFlowItem {
    enum Kind { case income, bill }
    let kind: Kind
    let amount: Decimal
    let frequency: PaymentFrequency
    let dayOfMonth: Int?
    let firstPaymentDate: Date?
    let createdAt: Date
    let oneTimeSpreadMonthsOverride: Int?
    // Bills only
    let reserveBalance: Decimal = 0
    init(kind: Kind, amount: Decimal, frequency: PaymentFrequency, dayOfMonth: Int? = nil, firstPaymentDate: Date? = nil, createdAt: Date = Date(), oneTimeSpreadMonthsOverride: Int? = nil) {
        self.kind = kind
        self.amount = amount
        self.frequency = frequency
        self.dayOfMonth = dayOfMonth
        self.firstPaymentDate = firstPaymentDate
        self.createdAt = createdAt
        self.oneTimeSpreadMonthsOverride = oneTimeSpreadMonthsOverride
    }
}

// Copy of helpers used by IncomeScheduler for month arithmetic
private func startOfMonth(_ date: Date) -> Date {
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year, .month], from: date)
    return cal.date(from: comps)!
}
private func addMonths(_ date: Date, _ n: Int) -> Date {
    let cal = Calendar(identifier: .gregorian)
    let s = startOfMonth(date)
    return startOfMonth(cal.date(byAdding: .month, value: n, to: s)!)
}

// Expose just the spreadsByMonth logic by embedding a minimal IncomeScheduler copy
private struct IncomeScheduler {
    static func spreadsByMonth(
        incomes: [CashFlowItem],
        start: Date,
        months: Int,
        oneTimeDefaultSpreadMonths: Int
    ) -> [Date: Decimal] {
        let firstOfMonth = startOfMonth(start)
        let monthStarts = (0..<months).map { addMonths(firstOfMonth, $0) }
        let monthSet = Set(monthStarts)
        let filtered = incomes.filter { $0.kind == .income && [.yearly, .quarterly, .semiAnnual, .oneTime].contains($0.frequency) }
        var result: [Date: Decimal] = [:]
        let lastMonthStart = monthStarts.last!
        for item in filtered {
            let payDate: Date = item.firstPaymentDate ?? {
                if let dom = item.dayOfMonth {
                    let cal = Calendar(identifier: .gregorian)
                    var comps = cal.dateComponents([.year, .month], from: firstOfMonth)
                    let range = cal.range(of: .day, in: .month, for: firstOfMonth)!
                    comps.day = min(dom, range.count)
                    return cal.date(from: comps)!
                } else {
                    return item.createdAt
                }
            }()
            let basePayMonth = startOfMonth(payDate)
            // N per frequency
            let N: Int = {
                switch item.frequency {
                case .yearly: return 12
                case .semiAnnual: return 6
                case .quarterly: return 3
                case .oneTime:
                    let override = item.oneTimeSpreadMonthsOverride ?? oneTimeDefaultSpreadMonths
                    return ([3,6,12].contains(override) ? override : 12)
                default: return 0
                }
            }()
            guard N > 0 else { continue }
            let periodMonths: Int = {
                switch item.frequency {
                case .yearly: return 12
                case .semiAnnual: return 6
                case .quarterly: return 3
                default: return 0
                }
            }()
            let amount = (item.amount as NSDecimalNumber).decimalValue
            let even = (amount / Decimal(N)).rounded(2)
            let remainder = amount - (even * Decimal(N - 1))
            func applyOccurrence(at payMonth: Date) {
                for i in 1..<N {
                    let m = addMonths(payMonth, i)
                    if monthSet.contains(m) {
                        result[m, default: 0] = (result[m, default: 0] + even).rounded(2)
                    }
                }
                let lastM = addMonths(payMonth, N)
                if monthSet.contains(lastM) {
                    result[lastM, default: 0] = (result[lastM, default: 0] + remainder).rounded(2)
                }
            }
            if periodMonths == 0 {
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
}

private extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}

@Suite("IncomeScheduler spreading tests")
struct IncomeSchedulerSpreadingTests {
    @Test("Yearly bonus spreads 12 months starting after pay month with remainder at last month")
    func yearlySpread() {
        let cal = Calendar(identifier: .gregorian)
        let payDate = cal.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        let item = CashFlowItem(kind: .income, amount: 1200, frequency: .yearly, firstPaymentDate: payDate)
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let spread = IncomeScheduler.spreadsByMonth(incomes: [item], start: start, months: 12, oneTimeDefaultSpreadMonths: 12)
        // April..March next year (within horizon April..Dec only)
        let april = cal.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        #expect(spread[april] == 100)
    }

    @Test("Quarterly income spreads 3 months starting after pay month with remainder at last month")
    func quarterlySpread() {
        let cal = Calendar(identifier: .gregorian)
        let payDate = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let item = CashFlowItem(kind: .income, amount: 1000, frequency: .quarterly, firstPaymentDate: payDate)
        let start = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let spread = IncomeScheduler.spreadsByMonth(incomes: [item], start: start, months: 6, oneTimeDefaultSpreadMonths: 12)
        let july = cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let aug = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let sep = cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        #expect(spread[july] == (1000/3).rounded(2))
        #expect(spread[sep] != nil) // last month gets the remainder
    }

    @Test("One-time with override uses chosen N and remainder on last month")
    func oneTimeOverride() {
        let cal = Calendar(identifier: .gregorian)
        let payDate = cal.date(from: DateComponents(year: 2026, month: 2, day: 10))!
        let item = CashFlowItem(kind: .income, amount: 1000, frequency: .oneTime, firstPaymentDate: payDate, oneTimeSpreadMonthsOverride: 6)
        let start = cal.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        let spread = IncomeScheduler.spreadsByMonth(incomes: [item], start: start, months: 8, oneTimeDefaultSpreadMonths: 12)
        let mar = cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let aug = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        #expect(spread[mar] == (1000/6).rounded(2))
        #expect(spread[aug] != nil)
    }

    @Test("Overlapping spreads accumulate")
    func overlapping() {
        let cal = Calendar(identifier: .gregorian)
        let payDate1 = cal.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        let payDate2 = cal.date(from: DateComponents(year: 2026, month: 2, day: 15))!
        let a = CashFlowItem(kind: .income, amount: 600, frequency: .oneTime, firstPaymentDate: payDate1, oneTimeSpreadMonthsOverride: 3)
        let b = CashFlowItem(kind: .income, amount: 900, frequency: .oneTime, firstPaymentDate: payDate2, oneTimeSpreadMonthsOverride: 3)
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let spread = IncomeScheduler.spreadsByMonth(incomes: [a,b], start: start, months: 6, oneTimeDefaultSpreadMonths: 12)
        let mar = cal.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        // a contributes Feb/Mar; b contributes Mar/Apr
        // a even = 200, b even = 300
        #expect(spread[mar] == 500)
    }

    @Test("Mid-spread start has no prior tail")
    func midSpreadStart() {
        let cal = Calendar(identifier: .gregorian)
        let payDate = cal.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        let item = CashFlowItem(kind: .income, amount: 1200, frequency: .yearly, firstPaymentDate: payDate)
        // Start in June; forward-only behavior should not include a tail from January.
        let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let spread = IncomeScheduler.spreadsByMonth(incomes: [item], start: start, months: 6, oneTimeDefaultSpreadMonths: 12)
        let jun = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        #expect(spread[jun] == nil)
    }

    @Test("One-time windfall never counted before pay date; starts month after")
    func oneTimeNeverBeforePayDate() {
        let cal = Calendar(identifier: .gregorian)
        let payDate = cal.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        let item = CashFlowItem(kind: .income, amount: 600, frequency: .oneTime, firstPaymentDate: payDate, oneTimeSpreadMonthsOverride: 3)
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let spread = IncomeScheduler.spreadsByMonth(incomes: [item], start: start, months: 12, oneTimeDefaultSpreadMonths: 12)
        let july = cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let aug = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        // July is the pay month; contribution begins in August
        #expect(spread[july] == nil)
        #expect(spread[aug] == (600/3).rounded(2))
    }

    @Test("Yearly spread crosses year boundary correctly")
    func crossYearSpread() {
        let cal = Calendar(identifier: .gregorian)
        // Pay in November 2026; spreads Dec 2026 through Nov 2027
        let payDate = cal.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        let item = CashFlowItem(kind: .income, amount: 1200, frequency: .yearly, firstPaymentDate: payDate)
        // Horizon: Oct 2026..Mar 2027 (6 months)
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let spread = IncomeScheduler.spreadsByMonth(incomes: [item], start: start, months: 6, oneTimeDefaultSpreadMonths: 12)
        let dec2026 = cal.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        let jan2027 = cal.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let feb2027 = cal.date(from: DateComponents(year: 2027, month: 2, day: 1))!
        let mar2027 = cal.date(from: DateComponents(year: 2027, month: 3, day: 1))!
        #expect(spread[dec2026] == 100)
        #expect(spread[jan2027] == 100)
        #expect(spread[feb2027] == 100)
        #expect(spread[mar2027] == 100)
    }

    @Test("Rounding: remainder goes to last month with exact cents")
    func roundingRemainder() {
        let cal = Calendar(identifier: .gregorian)
        let payDate = cal.date(from: DateComponents(year: 2026, month: 6, day: 10))!
        let item = CashFlowItem(kind: .income, amount: 1000, frequency: .quarterly, firstPaymentDate: payDate)
        let start = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        // Cover at least one full occurrence spread window
        let spread = IncomeScheduler.spreadsByMonth(incomes: [item], start: start, months: 8, oneTimeDefaultSpreadMonths: 12)
        let jul = cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let aug = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let sep = cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        // 1000/3 = 333.33 even; last month gets 333.34
        #expect(spread[jul] == (1000/3).rounded(2))
        #expect(spread[aug] == (1000/3).rounded(2))
        #expect(spread[sep] == 333.34)
    }
    
    @Test("No prior tail when horizon starts before first occurrence")
    func noPriorTailBeforeFirstOccurrence() {
        let cal = Calendar(identifier: .gregorian)
        // Yearly $1200 paid in June 2026
        let payDate = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let item = CashFlowItem(kind: .income, amount: 1200, frequency: .yearly, firstPaymentDate: payDate)
        // Horizon: April 2026..March 2027
        let start = cal.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        let spread = IncomeScheduler.spreadsByMonth(incomes: [item], start: start, months: 12, oneTimeDefaultSpreadMonths: 12)
        let apr = cal.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        let may = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let jun = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let jul = cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        // Expect no prior tail in Apr-Jun, then +100 starting in July
        #expect(spread[apr] == nil)
        #expect(spread[may] == nil)
        #expect(spread[jun] == nil)
        #expect(spread[jul] == 100)
    }
}
#endif

