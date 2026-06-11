#if canImport(Testing)
import Foundation
import SwiftData
import Testing
@testable import DebtScope

@Suite("DebtScope Assistant Service Tests")
@MainActor
struct DebtScopeAssistantServiceTests {
    @Test("Assistant prompt intents cover rollout smoke prompts")
    func assistantPromptIntentsCoverRolloutSmokePrompts() {
        #expect(AssistantPromptIntent(prompt: "What is my current debt picture?") == .debtPicture)
        #expect(AssistantPromptIntent(prompt: "Which debt should I focus on first and why?") == .payoffFocus)
        #expect(AssistantPromptIntent(prompt: "How much would I save by using avalanche over snowball?") == .strategySavings)
        #expect(AssistantPromptIntent(prompt: "What bills are coming up soon?") == .upcomingBills)
        #expect(AssistantPromptIntent(prompt: "Can I afford to add $100 to monthly debt payments?") == .debtAffordability)
        #expect(AssistantPromptIntent(prompt: "Show me my raw transactions and memos.") == .transactionDetails)
    }

    @Test("Assistant prompt intent recognizes original avalanche wording")
    func assistantPromptIntentRecognizesOriginalAvalancheWording() {
        #expect(AssistantPromptIntent(prompt: "How much interest do I save by using avalanche versus snowball?") == .strategySavings)
    }

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

    @Test("Payoff strategy comparison reports avalanche savings over snowball")
    func payoffStrategyComparisonReportsAvalancheSavingsOverSnowball() throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "snowball"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(300.0, forKey: "debtBudgetOverrideAmount")

