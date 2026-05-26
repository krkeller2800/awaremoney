import Foundation
import SwiftData

@MainActor
final class PayoffPlanProvider {
    private let context: ModelContext
    private let settings: SettingsStore

    init(context: ModelContext, settings: SettingsStore) {
        self.context = context
        self.settings = settings
    }

    func computePlan(startDate: Date) throws -> DebtPlanResult? {
        let accounts = try context.fetch(FetchDescriptor<Account>()).filter { $0.type == .loan || $0.type == .creditCard }
        let liabilities = accounts.filter { absDecimal(latestBalance($0)) > 0 }
        guard !liabilities.isEmpty else { return nil }

        let strategy: PayoffStrategy = {
            switch settings.defaultPayoffStrategyRaw.lowercased() {
            case "snowball": return .snowball
            case "avalanche": return .avalanche
            default: return .minimumsOnly
            }
        }()

        let includeSpreads = UserDefaults.standard.bool(forKey: "includeNonMonthlyIncomeSpreads")
        let defaultSpread = UserDefaults.standard.integer(forKey: "oneTimeIncomeDefaultSpreadMonths")
        let baselineRaw = UserDefaults.standard.string(forKey: "baselineBudgetSourceRaw") ?? "recurringNet"
        let useFixedDebtBudget = UserDefaults.standard.bool(forKey: "useFixedDebtBudget")
        let debtBudgetOverrideAmount = UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount")
        let debtPaymentReinvestmentRate = UserDefaults.standard.object(forKey: "debtPaymentReinvestmentRate") as? Double ?? 1
        let discretionaryReserve = PlanBudgetDisplay.discretionaryReserve(
            from: UserDefaults.standard.double(forKey: "debtDiscretionaryReserveAmount")
        )

        let debts: [DebtInput] = liabilities.map { acct in
            let bal = absDecimal(latestBalance(acct))
            return DebtInput(
                id: acct.id,
                name: acct.name,
                apr: acct.loanTerms?.apr,
                balance: bal,
                minPayment: monthlyPayment(for: acct, balance: bal)
            )
        }

        let startMonth = normalizeToMonth(startDate)

        if includeSpreads || baselineRaw == "recurringNet" {
            let availableCashSchedule = IncomeScheduler.budgetByMonth(
                items: allCashFlowItems(),
                start: startMonth,
                months: 60,
                includeSpreads: includeSpreads,
                oneTimeDefaultSpreadMonths: sanitizedSpread(defaultSpread),
                baselineSource: baselineRaw == "fixed" && useFixedDebtBudget && debtBudgetOverrideAmount > 0
                    ? .fixedAmount(Decimal(debtBudgetOverrideAmount))
                    : .recurringNet,
                incomeFundingAllocations: incomeFundingAllocationTotals()
            )
            let schedule = PlanBudgetDisplay.reserveAdjustedBudgetSchedule(
                availableCashSchedule,
                discretionaryReserve: discretionaryReserve,
                appliesReserve: baselineRaw == "recurringNet"
            )
            return try DebtPayoffEngine.plan(
                debts: debts,
                budgetByMonth: schedule,
                strategy: strategy,
                reinvestmentRate: Decimal(debtPaymentReinvestmentRate),
                startDate: startMonth
            )
        } else {
            let budget: Decimal
            if useFixedDebtBudget && debtBudgetOverrideAmount > 0 {
                budget = Decimal(debtBudgetOverrideAmount)
            } else {
                if strategy == .minimumsOnly {
                    budget = debts.reduce(0) { $0 + $1.minPayment }
                } else {
                    budget = 0
                }
            }
            return try DebtPayoffEngine.plan(
                debts: debts,
                monthlyBudget: budget,
                strategy: strategy,
                reinvestmentRate: Decimal(debtPaymentReinvestmentRate),
                startDate: startMonth
            )
        }
    }

    func currentSubtitle() -> String {
        let strategyText: String = {
            switch settings.defaultPayoffStrategyRaw.lowercased() {
            case "snowball": return "Snowball"
            case "avalanche": return "Avalanche"
            default: return "Minimums"
            }
        }()
        let useFixedDebtBudget = UserDefaults.standard.bool(forKey: "useFixedDebtBudget")
        let debtBudgetOverrideAmount = UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount")
        let discretionaryReserveAmount = UserDefaults.standard.double(forKey: "debtDiscretionaryReserveAmount")
        var budgetText = ""
        if useFixedDebtBudget && debtBudgetOverrideAmount > 0 {
            if let formatted = currency(Decimal(debtBudgetOverrideAmount), code: settings.currencyCode) {
                budgetText = " • Adj Budget: \(formatted)"
            }
        } else if discretionaryReserveAmount > 0, let formatted = currency(PlanBudgetDisplay.discretionaryReserve(from: discretionaryReserveAmount), code: settings.currencyCode) {
            budgetText = " • Reserve: \(formatted)"
        }
        return "Start now • \(strategyText)\(budgetText)"
    }

    private func absDecimal(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

    private func latestBalance(_ account: Account) -> Decimal {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        let snap = try? context.fetch(desc).first
        return snap?.balance ?? 0
    }

    private func monthlyPayment(for account: Account, balance: Decimal) -> Decimal {
        if let configured = account.loanTerms?.paymentAmount, configured > 0 { return configured }
        let twoPercent = Decimal(string: "0.02") ?? 0.02
        return (balance * twoPercent).rounded(2)
    }

    private func allCashFlowItems() -> [CashFlowItem] {
        do { return try context.fetch(FetchDescriptor<CashFlowItem>()) } catch { return [] }
    }

    private func incomeFundingAllocationTotals() -> [UUID: Decimal] {
        let allocations = (try? context.fetch(FetchDescriptor<BillFundingAllocation>())) ?? []
        return allocations.reduce(into: [UUID: Decimal]()) { totals, allocation in
            totals[allocation.incomeID, default: 0] += allocation.amount
        }
    }

    private func normalizeToMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    private func sanitizedSpread(_ v: Int) -> Int { [3,6,12].contains(v) ? v : 12 }

    private func currency(_ value: Decimal, code: String) -> String? {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = code
        return nf.string(from: NSDecimalNumber(decimal: value))
    }
}

private extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .bankers)
        return result
    }
}
