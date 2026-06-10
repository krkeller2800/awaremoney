import Foundation
import SwiftData

@MainActor
final class DebtScopeAssistantService {
    private let context: ModelContext
    private let settings: SettingsStore

    init(context: ModelContext, settings: SettingsStore) {
        self.context = context
        self.settings = settings
    }

    func debtSummary() throws -> AssistantDebtSummary {
        let liabilities = try debtAccountInputs()
        let payoffDates = payoffDatesByAccountID()
        let accountSummaries = liabilities.map { input in
            AssistantDebtAccountSummary(
                name: input.account.name,
                accountType: assistantAccountType(for: input.account.type),
                institutionName: input.account.institutionName,
                latestBalance: input.latestBalance,
                latestBalanceDate: input.latestBalanceDate,
                apr: input.apr,
                minimumPayment: input.minimumPayment,
                paymentFrequency: input.account.loanTerms.map { assistantPaymentFrequency(for: $0.frequency) },
                payoffDate: payoffDates[input.account.id],
                missingAPR: input.apr == nil,
                missingMinimumPayment: input.missingMinimumPayment
            )
        }

        let highestAPRDebt = liabilities
            .compactMap { input -> (name: String, apr: Decimal)? in
                guard let apr = input.apr else { return nil }
                return (input.account.name, apr)
            }
            .max { lhs, rhs in lhs.apr < rhs.apr }

        return AssistantDebtSummary(
            generatedAt: Date(),
            currencyCode: settings.currencyCode,
            debtCount: accountSummaries.count,
            totalDebt: liabilities.reduce(0) { $0 + $1.latestBalance },
            totalMinimumPayment: liabilities.reduce(0) { $0 + $1.minimumPayment },
            highestAPRDebtName: highestAPRDebt?.name,
            highestAPR: highestAPRDebt?.apr,
            accounts: accountSummaries,
            missingDataNotes: missingDataNotes(for: liabilities, payoffDates: payoffDates)
        )
    }

    func payoffPlanSummary(startDate: Date) throws -> AssistantPayoffPlanSummary? {
        let provider = PayoffPlanProvider(context: context, settings: settings)
        guard let plan = try provider.computePlan(startDate: startDate) else { return nil }

        let liabilities = try debtAccountInputs()
        let liabilitiesByID = Dictionary(uniqueKeysWithValues: liabilities.map { ($0.account.id, $0) })
        let orderedIDs = payoffOrderIDs(from: plan, liabilities: liabilities)
        let payoffOrder = orderedIDs.enumerated().compactMap { offset, accountID -> AssistantPayoffDebtSummary? in
            guard let input = liabilitiesByID[accountID] else { return nil }
            return AssistantPayoffDebtSummary(
                name: input.account.name,
                accountType: assistantAccountType(for: input.account.type),
                startingBalance: input.latestBalance,
                apr: input.apr,
                minimumPayment: input.minimumPayment,
                payoffDate: plan.payoffDates[accountID],
                orderIndex: offset + 1
            )
        }
        let projectedDebtFreeDate = liabilities.allSatisfy { plan.payoffDates[$0.account.id] != nil }
            ? plan.payoffDates.values.max()
            : nil

        return AssistantPayoffPlanSummary(
            generatedAt: Date(),
            currencyCode: settings.currencyCode,
            strategy: assistantPayoffStrategy(),
            startDate: normalizeToMonth(startDate),
            debtCount: liabilities.count,
            totalStartingDebt: liabilities.reduce(0) { $0 + $1.latestBalance },
            totalMinimumPayment: liabilities.reduce(0) { $0 + $1.minimumPayment },
            monthlyBudget: planMonthlyBudget(startDate: startDate, totalMinimumPayment: liabilities.reduce(0) { $0 + $1.minimumPayment }),
            totalInterest: plan.totalInterest,
            projectedDebtFreeDate: projectedDebtFreeDate,
            payoffOrder: payoffOrder,
            sourceNote: "Based on DebtScope's current payoff settings and PayoffPlanProvider results."
        )
    }

