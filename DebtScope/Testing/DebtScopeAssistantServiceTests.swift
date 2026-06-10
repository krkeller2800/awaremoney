#if canImport(Testing)
import Foundation
import SwiftData
import Testing
@testable import DebtScope

@Suite("DebtScope Assistant Service Tests")
@MainActor
struct DebtScopeAssistantServiceTests {
    @Test("Debt summary returns display-safe liability totals")
    func debtSummaryReturnsDisplaySafeLiabilityTotals() throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()

        let card = Account(
            name: "Rewards Card",
            type: .creditCard,
            institutionName: "Sample Bank",
            currencyCode: "USD"
        )
        card.loanTerms = LoanTerms(apr: Decimal(string: "0.2199"), paymentAmount: 75, paymentDayOfMonth: nil)
        let loan = Account(name: "Auto Loan", type: .loan, currencyCode: "USD")
        let checking = Account(name: "Checking", type: .checking, currencyCode: "USD")

        context.insert(card)
        context.insert(loan)
        context.insert(checking)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -1_200, account: card))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 2, 1), balance: -1_000, interestRateAPR: Decimal(string: "0.2499"), account: card))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 2, 1), balance: 5_000, account: loan))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 2, 1), balance: 2_500, account: checking))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.debtSummary()

        #expect(summary.currencyCode == "USD")
        #expect(summary.debtCount == 2)
        #expect(summary.totalDebt == 6_000)
        #expect(summary.totalMinimumPayment == 175)
        #expect(summary.highestAPRDebtName == "Rewards Card")
        #expect(summary.highestAPR == Decimal(string: "0.2499"))
        #expect(summary.accounts.map(\.name) == ["Auto Loan", "Rewards Card"])

        let cardSummary = try #require(summary.accounts.first { $0.name == "Rewards Card" })
        #expect(cardSummary.accountType == .creditCard)
        #expect(cardSummary.institutionName == "Sample Bank")
        #expect(cardSummary.latestBalance == 1_000)
        #expect(cardSummary.apr == Decimal(string: "0.2499"))
        #expect(cardSummary.minimumPayment == 75)
        #expect(cardSummary.paymentFrequency == .monthly)
        #expect(cardSummary.missingAPR == false)
        #expect(cardSummary.missingMinimumPayment == false)

        let loanSummary = try #require(summary.accounts.first { $0.name == "Auto Loan" })
        #expect(loanSummary.accountType == .loan)
        #expect(loanSummary.latestBalance == 5_000)
        #expect(loanSummary.minimumPayment == 100)
        #expect(loanSummary.missingAPR == true)
        #expect(loanSummary.missingMinimumPayment == true)
        #expect(summary.missingDataNotes.contains("APR is missing for 1 debt account(s)."))
        #expect(summary.missingDataNotes.contains("Minimum payment is missing for 1 debt account(s); DebtScope used the standard 2% balance fallback."))
    }

    @Test("Debt summary ignores zero-balance and asset accounts")
    func debtSummaryIgnoresZeroBalanceAndAssetAccounts() throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()

        let paidCard = Account(name: "Paid Card", type: .creditCard)
        let savings = Account(name: "Savings", type: .savings)
        context.insert(paidCard)
        context.insert(savings)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 3, 1), balance: 0, account: paidCard))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 3, 1), balance: 10_000, account: savings))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.debtSummary()

        #expect(summary.debtCount == 0)
        #expect(summary.totalDebt == 0)
        #expect(summary.totalMinimumPayment == 0)
        #expect(summary.highestAPRDebtName == nil)
        #expect(summary.highestAPR == nil)
        #expect(summary.accounts.isEmpty)
        #expect(summary.missingDataNotes.isEmpty)
    }

    @Test("Payoff plan summary reuses current DebtScope plan settings")
    func payoffPlanSummaryReusesCurrentDebtScopePlanSettings() throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "avalanche"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(300.0, forKey: "debtBudgetOverrideAmount")

        let highAPRCard = Account(name: "High APR Card", type: .creditCard, currencyCode: "USD")
        highAPRCard.loanTerms = LoanTerms(apr: Decimal(string: "0.24"), paymentAmount: 50, paymentDayOfMonth: nil)
        let lowAPRLoan = Account(name: "Low APR Loan", type: .loan, currencyCode: "USD")
        lowAPRLoan.loanTerms = LoanTerms(apr: Decimal(string: "0.05"), paymentAmount: 75, paymentDayOfMonth: nil)
        context.insert(highAPRCard)
        context.insert(lowAPRLoan)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -1_000, account: highAPRCard))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -3_000, account: lowAPRLoan))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try #require(try service.payoffPlanSummary(startDate: date(2026, 2, 14)))

        #expect(summary.currencyCode == "USD")
        #expect(summary.strategy == .avalanche)
        #expect(Calendar.current.component(.day, from: summary.startDate) == 1)
        #expect(summary.debtCount == 2)
        #expect(summary.totalStartingDebt == 4_000)
        #expect(summary.totalMinimumPayment == 125)
        #expect(summary.monthlyBudget == 300)
        #expect(summary.totalInterest > 0)
        #expect(summary.projectedDebtFreeDate != nil)
        #expect(summary.payoffOrder.count == 2)
        #expect(summary.payoffOrder.map(\.orderIndex) == [1, 2])
        #expect(summary.payoffOrder.first?.name == "High APR Card")
        #expect(summary.payoffOrder.first?.apr == Decimal(string: "0.24"))
        #expect(summary.payoffOrder.first?.minimumPayment == 50)
        #expect(summary.sourceNote.contains("PayoffPlanProvider"))
    }

    @Test("Payoff plan summary is nil without active debt")
    func payoffPlanSummaryIsNilWithoutActiveDebt() throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()
        let savings = Account(name: "Savings", type: .savings)
        context.insert(savings)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: 1_000, account: savings))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.payoffPlanSummary(startDate: date(2026, 2, 1))

        #expect(summary == nil)
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Account.self,
            BalanceSnapshot.self,
            CashFlowItem.self,
            BillFundingAllocation.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func makeSettings() -> SettingsStore {
        let settings = SettingsStore()
        settings.currencyCode = "USD"
        settings.defaultPayoffStrategyRaw = "minimumsOnly"
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(false, forKey: "useFixedDebtBudget")
        return settings
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        let components = DateComponents(year: year, month: month, day: day)
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }
}
#endif
