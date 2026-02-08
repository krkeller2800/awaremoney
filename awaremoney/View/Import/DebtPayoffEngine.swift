import Foundation

public enum PayoffStrategy {
    case minimumsOnly
    case snowball
    case avalanche
}

public struct DebtInput: Hashable {
    public let id: UUID
    public let name: String
    public let apr: Decimal?
    public let balance: Decimal
    public let minPayment: Decimal

    public init(id: UUID, name: String, apr: Decimal?, balance: Decimal, minPayment: Decimal) {
        self.id = id
        self.name = name
        self.apr = apr
        self.balance = balance
        self.minPayment = minPayment
    }
}

public struct DebtMonthResult {
    public let date: Date
    public let payments: [UUID: Decimal]
    public let balances: [UUID: Decimal]
    public let interest: [UUID: Decimal]

    public init(date: Date, payments: [UUID: Decimal], balances: [UUID: Decimal], interest: [UUID: Decimal]) {
        self.date = date
        self.payments = payments
        self.balances = balances
        self.interest = interest
    }
}

public struct DebtPlanResult {
    public let months: [DebtMonthResult]
    public let payoffDates: [UUID: Date]
    public let payoffOrder: [UUID]
    public let totalInterest: Decimal

    public init(months: [DebtMonthResult], payoffDates: [UUID: Date], payoffOrder: [UUID], totalInterest: Decimal) {
        self.months = months
        self.payoffDates = payoffDates
        self.payoffOrder = payoffOrder
        self.totalInterest = totalInterest
    }
}

public enum DebtPlanError: Error {
    case infeasibleBudget(requiredMinimum: Decimal)
}