    private func debtAccountInputs() throws -> [DebtAccountInput] {
        let accounts = try liabilityAccounts()
        let latestBalances = accounts.reduce(into: [UUID: LatestBalance]()) { result, account in
            result[account.id] = latestBalance(for: account)
        }

        return accounts.compactMap { account -> DebtAccountInput? in
            guard let latest = latestBalances[account.id] else { return nil }
            let balance = absDecimal(latest.balance)
            guard balance > 0 else { return nil }

            let configuredPayment = account.loanTerms?.paymentAmount
            let missingMinimumPayment = configuredPayment == nil || configuredPayment ?? 0 <= 0
            let minimumPayment = monthlyPayment(for: account, balance: balance)
            let apr = latest.apr ?? account.loanTerms?.apr

            return DebtAccountInput(
                account: account,
                latestBalance: balance,
                latestBalanceDate: latest.date,
                apr: apr,
                minimumPayment: minimumPayment,
                missingMinimumPayment: missingMinimumPayment
            )
        }
        .sorted { lhs, rhs in
            if lhs.latestBalance != rhs.latestBalance {
                return lhs.latestBalance > rhs.latestBalance
            }
            return lhs.account.name.localizedCaseInsensitiveCompare(rhs.account.name) == .orderedAscending
        }
    }