        let highAPRCard = Account(name: "High APR Card", type: .creditCard, currencyCode: "USD")
        highAPRCard.loanTerms = LoanTerms(apr: Decimal(string: "0.24"), paymentAmount: 100, paymentDayOfMonth: nil)
        let lowAPRLoan = Account(name: "Small Low APR Loan", type: .loan, currencyCode: "USD")
        lowAPRLoan.loanTerms = LoanTerms(apr: Decimal(string: "0.05"), paymentAmount: 50, paymentDayOfMonth: nil)
        context.insert(highAPRCard)
        context.insert(lowAPRLoan)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -5_000, account: highAPRCard))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -1_000, account: lowAPRLoan))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let comparison = try #require(try service.payoffStrategyComparison(startDate: date(2026, 2, 14)))

        #expect(comparison.currencyCode == "USD")
        #expect(Calendar.current.component(.day, from: comparison.startDate) == 1)
        #expect(comparison.debtCount == 2)
        #expect(comparison.totalStartingDebt == 6_000)
        #expect(comparison.totalMinimumPayment == 150)
        #expect(comparison.monthlyBudget == 300)
        #expect(comparison.avalanche.strategy == .avalanche)
        #expect(comparison.snowball.strategy == .snowball)
        #expect(comparison.avalanche.payoffOrder.count == 2)
        #expect(comparison.snowball.payoffOrder.count == 2)
        #expect(comparison.avalanche.totalInterest < comparison.snowball.totalInterest)
        #expect(comparison.interestSavingsUsingAvalanche == rounded(comparison.snowball.totalInterest - comparison.avalanche.totalInterest, scale: 2))
        #expect(comparison.interestSavingsUsingAvalanche > 0)
        #expect(comparison.sourceNote.contains("avalanche and snowball"))
    }

    @Test("Cash flow summary handles empty data and clamps requested months")
    func cashFlowSummaryHandlesEmptyDataAndClampsRequestedMonths() throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.cashFlowSummary(months: 99)

        #expect(summary.currencyCode == "USD")
        #expect(summary.monthsCovered == 24)
        #expect(summary.incomeItemCount == 0)
        #expect(summary.billItemCount == 0)
        #expect(summary.monthlyIncome == 0)
        #expect(summary.monthlyBills == 0)
        #expect(summary.recurringNet == 0)
        #expect(summary.nonMonthlyIncomeMonthlyAverage == 0)
        #expect(summary.upcomingBills.isEmpty)
        #expect(summary.missingDataNotes.contains("No income items are configured yet."))
        #expect(summary.missingDataNotes.contains("No bill items are configured yet."))
    }

    @Test("Upcoming bills clamps day window and returns display-safe summaries")
    func upcomingBillsClampsDayWindowAndReturnsDisplaySafeSummaries() throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()
        let calendar = Calendar.current
        let now = Date()
        let checking = Account(name: "Bills Checking", type: .checking)
        let paycheck = CashFlowItem(
            kind: .income,
            name: "Paycheck",
            amount: 3_000,
            frequency: .monthly,
            dayOfMonth: 1
        )
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        let ninetyOneDaysOut = try #require(calendar.date(byAdding: .day, value: 91, to: now))
        let dueSoon = CashFlowItem(
            kind: .bill,
            name: "Rent",
            amount: 1_250,
            frequency: .oneTime,
            firstPaymentDate: tomorrow,
            account: checking,
            fundingIncomeID: paycheck.id
        )
        let outsideClamp = CashFlowItem(
            kind: .bill,
            name: "Annual Fee",
            amount: 95,
            frequency: .oneTime,
            firstPaymentDate: ninetyOneDaysOut
        )

        context.insert(checking)
        context.insert(paycheck)
        context.insert(dueSoon)
        context.insert(outsideClamp)
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let oneDayBills = try service.upcomingBills(days: 0)
        let clampedBills = try service.upcomingBills(days: 500)

        #expect(oneDayBills.map(\.name) == ["Rent"])
        let rentSummary = try #require(oneDayBills.first)
        #expect(rentSummary.amount == 1_250)
        #expect(rentSummary.frequency == .oneTime)
        #expect(rentSummary.accountName == "Bills Checking")
        #expect(rentSummary.fundingSourceName == "Paycheck")
        #expect(rentSummary.reserveBalance == nil)

        #expect(clampedBills.map(\.name) == ["Rent"])
    }

    @Test("Assistant settings default to hidden and privacy-first")
    func assistantSettingsDefaultToHiddenAndPrivacyFirst() {
        withPreservedAssistantDefaults {
            removeAssistantDefaults()

            let settings = SettingsStore()

            #expect(settings.assistantEnabled == false)
            #expect(settings.assistantIncludeTransactions == false)
            #expect(settings.assistantRetainConversationHistory == false)
        }
    }

    @Test("Disabling assistant clears dependent privacy settings")
    func disablingAssistantClearsDependentPrivacySettings() {
        withPreservedAssistantDefaults {
            UserDefaults.standard.set(true, forKey: "assistant_enabled")
            UserDefaults.standard.set(true, forKey: "assistant_include_transactions")
            UserDefaults.standard.set(true, forKey: "assistant_retain_conversation_history")

            let settings = SettingsStore()
            #expect(settings.assistantEnabled == true)
            #expect(settings.assistantIncludeTransactions == true)
            #expect(settings.assistantRetainConversationHistory == true)

            settings.assistantEnabled = false

            #expect(settings.assistantEnabled == false)
            #expect(settings.assistantIncludeTransactions == false)
            #expect(settings.assistantRetainConversationHistory == false)
            #expect(UserDefaults.standard.bool(forKey: "assistant_enabled") == false)
            #expect(UserDefaults.standard.bool(forKey: "assistant_include_transactions") == false)
            #expect(UserDefaults.standard.bool(forKey: "assistant_retain_conversation_history") == false)
        }
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
        UserDefaults.standard.set(0.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(0.0, forKey: "debtDiscretionaryReserveAmount")
        UserDefaults.standard.set(12, forKey: "oneTimeIncomeDefaultSpreadMonths")
        return settings
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        let components = DateComponents(year: year, month: month, day: day)
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    private func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var value = value
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .bankers)
        return result
    }

    private func withPreservedAssistantDefaults(_ operation: () -> Void) {
        let savedValues = assistantDefaultKeys.reduce(into: [String: Any]()) { result, key in
            if let value = UserDefaults.standard.object(forKey: key) {
                result[key] = value
            }
        }

        defer {
            removeAssistantDefaults()
            for (key, value) in savedValues {
                UserDefaults.standard.set(value, forKey: key)
            }
        }

        operation()
    }

    private func removeAssistantDefaults() {
        for key in assistantDefaultKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private var assistantDefaultKeys: [String] {
        [
            "assistant_enabled",
            "assistant_include_transactions",
            "assistant_retain_conversation_history"
        ]
    }
}
#endif