public enum DebtPayoffEngine {
    public static func plan(
        debts: [DebtInput],
        monthlyBudget: Decimal,
        strategy: PayoffStrategy,
        startDate: Date,
        maxMonths: Int = 600
    ) throws -> DebtPlanResult {
        // Filter debts with balance > 0 and minPayment >= 0
        let filteredDebts = debts.filter { $0.balance > 0 && $0.minPayment >= 0 }
        if filteredDebts.isEmpty {
            return DebtPlanResult(months: [], payoffDates: [:], payoffOrder: [], totalInterest: 0)
        }
        // Sum min payments
        let sumMinPayments = filteredDebts.reduce(Decimal(0)) { $0 + $1.minPayment }
        if monthlyBudget < sumMinPayments {
            throw DebtPlanError.infeasibleBudget(requiredMinimum: sumMinPayments)
        }
        // Normalize startDate to first of month (year-month)
        let calendar = Calendar(identifier: .gregorian)
        let startComponents = calendar.dateComponents([.year, .month], from: startDate)
        guard let normalizedStartDate = calendar.date(from: startComponents) else {
            return DebtPlanResult(months: [], payoffDates: [:], payoffOrder: [], totalInterest: 0)
        }

        // State variables
        var balances: [UUID: Decimal] = [:]
        var aprs: [UUID: Decimal] = [:]
        var minPayments: [UUID: Decimal] = [:]
        var names: [UUID: String] = [:]
        for debt in filteredDebts {
            balances[debt.id] = debt.balance.rounded(2)
            aprs[debt.id] = debt.apr ?? 0
            minPayments[debt.id] = debt.minPayment.rounded(2)
            names[debt.id] = debt.name
        }

        var payoffDates: [UUID: Date] = [:]
        var payoffOrder: [UUID] = []
        var months: [DebtMonthResult] = []
        var totalInterest: Decimal = 0

        func openDebts() -> [UUID] {
            balances.filter { $0.value > 0 }.map { $0.key }
        }

        func selectTargetDebt(openDebtIDs: [UUID]) -> UUID? {
            guard !openDebtIDs.isEmpty else { return nil }
            switch strategy {
            case .minimumsOnly:
                return nil
            case .snowball:
                // lowest balance first, tie break: highest apr, then name
                let sorted = openDebtIDs.sorted { a, b in
                    let balA = balances[a] ?? 0
                    let balB = balances[b] ?? 0
                    if balA != balB {
                        return balA < balB
                    }
                    let aprA = aprs[a] ?? 0
                    let aprB = aprs[b] ?? 0
                    if aprA != aprB {
                        return aprA > aprB
                    }
                    let nameA = names[a] ?? ""
                    let nameB = names[b] ?? ""
                    return nameA < nameB
                }
                return sorted.first
            case .avalanche:
                // highest APR first (nil APR treated as 0), tie break: highest balance, then name
                let sorted = openDebtIDs.sorted { a, b in
                    let aprA = aprs[a] ?? 0
                    let aprB = aprs[b] ?? 0
                    if aprA != aprB {
                        return aprA > aprB
                    }
                    let balA = balances[a] ?? 0
                    let balB = balances[b] ?? 0
                    if balA != balB {
                        return balA > balB
                    }
                    let nameA = names[a] ?? ""
                    let nameB = names[b] ?? ""
                    return nameA < nameB
                }
                return sorted.first
            }
        }

        for monthIndex in 0..<maxMonths {
            let monthDate = calendar.date(byAdding: .month, value: monthIndex, to: normalizedStartDate)!
            let openIDs = openDebts()
            if openIDs.isEmpty {
                break
            }
            let targetDebt = selectTargetDebt(openDebtIDs: openIDs)

            // Base payments: min(minPayment, balance)
            var basePayments: [UUID: Decimal] = [:]
            for id in openIDs {
                let bal = balances[id] ?? 0
                let minPay = minPayments[id] ?? 0
                basePayments[id] = min(minPay, bal).rounded(2)
            }
            let sumBasePayments = basePayments.values.reduce(0, +)

            var extraBudget = (monthlyBudget - sumBasePayments).clampedLowerBound(0)

            var payments: [UUID: Decimal] = basePayments

            if strategy != .minimumsOnly, let target = targetDebt {
                let currentPayment = payments[target] ?? 0
                let bal = balances[target] ?? 0
                let remainingBalance = (bal - currentPayment).clampedLowerBound(0)
                let extraPayment = min(extraBudget, remainingBalance)
                let newPayment = (currentPayment + extraPayment).rounded(2)
                payments[target] = newPayment
                extraBudget -= extraPayment
                if extraBudget < 0 {
                    extraBudget = 0
                }
            }

            // Apply payments and interest
            var monthInterest: [UUID: Decimal] = [:]
            var newBalances: [UUID: Decimal] = [:]
            for id in balances.keys {
                let bal = balances[id] ?? 0
                let payment = payments[id] ?? 0
                let effectivePayment = min(payment, bal)
                let interestBase = (bal - effectivePayment).clampedLowerBound(0)
                let monthlyRate = ((aprs[id] ?? 0) / 12).rounded(12)
                let interest = (interestBase * monthlyRate).rounded(2)
                let newBal = max(0, (interestBase + interest).rounded(2))
                monthInterest[id] = interest
                newBalances[id] = newBal
            }

            // Record payoff dates and order
            for (id, oldBal) in balances {
                let newBal = newBalances[id] ?? 0
                if oldBal > 0 && newBal == 0 && payoffDates[id] == nil {
                    payoffDates[id] = monthDate
                    payoffOrder.append(id)
                }
            }

            // Accumulate total interest
            totalInterest += monthInterest.values.reduce(0, +)

            // Update balances
            balances = newBalances

            // Record month result
            let monthResult = DebtMonthResult(
                date: monthDate,
                payments: payments,
                balances: balances,
                interest: monthInterest
            )
            months.append(monthResult)
        }

        return DebtPlanResult(
            months: months,
            payoffDates: payoffDates,
            payoffOrder: payoffOrder,
            totalInterest: totalInterest.rounded(2)
        )
    }
}

fileprivate extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .bankers)
        return result
    }
}

fileprivate extension Decimal {
    func clampedLowerBound(_ lower: Decimal) -> Decimal {
        return self < lower ? lower : self
    }
}