    private func liabilityAccounts() throws -> [Account] {
        let loanRaw = Account.AccountType.loan.rawValue
        let creditCardRaw = Account.AccountType.creditCard.rawValue
        let predicate = #Predicate<Account> { account in
            account.typeRaw == loanRaw || account.typeRaw == creditCardRaw
        }
        var descriptor = FetchDescriptor<Account>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\Account.name)]
        return try context.fetch(descriptor)
    }

    private func latestBalance(for account: Account) -> LatestBalance? {
        let accountID = account.id
        let predicate = #Predicate<BalanceSnapshot> { snapshot in
            snapshot.accountID == accountID
        }
        var descriptor = FetchDescriptor<BalanceSnapshot>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        descriptor.fetchLimit = 1

        guard let snapshot = try? context.fetch(descriptor).first else { return nil }
        return LatestBalance(
            balance: snapshot.balance,
            date: snapshot.asOfDate,
            apr: snapshot.interestRateAPR
        )
    }

    private func payoffDatesByAccountID() -> [UUID: Date] {
        let provider = PayoffPlanProvider(context: context, settings: settings)
        return (try? provider.computePlan(startDate: Date()))?.payoffDates ?? [:]
    }

    private func monthlyPayment(for account: Account, balance: Decimal) -> Decimal {
        if let configured = account.loanTerms?.paymentAmount, configured > 0 {
            return configured
        }
        let twoPercent = Decimal(string: "0.02") ?? 0.02
        return (balance * twoPercent).rounded(2)
    }

    private func assistantAccountType(for accountType: Account.AccountType) -> AssistantAccountType {
        switch accountType {
        case .checking:
            return .checking
        case .savings:
            return .savings
        case .creditCard:
            return .creditCard
        case .loan:
            return .loan
        case .cash:
            return .cash
        case .brokerage:
            return .brokerage
        case .property:
            return .property
        case .other:
            return .other
        }
    }

    private func assistantPayoffStrategy() -> AssistantPayoffStrategy {
        switch settings.defaultPayoffStrategyRaw.lowercased() {
        case "snowball":
            return .snowball
        case "avalanche":
            return .avalanche
        default:
            return .minimumsOnly
        }
    }

    private func assistantPaymentFrequency(for frequency: PaymentFrequency) -> AssistantPaymentFrequency {
        switch frequency {
        case .weekly:
            return .weekly
        case .biweekly, .biWeekly:
            return .biweekly
        case .semimonthly, .twiceMonthly:
            return .semimonthly
        case .monthly:
            return .monthly
        case .quarterly:
            return .quarterly
        case .semiAnnual:
            return .semiAnnual
        case .yearly, .annual:
            return .annual
        case .oneTime:
            return .oneTime
        case .socialSecurity:
            return .socialSecurity
        }
    }

    private func payoffOrderIDs(from plan: DebtPlanResult, liabilities: [DebtAccountInput]) -> [UUID] {
        var seen = Set<UUID>()
        var ordered = plan.payoffOrder.filter { seen.insert($0).inserted }
        let remaining = liabilities
            .filter { !seen.contains($0.account.id) }
            .sorted { lhs, rhs in
                let lhsDate = plan.payoffDates[lhs.account.id]
                let rhsDate = plan.payoffDates[rhs.account.id]
                switch (lhsDate, rhsDate) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                if lhs.latestBalance != rhs.latestBalance {
                    return lhs.latestBalance > rhs.latestBalance
                }
                return lhs.account.name.localizedCaseInsensitiveCompare(rhs.account.name) == .orderedAscending
            }
            .map(\.account.id)
        ordered.append(contentsOf: remaining)
        return ordered
    }

    private func planMonthlyBudget(startDate: Date, totalMinimumPayment: Decimal) -> Decimal? {
        let startMonth = normalizeToMonth(startDate)
        let baselineRaw = UserDefaults.standard.string(forKey: "baselineBudgetSourceRaw") ?? "recurringNet"
        let useFixedDebtBudget = UserDefaults.standard.bool(forKey: "useFixedDebtBudget")
        let debtBudgetOverrideAmount = UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount")
        let includeSpreads = UserDefaults.standard.bool(forKey: "includeNonMonthlyIncomeSpreads")
        let defaultSpread = UserDefaults.standard.integer(forKey: "oneTimeIncomeDefaultSpreadMonths")
        let discretionaryReserveAmount = UserDefaults.standard.double(forKey: "debtDiscretionaryReserveAmount")

        if let budget = PlanBudgetDisplay.availableBudget(
            for: startMonth,
            modelContext: context,
            baselineBudgetSourceRaw: baselineRaw,
            useFixedDebtBudget: useFixedDebtBudget,
            debtBudgetOverrideAmount: debtBudgetOverrideAmount,
            includeNonMonthlyIncomeSpreads: includeSpreads,
            oneTimeIncomeDefaultSpreadMonths: defaultSpread,
            discretionaryReserveAmount: discretionaryReserveAmount
        ) {
            return budget
        }

        return assistantPayoffStrategy() == .minimumsOnly ? totalMinimumPayment : nil
    }

    private func normalizeToMonth(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private func missingDataNotes(for debts: [DebtAccountInput], payoffDates: [UUID: Date]) -> [String] {
        var notes: [String] = []
        let missingAPRCount = debts.filter { $0.apr == nil }.count
        let missingMinimumCount = debts.filter(\.missingMinimumPayment).count
        let missingPayoffDateCount = debts.filter { payoffDates[$0.account.id] == nil }.count

        if missingAPRCount > 0 {
            notes.append("APR is missing for \(missingAPRCount) debt account(s).")
        }
        if missingMinimumCount > 0 {
            notes.append("Minimum payment is missing for \(missingMinimumCount) debt account(s); DebtScope used the standard 2% balance fallback.")
        }
        if missingPayoffDateCount > 0, !debts.isEmpty {
            notes.append("Payoff date is unavailable for \(missingPayoffDateCount) debt account(s) with the current payoff settings.")
        }
        return notes
    }

    private func absDecimal(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }
}

private struct LatestBalance {
    let balance: Decimal
    let date: Date
    let apr: Decimal?
}

private struct DebtAccountInput {
    let account: Account
    let latestBalance: Decimal
    let latestBalanceDate: Date
    let apr: Decimal?
    let minimumPayment: Decimal
    let missingMinimumPayment: Bool
}

private extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .bankers)
        return result
    }
}
