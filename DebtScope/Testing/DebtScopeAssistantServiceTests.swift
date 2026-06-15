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
        #expect(AssistantPromptIntent(prompt: "What happens if I add $100 per month to debt payments?") == .extraPaymentSimulation)
        #expect(AssistantPromptIntent(prompt: "What changed after my latest import?") == .importReview)
        #expect(AssistantPromptIntent(prompt: "What needs review in account mapping?") == .importReview)
        #expect(AssistantPromptIntent(prompt: "What should I clean up next?") == .cleanupRecommendations)
        #expect(AssistantPromptIntent(prompt: "How do I fix my missing APRs?") == .cleanupRecommendations)
        #expect(AssistantPromptIntent(prompt: "How do I fix my missing minimum payment?") == .cleanupRecommendations)
        #expect(AssistantPromptIntent(prompt: "How do I resolve account mapping issues?") == .cleanupRecommendations)
        #expect(AssistantPromptIntent(prompt: "How do I complete bill and income schedules?") == .cleanupRecommendations)
        #expect(AssistantPromptIntent(prompt: "Show me my raw transactions and memos.") == .transactionDetails)
    }

    @Test("Assistant prompt intent recognizes original avalanche wording")
    func assistantPromptIntentRecognizesOriginalAvalancheWording() {
        #expect(AssistantPromptIntent(prompt: "How much interest do I save by using avalanche versus snowball?") == .strategySavings)
        #expect(AssistantPromptIntent(prompt: "How much interest will I save by using avalanche over snowball") == .strategySavings)
    }

    @Test("Import review question focus recognizes specific follow-up categories")
    func importReviewQuestionFocusRecognizesSpecificFollowUpCategories() {
        #expect(AssistantImportReviewQuestionFocus(prompt: "Do I have duplicate import candidates?") == .duplicates)
        #expect(AssistantImportReviewQuestionFocus(prompt: "Are there account mapping issues from my latest import?") == .accountMapping)
        #expect(AssistantImportReviewQuestionFocus(prompt: "What import records are excluded or edited?") == .conflicts)
        #expect(AssistantImportReviewQuestionFocus(prompt: "What changed after my latest import?") == .latestImport)
        #expect(AssistantImportReviewQuestionFocus(prompt: "Summarize my recent imports") == .general)
    }

    @Test("Cleanup recommendation focus recognizes how-to cleanup prompts")
    func cleanupRecommendationFocusRecognizesHowToPrompts() {
        #expect(AssistantCleanupRecommendationFocus(prompt: "How do I fix my missing APRs?") == .missingAPR)
        #expect(AssistantCleanupRecommendationFocus(prompt: "How do I fix my missing minimum payment?") == .missingMinimumPayments)
        #expect(AssistantCleanupRecommendationFocus(prompt: "How do I resolve account mapping issues?") == .accountMapping)
        #expect(AssistantCleanupRecommendationFocus(prompt: "How do I clean up duplicate imports?") == .duplicateImports)
        #expect(AssistantCleanupRecommendationFocus(prompt: "How do I complete bill and income schedules?") == .cashFlowSchedules)
    }

    @Test("Debt summary returns display-safe liability totals")
    func debtSummaryReturnsDisplaySafeLiabilityTotals() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

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
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

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
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

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
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

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
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

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
        #expect(comparison.minimumPayments.strategy == .minimumsOnly)
        #expect(comparison.minimumPayments.paymentFeasible == true)
        #expect(comparison.avalanche.strategy == .avalanche)
        #expect(comparison.avalanche.paymentFeasible == true)
        #expect(comparison.snowball.strategy == .snowball)
        #expect(comparison.snowball.paymentFeasible == true)
        #expect(comparison.avalanche.payoffOrder.count == 2)
        #expect(comparison.snowball.payoffOrder.count == 2)
        #expect(comparison.avalanche.totalInterest < comparison.snowball.totalInterest)
        #expect(comparison.interestSavingsUsingAvalanche == rounded(comparison.snowball.totalInterest - comparison.avalanche.totalInterest, scale: 2))
        #expect(comparison.interestSavingsUsingAvalanche > 0)
        #expect(comparison.missingDataNotes.isEmpty)
        #expect(comparison.sourceNote.contains("minimum-payment, avalanche, and snowball"))
    }

    @Test("Payoff strategy comparison returns missing-data summary without active debt")
    func payoffStrategyComparisonReturnsMissingDataSummaryWithoutActiveDebt() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()

        let savings = Account(name: "Savings", type: .savings)
        context.insert(savings)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: 1_000, account: savings))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let comparison = try #require(try service.payoffStrategyComparison(startDate: date(2026, 2, 14)))

        #expect(comparison.debtCount == 0)
        #expect(comparison.totalStartingDebt == 0)
        #expect(comparison.minimumPayments.paymentFeasible == false)
        #expect(comparison.avalanche.paymentFeasible == false)
        #expect(comparison.snowball.paymentFeasible == false)
        #expect(comparison.missingDataNotes.contains("No active credit-card or loan debts with current balances are available to compare."))
    }

    @Test("Payoff strategy comparison discloses missing APR and minimum payment inputs")
    func payoffStrategyComparisonDisclosesMissingInputs() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(300.0, forKey: "debtBudgetOverrideAmount")

        let card = Account(name: "Card Missing Terms", type: .creditCard, currencyCode: "USD")
        context.insert(card)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -1_000, account: card))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let comparison = try #require(try service.payoffStrategyComparison(startDate: date(2026, 2, 14)))

        #expect(comparison.debtCount == 1)
        #expect(comparison.minimumPayments.paymentFeasible == true)
        #expect(comparison.avalanche.paymentFeasible == true)
        #expect(comparison.snowball.paymentFeasible == true)
        #expect(comparison.missingDataNotes.contains { $0.contains("APR is missing for 1 debt account") })
        #expect(comparison.missingDataNotes.contains { $0.contains("Minimum payment is missing for 1 debt account") })
    }

    @Test("Payoff strategy comparison treats minimum-payment fallback budget as feasible for all strategies")
    func payoffStrategyComparisonTreatsMinimumFallbackBudgetAsFeasibleForAllStrategies() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "minimumsOnly"
        UserDefaults.standard.set(false, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(0.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        let highAPRCard = Account(name: "High APR Card", type: .creditCard, currencyCode: "USD")
        highAPRCard.loanTerms = LoanTerms(apr: Decimal(string: "0.24"), paymentAmount: 100, paymentDayOfMonth: nil)
        let lowAPRLoan = Account(name: "Low APR Loan", type: .loan, currencyCode: "USD")
        lowAPRLoan.loanTerms = LoanTerms(apr: Decimal(string: "0.05"), paymentAmount: 75, paymentDayOfMonth: nil)
        context.insert(highAPRCard)
        context.insert(lowAPRLoan)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -5_000, account: highAPRCard))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -1_000, account: lowAPRLoan))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let comparison = try #require(try service.payoffStrategyComparison(startDate: date(2026, 2, 14)))

        #expect(comparison.monthlyBudget == 175)
        #expect(comparison.minimumPayments.paymentFeasible == true)
        #expect(comparison.avalanche.paymentFeasible == true)
        #expect(comparison.snowball.paymentFeasible == true)
        #expect(comparison.minimumPayments.totalInterest > 0)
        #expect(comparison.avalanche.totalInterest > 0)
        #expect(comparison.snowball.totalInterest > 0)
        #expect(comparison.missingDataNotes.isEmpty)
    }

    @Test("Payoff strategy comparison can use temporary monthly budget override without saving settings")
    func payoffStrategyComparisonCanUseTemporaryMonthlyBudgetOverrideWithoutSavingSettings() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "avalanche"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(4_000.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        let highAPRCard = Account(name: "High APR Card", type: .creditCard, currencyCode: "USD")
        highAPRCard.loanTerms = LoanTerms(apr: Decimal(string: "0.24"), paymentAmount: 100, paymentDayOfMonth: nil)
        let lowAPRLoan = Account(name: "Low APR Loan", type: .loan, currencyCode: "USD")
        lowAPRLoan.loanTerms = LoanTerms(apr: Decimal(string: "0.05"), paymentAmount: 75, paymentDayOfMonth: nil)
        context.insert(highAPRCard)
        context.insert(lowAPRLoan)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -50_000, account: highAPRCard))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -10_000, account: lowAPRLoan))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)
        let currentBudgetComparison = try #require(try service.payoffStrategyComparison(startDate: date(2026, 6, 11)))
        let overrideComparison = try #require(try service.payoffStrategyComparison(
            startDate: date(2026, 6, 11),
            monthlyBudgetOverride: 3_500
        ))

        #expect(currentBudgetComparison.monthlyBudget == 4_000)
        #expect(overrideComparison.monthlyBudget == 3_500)
        #expect(overrideComparison.avalanche.paymentFeasible == true)
        #expect(overrideComparison.snowball.paymentFeasible == true)
        #expect(overrideComparison.avalanche.totalInterest != currentBudgetComparison.avalanche.totalInterest)
        #expect(overrideComparison.snowball.totalInterest != currentBudgetComparison.snowball.totalInterest)
        #expect(UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount") == 4_000.0)
    }

    @Test("Extra payment simulation with zero extra matches baseline")
    func extraPaymentSimulationWithZeroExtraMatchesBaseline() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "avalanche"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(300.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        insertTwoDebtFixture(in: context)
        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.extraPaymentSimulation(extraMonthlyPayment: 0, startDate: date(2026, 2, 14))

        #expect(summary.status == .valid)
        #expect(summary.extraMonthlyPayment == 0)
        #expect(summary.strategy == .avalanche)
        #expect(summary.baselineMonthlyBudget == 300)
        #expect(summary.scenarioMonthlyBudget == 300)
        #expect(summary.interestSaved == 0)
        #expect(summary.baseline?.totalInterest == summary.scenario?.totalInterest)
        #expect(summary.baseline?.projectedDebtFreeDate == summary.scenario?.projectedDebtFreeDate)
        #expect(summary.firstAffectedAccountName == nil)
    }

    @Test("Positive extra payment improves or equals feasible payoff timing")
    func positiveExtraPaymentImprovesOrEqualsFeasiblePayoffTiming() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "avalanche"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(300.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        insertTwoDebtFixture(in: context)
        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.extraPaymentSimulation(
            extraMonthlyPayment: 100,
            startDate: date(2026, 2, 14),
            scenarioStrategy: .avalanche
        )

        #expect(summary.status == .valid)
        #expect(summary.strategy == .avalanche)
        #expect(summary.scenarioStrategy == .avalanche)
        #expect(summary.baselineMonthlyBudget == 300)
        #expect(summary.scenarioMonthlyBudget == 400)
        #expect(summary.baseline?.paymentFeasible == true)
        #expect(summary.scenario?.paymentFeasible == true)
        #expect((summary.interestSaved ?? -1) >= 0)
        #expect((summary.debtFreeDateAdvantageMonths ?? 0) >= 0)
    }

    @Test("Positive extra payment asks for strategy when omitted")
    func positiveExtraPaymentAsksForStrategyWhenOmitted() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "avalanche"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(300.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        insertTwoDebtFixture(in: context)
        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.extraPaymentSimulation(extraMonthlyPayment: 100, startDate: date(2026, 2, 14))

        #expect(summary.status == .unavailable)
        #expect(summary.validationMessage == "Choose which strategy to use (minimums, avalanche, or snowball) when applying the extra payment.")
        #expect(summary.baseline == nil)
        #expect(summary.scenario == nil)
    }

    @Test("Extra payment simulation reports minimum budget for minimums-only strategy")
    func extraPaymentSimulationReportsMinimumBudgetForMinimumsOnlyStrategy() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "minimumsOnly"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(4_000.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        insertTwoDebtFixture(in: context)
        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.extraPaymentSimulation(extraMonthlyPayment: 0, startDate: date(2026, 2, 14))

        #expect(summary.status == .valid)
        #expect(summary.strategy == .minimumsOnly)
        #expect(summary.scenarioStrategy == .minimumsOnly)
        #expect(summary.baselineMonthlyBudget == 175)
        #expect(summary.scenarioMonthlyBudget == 175)
        #expect(UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount") == 4_000.0)
    }

    @Test("Positive extra payment asks for strategy when baseline is minimums-only")
    func positiveExtraPaymentAsksForStrategyWhenBaselineIsMinimumsOnly() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "minimumsOnly"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(4_000.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        insertTwoDebtFixture(in: context)
        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.extraPaymentSimulation(extraMonthlyPayment: 150, startDate: date(2026, 2, 14))

        #expect(summary.status == .unavailable)
        #expect(summary.strategy == .minimumsOnly)
        #expect(summary.scenarioStrategy == .minimumsOnly)
        #expect(summary.baselineMonthlyBudget == 175)
        #expect(summary.scenarioMonthlyBudget == nil)
        #expect(summary.validationMessage == "Choose which strategy to use (minimums, avalanche, or snowball) when applying the extra payment.")
        #expect(summary.baseline == nil)
        #expect(summary.scenario == nil)
        #expect(UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount") == 4_000.0)
    }

    @Test("Positive extra payment can use minimums strategy")
    func positiveExtraPaymentCanUseMinimumsStrategy() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "minimumsOnly"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(4_000.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        insertTwoDebtFixture(in: context)
        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.extraPaymentSimulation(
            extraMonthlyPayment: 150,
            startDate: date(2026, 2, 14),
            scenarioStrategy: .minimumsOnly
        )

        #expect(summary.status == .valid)
        #expect(summary.strategy == .minimumsOnly)
        #expect(summary.scenarioStrategy == .minimumsOnly)
        #expect(summary.baselineMonthlyBudget == 175)
        #expect(summary.scenarioMonthlyBudget == 325)
        #expect((summary.interestSaved ?? 0) > 0)
        #expect(summary.scenario?.totalInterest != summary.baseline?.totalInterest)
        #expect(summary.firstAffectedAccountName == nil)
        #expect(UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount") == 4_000.0)
    }

    @Test("Positive extra payment uses requested strategy when baseline is minimums-only")
    func positiveExtraPaymentUsesRequestedStrategyWhenBaselineIsMinimumsOnly() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        settings.defaultPayoffStrategyRaw = "minimumsOnly"
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(4_000.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        insertTwoDebtFixture(in: context)
        let service = DebtScopeAssistantService(context: context, settings: settings)
        let summary = try service.extraPaymentSimulation(
            extraMonthlyPayment: 150,
            startDate: date(2026, 2, 14),
            scenarioStrategy: .snowball
        )

        #expect(summary.status == .valid)
        #expect(summary.strategy == .minimumsOnly)
        #expect(summary.scenarioStrategy == .snowball)
        #expect(summary.baselineMonthlyBudget == 175)
        #expect(summary.scenarioMonthlyBudget == 325)
        #expect((summary.interestSaved ?? 0) > 0)
        #expect(summary.scenario?.totalInterest != summary.baseline?.totalInterest)
        #expect(UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount") == 4_000.0)
    }

    @Test("Invalid extra payment values return validation without saved setting changes")
    func invalidExtraPaymentValuesReturnValidationWithoutSavedSettingChanges() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(4_000.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        insertTwoDebtFixture(in: context)
        let service = DebtScopeAssistantService(context: context, settings: settings)
        let negative = try service.extraPaymentSimulation(extraMonthlyPayment: -100, startDate: date(2026, 2, 14))
        let unrealistic = try service.extraPaymentSimulation(extraMonthlyPayment: 100_001, startDate: date(2026, 2, 14))

        #expect(negative.status == .invalidAmount)
        #expect(negative.baseline == nil)
        #expect(negative.scenario == nil)
        #expect(unrealistic.status == .invalidAmount)
        #expect(unrealistic.baseline == nil)
        #expect(unrealistic.scenario == nil)
        #expect(UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount") == 4_000.0)
        #expect(UserDefaults.standard.bool(forKey: "useFixedDebtBudget") == true)
        #expect(UserDefaults.standard.string(forKey: "baselineBudgetSourceRaw") == "fixed")
    }

    @Test("Assistant prompt amount parser treats word zero as zero")
    func assistantPromptAmountParserTreatsWordZeroAsZero() {
        #expect(AssistantPromptAmountParser.signedMonthlyAmount(in: "What happens if I add zero extra payment?") == 0)
        #expect(AssistantPromptAmountParser.signedMonthlyAmount(in: "Using a zero monthly extra payment starting June 2026 compare payoff.") == 0)
        #expect(AssistantPromptAmountParser.signedMonthlyAmount(in: "What happens if I add $3,500 per month?") == 3_500)
        #expect(AssistantPromptAmountParser.extraPaymentStrategy(in: "What happens if I add $100 using minimums?") == .minimumsOnly)
        #expect(AssistantPromptAmountParser.extraPaymentStrategy(in: "What happens if I add $100 to minimum payments?") == .minimumsOnly)
        #expect(AssistantPromptAmountParser.extraPaymentStrategy(in: "What happens if I add $100 using avalanche?") == .avalanche)
        #expect(AssistantPromptAmountParser.extraPaymentStrategy(in: "What happens if I add $100 using snowball?") == .snowball)
        #expect(AssistantPromptAmountParser.extraPaymentStrategy(in: "Minimum") == .minimumsOnly)
        #expect(AssistantPromptAmountParser.extraPaymentStrategy(in: "Avalanche") == .avalanche)
        #expect(AssistantPromptAmountParser.extraPaymentStrategy(in: "Snowball") == .snowball)
        #expect(AssistantPromptAmountParser.extraPaymentStrategy(in: "What happens if I add $100?") == nil)
    }

    @Test("Extra payment simulation does not write payoff defaults")
    func extraPaymentSimulationDoesNotWritePayoffDefaults() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(4_000.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(250.0, forKey: "debtDiscretionaryReserveAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")
        UserDefaults.standard.set(6, forKey: "oneTimeIncomeDefaultSpreadMonths")

        insertTwoDebtFixture(in: context)
        let service = DebtScopeAssistantService(context: context, settings: settings)
        _ = try service.extraPaymentSimulation(extraMonthlyPayment: 100, startDate: date(2026, 2, 14))

        #expect(UserDefaults.standard.bool(forKey: "useFixedDebtBudget") == true)
        #expect(UserDefaults.standard.string(forKey: "baselineBudgetSourceRaw") == "fixed")
        #expect(UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount") == 4_000.0)
        #expect(UserDefaults.standard.double(forKey: "debtDiscretionaryReserveAmount") == 250.0)
        #expect(UserDefaults.standard.bool(forKey: "includeNonMonthlyIncomeSpreads") == false)
        #expect(UserDefaults.standard.integer(forKey: "oneTimeIncomeDefaultSpreadMonths") == 6)
    }

    @Test("Assistant read-only defaults snapshot restores payoff budget settings")
    func assistantReadOnlyDefaultsSnapshotRestoresPayoffBudgetSettings() {
        let suiteName = "DebtScopeAssistantReadOnlyDefaultsSnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "useFixedDebtBudget")
        defaults.set("fixed", forKey: "baselineBudgetSourceRaw")
        defaults.set(4_000.0, forKey: "debtBudgetOverrideAmount")

        let snapshot = DebtScopeAssistantReadOnlyDefaultsSnapshot.capture(defaults: defaults)
        defaults.set(100.0, forKey: "debtBudgetOverrideAmount")
        defaults.set(false, forKey: "useFixedDebtBudget")
        defaults.set("recurringNet", forKey: "baselineBudgetSourceRaw")

        snapshot.restore(defaults: defaults)

        #expect(defaults.bool(forKey: "useFixedDebtBudget") == true)
        #expect(defaults.string(forKey: "baselineBudgetSourceRaw") == "fixed")
        #expect(defaults.double(forKey: "debtBudgetOverrideAmount") == 4_000.0)
    }

    @Test("Payoff strategy comparison unavailable details explain infeasible budget")
    func payoffStrategyComparisonUnavailableDetailsExplainInfeasibleBudget() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(100.0, forKey: "debtBudgetOverrideAmount")
        UserDefaults.standard.set(false, forKey: "includeNonMonthlyIncomeSpreads")

        let card = Account(name: "High APR Card", type: .creditCard, currencyCode: "USD")
        card.loanTerms = LoanTerms(apr: Decimal(string: "0.24"), paymentAmount: 100, paymentDayOfMonth: nil)
        let loan = Account(name: "Small Loan", type: .loan, currencyCode: "USD")
        loan.loanTerms = LoanTerms(apr: Decimal(string: "0.05"), paymentAmount: 75, paymentDayOfMonth: nil)
        context.insert(card)
        context.insert(loan)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -5_000, account: card))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -1_000, account: loan))
        try context.save()

        let service = DebtScopeAssistantService(context: context, settings: settings)

        let comparison = try #require(try service.payoffStrategyComparison(startDate: date(2026, 2, 14)))

        #expect(comparison.minimumPayments.paymentFeasible == false)
        #expect(comparison.avalanche.paymentFeasible == false)
        #expect(comparison.snowball.paymentFeasible == false)
        #expect(comparison.missingDataNotes.contains { $0.contains("Current monthly payoff budget is $100.00") })
        #expect(comparison.missingDataNotes.contains { $0.contains("minimum payments require at least $175.00") })
    }

    @Test("Cash flow summary handles empty data and clamps requested months")
    func cashFlowSummaryHandlesEmptyDataAndClampsRequestedMonths() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

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
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

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

    @Test("Import review returns empty state without imports")
    func importReviewReturnsEmptyStateWithoutImports() throws {
        let context = try makeInMemoryContext()
        let settings = makeSettings()
        let service = DebtScopeAssistantService(context: context, settings: settings)

        let summary = try service.importReviewSummary()

        #expect(summary.importCount == 0)
        #expect(summary.latestImport == nil)
        #expect(summary.recentImports.isEmpty)
        #expect(summary.totalImportedBalanceCount == 0)
        #expect(summary.totalImportedTransactionCount == 0)
        #expect(summary.totalImportedHoldingCount == 0)
        #expect(summary.duplicateTransactionCandidateCount == 0)
        #expect(summary.conflictCount == 0)
        #expect(summary.unresolvedAccountMappingCount == 0)
        #expect(summary.includesTransactionLevelDetail == false)
        #expect(summary.reviewNotes.contains("No completed imports are available to review."))
    }

    @Test("Import review summarizes duplicates conflicts and mappings without transaction details")
    func importReviewSummarizesDuplicatesConflictsAndMappingsWithoutTransactionDetails() throws {
        withPreservedAssistantDefaults {
            UserDefaults.standard.set(false, forKey: "assistant_include_transactions")

            do {
                let context = try makeInMemoryContext()
                let settings = makeSettings()
                let checking = Account(name: "Main Checking", type: .checking, institutionName: "Sample Bank")
                let latestBatch = ImportBatch(
                    createdAt: date(2026, 5, 12),
                    label: "sample-bank-may.csv",
                    sourceFileName: "sample-bank-may.csv",
                    parserId: "bank.csv"
                )
                let olderBatch = ImportBatch(
                    createdAt: date(2026, 4, 12),
                    label: "Older Import",
                    sourceFileName: "older.csv",
                    parserId: "bank.csv"
                )

                context.insert(checking)
                context.insert(latestBatch)
                context.insert(olderBatch)
                context.insert(Transaction(
                    datePosted: date(2026, 5, 1),
                    amount: -25,
                    payee: "Coffee",
                    memo: "Private memo should not be surfaced",
                    hashKey: "duplicate-key",
                    account: checking,
                    importBatch: latestBatch,
                    importHashKey: "duplicate-key"
                ))
                context.insert(Transaction(
                    datePosted: date(2026, 5, 1),
                    amount: -25,
                    payee: "Coffee Duplicate",
                    hashKey: "duplicate-key",
                    importBatch: latestBatch,
                    isUserEdited: true,
                    importHashKey: "duplicate-key"
                ))
                context.insert(Transaction(
                    datePosted: date(2026, 4, 1),
                    amount: -10,
                    payee: "Older",
                    hashKey: "older-key",
                    account: checking,
                    importBatch: olderBatch,
                    isExcluded: true,
                    importHashKey: "older-key"
                ))
                context.insert(BalanceSnapshot(
                    asOfDate: date(2026, 5, 12),
                    balance: 1_000,
                    account: checking,
                    importBatch: latestBatch
                ))
                context.insert(BalanceSnapshot(
                    asOfDate: date(2026, 5, 12),
                    balance: 2_000,
                    importBatch: latestBatch,
                    isUserModified: true
                ))
                try context.save()

                let service = DebtScopeAssistantService(context: context, settings: settings)
                let summary = try service.importReviewSummary(recentLimit: 1)

                #expect(summary.importCount == 2)
                #expect(summary.recentImports.count == 1)
                #expect(summary.latestImport?.label == "sample-bank-may")
                #expect(summary.latestImport?.parserName == "bank.csv")
                #expect(summary.latestImport?.detectedInstitutionName == "Sample Bank")
                #expect(summary.latestImport?.importedBalanceCount == 2)
                #expect(summary.latestImport?.importedTransactionCount == 2)
                #expect(summary.latestImport?.editedRecordCount == 2)
                #expect(summary.latestImport?.unresolvedAccountMappingCount == 2)
                #expect(summary.totalImportedBalanceCount == 2)
                #expect(summary.totalImportedTransactionCount == 3)
                #expect(summary.duplicateTransactionCandidateCount == 2)
                #expect(summary.conflictCount == 3)
                #expect(summary.unresolvedAccountMappingCount == 2)
                #expect(summary.mappedAccountCount == 1)
                #expect(summary.transactionLevelDetailAvailable == false)
                #expect(summary.includesTransactionLevelDetail == false)
                #expect(summary.sourceNote.contains("Raw file contents"))
                #expect(summary.reviewNotes.contains { $0.contains("duplicate import keys") })
                #expect(summary.reviewNotes.contains { $0.contains("account mapping review") })
            } catch {
                Issue.record(error)
            }
        }
    }

    @Test("Cleanup recommendations summarize current app state without transaction details")
    func cleanupRecommendationsSummarizeCurrentAppStateWithoutTransactionDetails() throws {
        withPreservedAssistantDefaults {
            UserDefaults.standard.set(false, forKey: "assistant_include_transactions")

            do {
                let context = try makeInMemoryContext()
                let settings = makeSettings()
                let checking = Account(name: "Main Checking", type: .checking, institutionName: "Sample Bank")
                let card = Account(name: "Rewards Card", type: .creditCard, currencyCode: "USD")
                let loan = Account(name: "Auto Loan", type: .loan, currencyCode: "USD")
                loan.loanTerms = LoanTerms(apr: Decimal(string: "0.08"), paymentAmount: 150, paymentDayOfMonth: nil)
                let importBatch = ImportBatch(
                    createdAt: date(2026, 5, 12),
                    label: "sample-bank-may.csv",
                    sourceFileName: "sample-bank-may.csv",
                    parserId: "bank.csv"
                )
                let incompleteBill = CashFlowItem(
                    kind: .bill,
                    name: "Insurance",
                    amount: 600,
                    frequency: .semiAnnual
                )

                context.insert(checking)
                context.insert(card)
                context.insert(loan)
                context.insert(importBatch)
                context.insert(incompleteBill)
                context.insert(BalanceSnapshot(asOfDate: date(2026, 5, 1), balance: -1_000, account: card))
                context.insert(BalanceSnapshot(asOfDate: date(2026, 5, 1), balance: 5_000, account: loan))
                context.insert(Transaction(
                    datePosted: date(2026, 5, 1),
                    amount: -25,
                    payee: "Coffee",
                    hashKey: "duplicate-key",
                    account: checking,
                    importBatch: importBatch,
                    importHashKey: "duplicate-key"
                ))
                context.insert(Transaction(
                    datePosted: date(2026, 5, 1),
                    amount: -25,
                    payee: "Coffee Duplicate",
                    hashKey: "duplicate-key",
                    account: checking,
                    importBatch: importBatch,
                    importHashKey: "duplicate-key"
                ))
                context.insert(BalanceSnapshot(
                    asOfDate: date(2026, 5, 12),
                    balance: 2_000,
                    importBatch: importBatch
                ))
                try context.save()

                let service = DebtScopeAssistantService(context: context, settings: settings)
                let summary = try service.cleanupRecommendationSummary()

                #expect(summary.recommendationCount == 5)
                #expect(summary.transactionLevelDetailAvailable == false)
                #expect(summary.includesTransactionLevelDetail == false)
                #expect(summary.sourceNote.contains("read-only"))
                #expect(summary.sourceNote.contains("confirmation"))
                #expect(summary.recommendations.map(\.kind) == [
                    .duplicateImports,
                    .missingAccountMappings,
                    .missingAPR,
                    .missingMinimumPayments,
                    .incompleteCashFlowSetup
                ])
                #expect(summary.recommendations.allSatisfy { !$0.destination.title.isEmpty })
                #expect(summary.recommendations.allSatisfy { $0.requiredUserConfirmation.contains("confirm") || $0.requiredUserConfirmation.contains("confirmation") })

                let duplicateRecommendation = try #require(summary.recommendations.first { $0.kind == .duplicateImports })
                #expect(duplicateRecommendation.affectedRecordCount == 2)
                #expect(duplicateRecommendation.destination == .importReview)
                #expect(duplicateRecommendation.requiredUserConfirmation.contains("During statement import review"))
                #expect(duplicateRecommendation.details.joined().contains("transaction lists") == true)

                let mappingRecommendation = try #require(summary.recommendations.first { $0.kind == .missingAccountMappings })
                #expect(mappingRecommendation.affectedRecordCount == 1)
                #expect(mappingRecommendation.destination == .importReview)
                #expect(mappingRecommendation.requiredUserConfirmation.contains("before accepting the import"))

                let missingAPRRecommendation = try #require(summary.recommendations.first { $0.kind == .missingAPR })
                #expect(missingAPRRecommendation.affectedRecordCount == 1)
                #expect(missingAPRRecommendation.requiredUserConfirmation.contains("APR from your statement"))
                #expect(missingAPRRecommendation.requiredUserConfirmation.contains("APR"))

                let missingMinimumRecommendation = try #require(summary.recommendations.first { $0.kind == .missingMinimumPayments })
                #expect(missingMinimumRecommendation.affectedRecordCount == 1)
                #expect(missingMinimumRecommendation.requiredUserConfirmation.contains("minimum payment from your statement"))
                #expect(missingMinimumRecommendation.requiredUserConfirmation.contains("Typical payment"))

                let cashFlowRecommendation = try #require(summary.recommendations.first { $0.kind == .incompleteCashFlowSetup })
                #expect(cashFlowRecommendation.destination == .incomeBills)
                #expect(cashFlowRecommendation.affectedRecordCount == 1)
            } catch {
                Issue.record(error)
            }
        }
    }

    @Test("Cleanup recommendations do not mutate user defaults or stored records")
    func cleanupRecommendationsDoNotMutateUserDefaultsOrStoredRecords() throws {
        let defaultsSnapshot = PayoffDefaultsSnapshot.capture()
        defer { defaultsSnapshot.restore() }

        let context = try makeInMemoryContext()
        let settings = makeSettings()
        UserDefaults.standard.set(true, forKey: "useFixedDebtBudget")
        UserDefaults.standard.set("fixed", forKey: "baselineBudgetSourceRaw")
        UserDefaults.standard.set(450.0, forKey: "debtBudgetOverrideAmount")

        let card = Account(name: "Rewards Card", type: .creditCard, currencyCode: "USD")
        context.insert(card)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 5, 1), balance: -1_000, account: card))
        try context.save()

        let transactionCountBefore = try context.fetch(FetchDescriptor<Transaction>()).count
        let balanceCountBefore = try context.fetch(FetchDescriptor<BalanceSnapshot>()).count
        let service = DebtScopeAssistantService(context: context, settings: settings)
        _ = try service.cleanupRecommendationSummary()

        #expect(UserDefaults.standard.bool(forKey: "useFixedDebtBudget") == true)
        #expect(UserDefaults.standard.string(forKey: "baselineBudgetSourceRaw") == "fixed")
        #expect(UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount") == 450.0)
        #expect(try context.fetch(FetchDescriptor<Transaction>()).count == transactionCountBefore)
        #expect(try context.fetch(FetchDescriptor<BalanceSnapshot>()).count == balanceCountBefore)
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
            Transaction.self,
            ImportBatch.self,
            HoldingSnapshot.self,
            Security.self,
            BalanceSnapshot.self,
            CashFlowItem.self,
            BillFundingAllocation.self,
            AccountImportMapping.self,
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

    private func insertTwoDebtFixture(in context: ModelContext) {
        let highAPRCard = Account(name: "High APR Card", type: .creditCard, currencyCode: "USD")
        highAPRCard.loanTerms = LoanTerms(apr: Decimal(string: "0.24"), paymentAmount: 100, paymentDayOfMonth: nil)
        let lowAPRLoan = Account(name: "Low APR Loan", type: .loan, currencyCode: "USD")
        lowAPRLoan.loanTerms = LoanTerms(apr: Decimal(string: "0.05"), paymentAmount: 75, paymentDayOfMonth: nil)

        context.insert(highAPRCard)
        context.insert(lowAPRLoan)
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -5_000, account: highAPRCard))
        context.insert(BalanceSnapshot(asOfDate: date(2026, 1, 1), balance: -1_000, account: lowAPRLoan))
        try? context.save()
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

    private struct PayoffDefaultsSnapshot {
        private static let keys = [
            "debtPlanStartModeRaw",
            "debtPlanStartDate",
            "useFixedDebtBudget",
            "debtBudgetOverrideAmount",
            "lastFixedDebtBudgetAmount",
            "debtPaymentReinvestmentRate",
            "debtDiscretionaryReserveAmount",
            "baselineBudgetSourceRaw",
            "includeNonMonthlyIncomeSpreads",
            "oneTimeIncomeDefaultSpreadMonths"
        ]

        private let values: [String: Any]
        private let missingKeys: Set<String>

        static func capture(defaults: UserDefaults = .standard) -> PayoffDefaultsSnapshot {
            var values: [String: Any] = [:]
            var missingKeys = Set<String>()

            for key in keys {
                if let value = defaults.object(forKey: key) {
                    values[key] = value
                } else {
                    missingKeys.insert(key)
                }
            }

            return PayoffDefaultsSnapshot(values: values, missingKeys: missingKeys)
        }

        func restore(defaults: UserDefaults = .standard) {
            for key in Self.keys {
                if missingKeys.contains(key) {
                    defaults.removeObject(forKey: key)
                } else if let value = values[key] {
                    defaults.set(value, forKey: key)
                }
            }
        }
    }
}
#endif
