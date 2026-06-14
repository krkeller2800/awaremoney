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

    func payoffStrategyComparison(startDate: Date, monthlyBudgetOverride: Decimal? = nil) throws -> AssistantPayoffStrategyComparisonSummary? {
        let provider = PayoffPlanProvider(context: context, settings: settings)
        let liabilities = try debtAccountInputs()
        let totalMinimumPayment = liabilities.reduce(0) { $0 + $1.minimumPayment }
        let sanitizedMonthlyBudgetOverride = monthlyBudgetOverride.map { max(0, $0.rounded(2)) }
        let monthlyBudget = sanitizedMonthlyBudgetOverride.flatMap { $0 > 0 ? $0 : nil }
            ?? planMonthlyBudget(startDate: startDate, totalMinimumPayment: totalMinimumPayment)
        let minimumsOnly = payoffStrategyComparisonResult(
            strategy: .minimumsOnly,
            startDate: startDate,
            monthlyBudgetOverride: sanitizedMonthlyBudgetOverride,
            provider: provider,
            liabilities: liabilities
        )
        let avalanche = payoffStrategyComparisonResult(
            strategy: .avalanche,
            startDate: startDate,
            monthlyBudgetOverride: sanitizedMonthlyBudgetOverride,
            provider: provider,
            liabilities: liabilities
        )
        let snowball = payoffStrategyComparisonResult(
            strategy: .snowball,
            startDate: startDate,
            monthlyBudgetOverride: sanitizedMonthlyBudgetOverride,
            provider: provider,
            liabilities: liabilities
        )
        let missingDataNotes = strategyComparisonMissingDataNotes(
            liabilities: liabilities,
            monthlyBudget: monthlyBudget,
            totalMinimumPayment: totalMinimumPayment,
            strategyErrors: [
                minimumsOnly.error,
                avalanche.error,
                snowball.error
            ]
        )

        return AssistantPayoffStrategyComparisonSummary(
            generatedAt: Date(),
            currencyCode: settings.currencyCode,
            startDate: normalizeToMonth(startDate),
            debtCount: liabilities.count,
            totalStartingDebt: liabilities.reduce(0) { $0 + $1.latestBalance },
            totalMinimumPayment: totalMinimumPayment,
            monthlyBudget: monthlyBudget,
            minimumPayments: minimumsOnly.summary,
            avalanche: avalanche.summary,
            snowball: snowball.summary,
            interestSavingsUsingAvalanche: avalanche.summary.paymentFeasible && snowball.summary.paymentFeasible
                ? (snowball.summary.totalInterest - avalanche.summary.totalInterest).rounded(2)
                : 0,
            avalancheDebtFreeDateAdvantageMonths: monthAdvantage(
                earlierDate: avalanche.summary.projectedDebtFreeDate,
                laterDate: snowball.summary.projectedDebtFreeDate
            ),
            missingDataNotes: missingDataNotes,
            sourceNote: monthlyBudgetOverride == nil
                ? "Based on DebtScope's PayoffPlanProvider results for minimum-payment, avalanche, and snowball strategies using the current budget settings."
                : "Based on DebtScope's PayoffPlanProvider results for minimum-payment, avalanche, and snowball strategies using a temporary monthly budget override."
        )
    }

    func payoffStrategyComparisonUnavailableDetails(startDate: Date, error: Error?) -> [String] {
        do {
            let liabilities = try debtAccountInputs()
            guard !liabilities.isEmpty else {
                return ["No active credit-card or loan debts with balances are available to compare."]
            }

            let totalMinimumPayment = liabilities.reduce(0) { $0 + $1.minimumPayment }
            let monthlyBudget = planMonthlyBudget(startDate: startDate, totalMinimumPayment: totalMinimumPayment)
            var details: [String] = []

            if let debtPlanError = error as? DebtPlanError,
               case let .infeasibleBudget(requiredMinimum) = debtPlanError {
                if let monthlyBudget {
                    details.append("Current monthly payoff budget is \(formatCurrency(monthlyBudget)), but minimum payments require at least \(formatCurrency(requiredMinimum)).")
                } else {
                    details.append("DebtScope needs at least \(formatCurrency(requiredMinimum)) per month for minimum payments before it can compare payoff strategies.")
                }
            } else if let monthlyBudget, monthlyBudget < totalMinimumPayment {
                details.append("Current monthly payoff budget is \(formatCurrency(monthlyBudget)), below total minimum payments of \(formatCurrency(totalMinimumPayment)).")
            } else if monthlyBudget == nil {
                details.append("DebtScope could not determine a monthly payoff budget from the current budget settings.")
            }

            let missingAPRCount = liabilities.filter { $0.apr == nil }.count
            if missingAPRCount > 0 {
                details.append("APR is missing for \(missingAPRCount) debt account(s), so avalanche ordering may not reflect true interest cost.")
            }

            let missingMinimumPaymentCount = liabilities.filter { $0.missingMinimumPayment }.count
            if missingMinimumPaymentCount > 0 {
                details.append("Minimum payment is missing for \(missingMinimumPaymentCount) debt account(s); DebtScope is using its fallback payment estimate.")
            }

            if details.isEmpty {
                details.append("DebtScope's payoff engine could not produce both avalanche and snowball plans with the current debt and budget settings.")
            }
            return details
        } catch {
            return ["DebtScope could not read the debt setup needed to compare payoff strategies."]
        }
    }

    func extraPaymentSimulation(
        extraMonthlyPayment: Decimal,
        startDate: Date,
        scenarioStrategy requestedScenarioStrategy: AssistantPayoffStrategy? = nil
    ) throws -> AssistantExtraPaymentSimulationSummary {
        let normalizedExtra = extraMonthlyPayment.rounded(2)
        let liabilities = try debtAccountInputs()
        let totalMinimumPayment = liabilities.reduce(0) { $0 + $1.minimumPayment }
        let startMonth = normalizeToMonth(startDate)
        let strategy = assistantPayoffStrategy()
        let scenarioStrategy = extraPaymentScenarioStrategy(
            baselineStrategy: strategy,
            extraMonthlyPayment: normalizedExtra,
            requestedScenarioStrategy: requestedScenarioStrategy
        )
        let configuredBaselineMonthlyBudget = planMonthlyBudget(startDate: startDate, totalMinimumPayment: totalMinimumPayment)
        let baselineMonthlyBudget = extraPaymentBaselineMonthlyBudget(
            for: strategy,
            configuredMonthlyBudget: configuredBaselineMonthlyBudget,
            totalMinimumPayment: totalMinimumPayment
        )

        if normalizedExtra < 0 {
            return invalidExtraPaymentSimulationSummary(
                extraMonthlyPayment: normalizedExtra,
                startDate: startMonth,
                debtCount: liabilities.count,
                strategy: strategy,
                scenarioStrategy: scenarioStrategy,
                baselineMonthlyBudget: baselineMonthlyBudget,
                message: "Extra monthly payment must be zero or greater."
            )
        }

        let maximumExtraPayment = Decimal(100_000)
        if normalizedExtra > maximumExtraPayment {
            return invalidExtraPaymentSimulationSummary(
                extraMonthlyPayment: normalizedExtra,
                startDate: startMonth,
                debtCount: liabilities.count,
                strategy: strategy,
                scenarioStrategy: scenarioStrategy,
                baselineMonthlyBudget: baselineMonthlyBudget,
                message: "Extra monthly payment is too large for this assistant simulation."
            )
        }

        guard !liabilities.isEmpty else {
            return AssistantExtraPaymentSimulationSummary(
                generatedAt: Date(),
                currencyCode: settings.currencyCode,
                startDate: startMonth,
                status: .unavailable,
                validationMessage: "No active credit-card or loan debts with current balances are available to simulate.",
                debtCount: 0,
                strategy: strategy,
                scenarioStrategy: scenarioStrategy,
                extraMonthlyPayment: normalizedExtra,
                baselineMonthlyBudget: baselineMonthlyBudget,
                scenarioMonthlyBudget: nil,
                baseline: nil,
                scenario: nil,
                interestSaved: nil,
                debtFreeDateAdvantageMonths: nil,
                firstAffectedAccountName: nil,
                missingDataNotes: ["No active credit-card or loan debts with current balances are available to simulate."],
                sourceNote: "No payoff calculations were run because DebtScope has no active debt inputs for this simulation."
            )
        }

        if needsExtraPaymentStrategyChoice(
            baselineStrategy: strategy,
            extraMonthlyPayment: normalizedExtra,
            requestedScenarioStrategy: requestedScenarioStrategy
        ) {
            return unavailableExtraPaymentSimulationSummary(
                extraMonthlyPayment: normalizedExtra,
                startDate: startMonth,
                debtCount: liabilities.count,
                strategy: strategy,
                scenarioStrategy: scenarioStrategy,
                baselineMonthlyBudget: baselineMonthlyBudget,
                scenarioMonthlyBudget: nil,
                validationMessage: "Choose which strategy to use (minimums, avalanche, or snowball) when applying the extra payment.",
                notes: []
            )
        }

        let provider = PayoffPlanProvider(context: context, settings: settings)
        let scenarioMonthlyBudget = baselineMonthlyBudget.map { ($0 + normalizedExtra).rounded(2) }

        do {
            guard
                let baselineBudget = baselineMonthlyBudget,
                let baselinePlan = try provider.computePlan(
                    startDate: startDate,
                    strategyOverride: payoffStrategy(for: strategy),
                    monthlyBudgetOverride: baselineBudget
                ),
                let scenarioBudget = scenarioMonthlyBudget,
                let scenarioPlan = try extraPaymentScenarioPlan(
                    strategy: scenarioStrategy,
                    liabilities: liabilities,
                    provider: provider,
                    startDate: startDate,
                    monthlyBudget: scenarioBudget,
                    extraMonthlyPayment: normalizedExtra,
                    totalMinimumPayment: totalMinimumPayment
                )
            else {
                return unavailableExtraPaymentSimulationSummary(
                    extraMonthlyPayment: normalizedExtra,
                    startDate: startMonth,
                    debtCount: liabilities.count,
                    strategy: strategy,
                    scenarioStrategy: scenarioStrategy,
                    baselineMonthlyBudget: baselineMonthlyBudget,
                    scenarioMonthlyBudget: scenarioMonthlyBudget,
                    notes: ["DebtScope could not compute both baseline and extra-payment payoff plans with the current debt and budget settings."]
                )
            }

            let baselineSummary = payoffSimulationPlanSummary(plan: baselinePlan, liabilities: liabilities)
            let scenarioSummary = payoffSimulationPlanSummary(plan: scenarioPlan, liabilities: liabilities)
            let interestSaved = (baselinePlan.totalInterest - scenarioPlan.totalInterest).rounded(2)

            return AssistantExtraPaymentSimulationSummary(
                generatedAt: Date(),
                currencyCode: settings.currencyCode,
                startDate: startMonth,
                status: .valid,
                validationMessage: nil,
                debtCount: liabilities.count,
                strategy: strategy,
                scenarioStrategy: scenarioStrategy,
                extraMonthlyPayment: normalizedExtra,
                baselineMonthlyBudget: baselineMonthlyBudget,
                scenarioMonthlyBudget: scenarioMonthlyBudget,
                baseline: baselineSummary,
                scenario: scenarioSummary,
                interestSaved: interestSaved,
                debtFreeDateAdvantageMonths: monthAdvantage(
                    earlierDate: scenarioSummary.projectedDebtFreeDate,
                    laterDate: baselineSummary.projectedDebtFreeDate
                ),
                firstAffectedAccountName: scenarioStrategy == .minimumsOnly
                    ? nil
                    : firstAffectedAccountName(
                        baselinePlan: baselinePlan,
                        scenarioPlan: scenarioPlan,
                        liabilities: liabilities
                    ),
                missingDataNotes: strategyComparisonMissingDataNotes(
                    liabilities: liabilities,
                    monthlyBudget: baselineMonthlyBudget,
                    totalMinimumPayment: totalMinimumPayment,
                    strategyErrors: []
                ),
                sourceNote: "Based on DebtScope's PayoffPlanProvider results using a temporary extra-payment scenario. No payoff settings are saved."
            )
        } catch {
            return unavailableExtraPaymentSimulationSummary(
                extraMonthlyPayment: normalizedExtra,
                startDate: startMonth,
                debtCount: liabilities.count,
                strategy: strategy,
                scenarioStrategy: scenarioStrategy,
                baselineMonthlyBudget: baselineMonthlyBudget,
                scenarioMonthlyBudget: scenarioMonthlyBudget,
                notes: payoffStrategyComparisonUnavailableDetails(startDate: startDate, error: error)
            )
        }
    }

    func cashFlowSummary(months requestedMonths: Int) throws -> AssistantCashFlowSummary {
        let months = clamp(requestedMonths, to: 1...24)
        let items = try cashFlowItems()
        let incomeItems = items.filter { $0.kind == .income }
        let billItems = items.filter { $0.kind == .bill }
        let allocations = try incomeFundingAllocationTotals()
        let startMonth = normalizeToMonth(Date())
        let defaultSpread = sanitizedDefaultSpread(UserDefaults.standard.integer(forKey: "oneTimeIncomeDefaultSpreadMonths"))
        let incomeSpreads = IncomeScheduler.spreadsByMonth(
            incomes: items,
            start: startMonth,
            months: months,
            oneTimeDefaultSpreadMonths: defaultSpread,
            incomeFundingAllocations: allocations
        )
        let nonMonthlyIncomeMonthlyAverage = incomeSpreads.values.reduce(0, +) / Decimal(months)
        let reserveAdjustedAvailableForDebt = PlanBudgetDisplay.availableBudget(
            for: startMonth,
            modelContext: context,
            baselineBudgetSourceRaw: UserDefaults.standard.string(forKey: "baselineBudgetSourceRaw") ?? "recurringNet",
            useFixedDebtBudget: UserDefaults.standard.bool(forKey: "useFixedDebtBudget"),
            debtBudgetOverrideAmount: UserDefaults.standard.double(forKey: "debtBudgetOverrideAmount"),
            includeNonMonthlyIncomeSpreads: UserDefaults.standard.bool(forKey: "includeNonMonthlyIncomeSpreads"),
            oneTimeIncomeDefaultSpreadMonths: defaultSpread,
            discretionaryReserveAmount: UserDefaults.standard.double(forKey: "debtDiscretionaryReserveAmount")
        )

        return AssistantCashFlowSummary(
            generatedAt: Date(),
            currencyCode: settings.currencyCode,
            monthsCovered: months,
            incomeItemCount: incomeItems.count,
            billItemCount: billItems.count,
            monthlyIncome: recurringMonthlyIncome(from: incomeItems),
            monthlyBills: recurringMonthlyBills(from: billItems),
            recurringNet: recurringMonthlyIncome(from: incomeItems) - recurringMonthlyBills(from: billItems),
            nonMonthlyIncomeMonthlyAverage: nonMonthlyIncomeMonthlyAverage.rounded(2),
            reserveAdjustedAvailableForDebt: reserveAdjustedAvailableForDebt,
            upcomingBills: try upcomingBills(days: min(90, max(30, months * 31))).prefix(12).map { $0 },
            missingDataNotes: cashFlowMissingDataNotes(items: items, reserveAdjustedAvailableForDebt: reserveAdjustedAvailableForDebt)
        )
    }

    func upcomingBills(days requestedDays: Int) throws -> [AssistantUpcomingBillSummary] {
        let days = clamp(requestedDays, to: 1...90)
        let now = Date()
        let calendar = Calendar.current
        let endDate = calendar.date(byAdding: .day, value: days, to: now) ?? now
        let items = try cashFlowItems()
        let incomeNamesByID = Dictionary(uniqueKeysWithValues: items.filter { $0.kind == .income }.map { ($0.id, $0.name) })
        let allocationSourceNames = try allocationSourceNames(incomeNamesByID: incomeNamesByID)

        return items
            .filter { $0.kind == .bill }
            .compactMap { item -> (summary: AssistantUpcomingBillSummary, dueDate: Date)? in
                guard let due = nextDueDate(for: item, after: now), due <= endDate else { return nil }
                return (
                    AssistantUpcomingBillSummary(
                        name: item.name,
                        amount: item.amount,
                        dueDate: due,
                        frequency: assistantPaymentFrequency(for: item.frequency),
                        accountName: item.account?.name,
                        reserveBalance: item.frequency.isReserveEligible ? item.reserveBalance : nil,
                        fundingSourceName: fundingSourceName(for: item, incomeNamesByID: incomeNamesByID, allocationSourceNames: allocationSourceNames)
                    ),
                    due
                )
            }
            .sorted { lhs, rhs in
                if lhs.dueDate != rhs.dueDate { return lhs.dueDate < rhs.dueDate }
                return lhs.summary.name.localizedCaseInsensitiveCompare(rhs.summary.name) == .orderedAscending
            }
            .prefix(30)
            .map(\.summary)
    }

    func importReviewSummary(recentLimit requestedLimit: Int = 5) throws -> AssistantImportReviewSummary {
        let recentLimit = clamp(requestedLimit, to: 1...10)
        var batchDescriptor = FetchDescriptor<ImportBatch>()
        batchDescriptor.sortBy = [SortDescriptor(\ImportBatch.createdAt, order: .reverse)]
        let batches = try context.fetch(batchDescriptor)

        let transactions = try context.fetch(FetchDescriptor<Transaction>())
            .filter { $0.importBatch != nil }
        let balances = try context.fetch(FetchDescriptor<BalanceSnapshot>())
            .filter { $0.importBatch != nil }
        let holdings = try context.fetch(FetchDescriptor<HoldingSnapshot>())
            .filter { $0.importBatch != nil }

        let batchSummaries = batches.prefix(recentLimit).map { batch in
            importBatchReviewSummary(
                for: batch,
                transactions: transactions,
                balances: balances,
                holdings: holdings
            )
        }
        let duplicateCandidateCount = duplicateImportedTransactionCandidateCount(transactions)
        let conflictCount = transactions.filter { $0.isUserEdited || $0.isUserModified || $0.isExcluded }.count
            + balances.filter { $0.isUserModified || $0.isExcluded }.count
            + holdings.filter { $0.isUserModified || $0.isExcluded }.count
        let unresolvedMappingCount = unresolvedAccountMappingCount(
            transactions: transactions,
            balances: balances,
            holdings: holdings
        )
        let mappedAccountIDs = Set(
            transactions.compactMap(\.accountID)
                + balances.compactMap(\.accountID)
                + holdings.compactMap { $0.account?.id }
        )

        return AssistantImportReviewSummary(
            generatedAt: Date(),
            importCount: batches.count,
            latestImport: batchSummaries.first,
            recentImports: batchSummaries,
            totalImportedBalanceCount: balances.count,
            totalImportedTransactionCount: transactions.count,
            totalImportedHoldingCount: holdings.count,
            duplicateTransactionCandidateCount: duplicateCandidateCount,
            conflictCount: conflictCount,
            unresolvedAccountMappingCount: unresolvedMappingCount,
            mappedAccountCount: mappedAccountIDs.count,
            transactionLevelDetailAvailable: settings.assistantIncludeTransactions,
            includesTransactionLevelDetail: false,
            reviewNotes: importReviewNotes(
                importCount: batches.count,
                duplicateTransactionCandidateCount: duplicateCandidateCount,
                conflictCount: conflictCount,
                unresolvedAccountMappingCount: unresolvedMappingCount
            ),
            sourceNote: "Based on persisted DebtScope import batches and count-level review signals. Raw file contents, hashes, full memos, and persistent identifiers are excluded."
        )
    }

    func cleanupRecommendationSummary() throws -> AssistantCleanupRecommendationSummary {
        let liabilities = try debtAccountInputs()
        let importReview = try importReviewSummary()
        let cashFlowItems = try cashFlowItems()
        var recommendations: [AssistantCleanupRecommendation] = []

        if importReview.duplicateTransactionCandidateCount > 0 {
            recommendations.append(AssistantCleanupRecommendation(
                kind: .duplicateImports,
                title: "Review duplicate import candidates",
                destination: "Import review during statement import",
                expectedBenefit: "Helps prevent imported activity from being counted twice in account and cash-flow summaries.",
                requiredUserConfirmation: "During statement import review, confirm which duplicate candidates should be kept, excluded, or left unchanged before accepting the import.",
                affectedRecordCount: importReview.duplicateTransactionCandidateCount,
                details: ["Duplicate recommendation is based on count-level import keys only; transaction lists and full memos are not included."]
            ))
        }

        if importReview.unresolvedAccountMappingCount > 0 {
            recommendations.append(AssistantCleanupRecommendation(
                kind: .missingAccountMappings,
                title: "Map imported records to accounts",
                destination: "Account mapping during statement import",
                expectedBenefit: "Improves account balances, import review clarity, and future duplicate detection.",
                requiredUserConfirmation: "During statement import review, choose and confirm the correct DebtScope account for unresolved imported records before accepting the import.",
                affectedRecordCount: importReview.unresolvedAccountMappingCount,
                details: ["Mapping recommendation is based on imported records that are not linked to an account."]
            ))
        }

        let missingAPRCount = liabilities.filter { $0.apr == nil }.count
        if missingAPRCount > 0 {
            recommendations.append(AssistantCleanupRecommendation(
                kind: .missingAPR,
                title: "Add missing APRs",
                destination: "Liability Accounts",
                expectedBenefit: "Makes avalanche ordering and projected interest totals more accurate.",
                requiredUserConfirmation: "Open Liability Accounts, choose the liability account, enter the APR from your statement in the APR field, and confirm the value before leaving the field.",
                affectedRecordCount: missingAPRCount,
                details: ["APR is missing for \(missingAPRCount) active debt account(s)."]
            ))
        }

        let missingMinimumPaymentCount = liabilities.filter(\.missingMinimumPayment).count
        if missingMinimumPaymentCount > 0 {
            recommendations.append(AssistantCleanupRecommendation(
                kind: .missingMinimumPayments,
                title: "Add missing minimum payments",
                destination: "Liability Accounts",
                expectedBenefit: "Reduces reliance on fallback minimum-payment estimates in payoff planning.",
                requiredUserConfirmation: "Open Liability Accounts, choose the liability account, enter the minimum payment from your statement in the Typical payment field, and confirm the value before leaving the field.",
                affectedRecordCount: missingMinimumPaymentCount,
                details: ["DebtScope is currently using fallback minimum-payment estimates for these debt account(s)."]
            ))
        }

        let incompleteCashFlowCount = cashFlowItems.filter { item in
            item.firstPaymentDate == nil && item.dayOfMonth == nil
        }.count
        if incompleteCashFlowCount > 0 {
            recommendations.append(AssistantCleanupRecommendation(
                kind: .incompleteCashFlowSetup,
                title: "Complete bill and income schedules",
                destination: "Income & Bills",
                expectedBenefit: "Improves upcoming bill timing, monthly cash-flow summaries, and reserve planning.",
                requiredUserConfirmation: "Open Income & Bills and confirm due dates or payment days for the incomplete items.",
                affectedRecordCount: incompleteCashFlowCount,
                details: ["Schedule details are missing for \(incompleteCashFlowCount) bill or income item(s)."]
            ))
        }

        return AssistantCleanupRecommendationSummary(
            generatedAt: Date(),
            recommendationCount: recommendations.count,
            recommendations: recommendations,
            transactionLevelDetailAvailable: settings.assistantIncludeTransactions,
            includesTransactionLevelDetail: false,
            sourceNote: "Based on current DebtScope setup and count-level review signals. Recommendations are read-only and require normal app confirmation before any data changes."
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

    private func payoffStrategyResult(
        strategy: AssistantPayoffStrategy,
        plan: DebtPlanResult,
        liabilities: [DebtAccountInput]
    ) -> AssistantPayoffStrategyResultSummary {
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

        return AssistantPayoffStrategyResultSummary(
            strategy: strategy,
            totalInterest: plan.totalInterest,
            projectedDebtFreeDate: projectedDebtFreeDate,
            paymentFeasible: true,
            payoffOrder: payoffOrder
        )
    }

    private func payoffStrategyComparisonResult(
        strategy: AssistantPayoffStrategy,
        startDate: Date,
        monthlyBudgetOverride: Decimal?,
        provider: PayoffPlanProvider,
        liabilities: [DebtAccountInput]
    ) -> (summary: AssistantPayoffStrategyResultSummary, error: Error?) {
        let strategyOverride: PayoffStrategy = {
            switch strategy {
            case .minimumsOnly:
                return .minimumsOnly
            case .snowball:
                return .snowball
            case .avalanche:
                return .avalanche
            }
        }()

        do {
            guard let plan = try provider.computePlan(
                startDate: startDate,
                strategyOverride: strategyOverride,
                monthlyBudgetOverride: monthlyBudgetOverride
            ) else {
                return (emptyPayoffStrategyResult(strategy: strategy), nil)
            }

            return (payoffStrategyResult(strategy: strategy, plan: plan, liabilities: liabilities), nil)
        } catch {
            return (emptyPayoffStrategyResult(strategy: strategy), error)
        }
    }

    private func emptyPayoffStrategyResult(strategy: AssistantPayoffStrategy) -> AssistantPayoffStrategyResultSummary {
        AssistantPayoffStrategyResultSummary(
            strategy: strategy,
            totalInterest: 0,
            projectedDebtFreeDate: nil,
            paymentFeasible: false,
            payoffOrder: []
        )
    }

    private func invalidExtraPaymentSimulationSummary(
        extraMonthlyPayment: Decimal,
        startDate: Date,
        debtCount: Int,
        strategy: AssistantPayoffStrategy,
        scenarioStrategy: AssistantPayoffStrategy,
        baselineMonthlyBudget: Decimal?,
        message: String
    ) -> AssistantExtraPaymentSimulationSummary {
        AssistantExtraPaymentSimulationSummary(
            generatedAt: Date(),
            currencyCode: settings.currencyCode,
            startDate: startDate,
            status: .invalidAmount,
            validationMessage: message,
            debtCount: debtCount,
            strategy: strategy,
            scenarioStrategy: scenarioStrategy,
            extraMonthlyPayment: extraMonthlyPayment,
            baselineMonthlyBudget: baselineMonthlyBudget,
            scenarioMonthlyBudget: nil,
            baseline: nil,
            scenario: nil,
            interestSaved: nil,
            debtFreeDateAdvantageMonths: nil,
            firstAffectedAccountName: nil,
            missingDataNotes: [],
            sourceNote: "No payoff calculations were run because the requested extra payment was invalid."
        )
    }

    private func unavailableExtraPaymentSimulationSummary(
        extraMonthlyPayment: Decimal,
        startDate: Date,
        debtCount: Int,
        strategy: AssistantPayoffStrategy,
        scenarioStrategy: AssistantPayoffStrategy,
        baselineMonthlyBudget: Decimal?,
        scenarioMonthlyBudget: Decimal?,
        validationMessage: String = "DebtScope could not compute this extra-payment simulation with the current setup.",
        notes: [String]
    ) -> AssistantExtraPaymentSimulationSummary {
        AssistantExtraPaymentSimulationSummary(
            generatedAt: Date(),
            currencyCode: settings.currencyCode,
            startDate: startDate,
            status: .unavailable,
            validationMessage: validationMessage,
            debtCount: debtCount,
            strategy: strategy,
            scenarioStrategy: scenarioStrategy,
            extraMonthlyPayment: extraMonthlyPayment,
            baselineMonthlyBudget: baselineMonthlyBudget,
            scenarioMonthlyBudget: scenarioMonthlyBudget,
            baseline: nil,
            scenario: nil,
            interestSaved: nil,
            debtFreeDateAdvantageMonths: nil,
            firstAffectedAccountName: nil,
            missingDataNotes: notes,
            sourceNote: "DebtScope could not compute both baseline and scenario payoff plans."
        )
    }

    private func extraPaymentBaselineMonthlyBudget(
        for strategy: AssistantPayoffStrategy,
        configuredMonthlyBudget: Decimal?,
        totalMinimumPayment: Decimal
    ) -> Decimal? {
        if strategy == .minimumsOnly {
            return totalMinimumPayment.rounded(2)
        }

        return configuredMonthlyBudget
    }

    private func extraPaymentScenarioStrategy(
        baselineStrategy: AssistantPayoffStrategy,
        extraMonthlyPayment: Decimal,
        requestedScenarioStrategy: AssistantPayoffStrategy?
    ) -> AssistantPayoffStrategy {
        if let requestedScenarioStrategy {
            return requestedScenarioStrategy
        }

        return baselineStrategy
    }

    private func needsExtraPaymentStrategyChoice(
        baselineStrategy: AssistantPayoffStrategy,
        extraMonthlyPayment: Decimal,
        requestedScenarioStrategy: AssistantPayoffStrategy?
    ) -> Bool {
        extraMonthlyPayment > 0
            && requestedScenarioStrategy == nil
    }

    private func payoffStrategy(for strategy: AssistantPayoffStrategy) -> PayoffStrategy {
        switch strategy {
        case .minimumsOnly:
            return .minimumsOnly
        case .snowball:
            return .snowball
        case .avalanche:
            return .avalanche
        }
    }

    private func extraPaymentScenarioPlan(
        strategy: AssistantPayoffStrategy,
        liabilities: [DebtAccountInput],
        provider: PayoffPlanProvider,
        startDate: Date,
        monthlyBudget: Decimal,
        extraMonthlyPayment: Decimal,
        totalMinimumPayment: Decimal
    ) throws -> DebtPlanResult? {
        guard strategy == .minimumsOnly, extraMonthlyPayment > 0 else {
            return try provider.computePlan(
                startDate: startDate,
                strategyOverride: payoffStrategy(for: strategy),
                monthlyBudgetOverride: monthlyBudget
            )
        }

        let debts = minimumsPlusExtraDebtInputs(
            liabilities: liabilities,
            extraMonthlyPayment: extraMonthlyPayment,
            totalMinimumPayment: totalMinimumPayment
        )

        return try DebtPayoffEngine.plan(
            debts: debts,
            monthlyBudget: monthlyBudget,
            strategy: .minimumsOnly,
            reinvestmentRate: assistantDebtPaymentReinvestmentRate(),
            startDate: normalizeToMonth(startDate)
        )
    }

    private func minimumsPlusExtraDebtInputs(
        liabilities: [DebtAccountInput],
        extraMonthlyPayment: Decimal,
        totalMinimumPayment: Decimal
    ) -> [DebtInput] {
        let sortedLiabilities = liabilities.sorted {
            $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending
        }
        var allocatedExtra: Decimal = 0

        return sortedLiabilities.enumerated().map { offset, input in
            let extraShare: Decimal
            if offset == sortedLiabilities.count - 1 {
                extraShare = (extraMonthlyPayment - allocatedExtra).rounded(2)
            } else if totalMinimumPayment > 0 {
                extraShare = ((input.minimumPayment / totalMinimumPayment) * extraMonthlyPayment).rounded(2)
                allocatedExtra += extraShare
            } else {
                extraShare = 0
            }

            return DebtInput(
                id: input.account.id,
                name: input.account.name,
                apr: input.apr,
                balance: input.latestBalance,
                minPayment: (input.minimumPayment + extraShare).rounded(2)
            )
        }
    }

    private func assistantDebtPaymentReinvestmentRate() -> Decimal {
        Decimal(UserDefaults.standard.object(forKey: "debtPaymentReinvestmentRate") as? Double ?? 1)
    }

    private func payoffSimulationPlanSummary(
        plan: DebtPlanResult,
        liabilities: [DebtAccountInput]
    ) -> AssistantPayoffSimulationPlanSummary {
        let projectedDebtFreeDate = liabilities.allSatisfy { plan.payoffDates[$0.account.id] != nil }
            ? plan.payoffDates.values.max()
            : nil

        return AssistantPayoffSimulationPlanSummary(
            totalInterest: plan.totalInterest,
            projectedDebtFreeDate: projectedDebtFreeDate,
            paymentFeasible: true
        )
    }

    private func firstAffectedAccountName(
        baselinePlan: DebtPlanResult,
        scenarioPlan: DebtPlanResult,
        liabilities: [DebtAccountInput]
    ) -> String? {
        if let improved = liabilities.compactMap({ input -> (name: String, date: Date)? in
            guard
                let baselineDate = baselinePlan.payoffDates[input.account.id],
                let scenarioDate = scenarioPlan.payoffDates[input.account.id],
                scenarioDate < baselineDate
            else {
                return nil
            }
            return (input.account.name, scenarioDate)
        })
        .sorted(by: { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        })
        .first {
            return improved.name
        }

        return nil
    }

    private func monthAdvantage(earlierDate: Date?, laterDate: Date?) -> Int? {
        guard let earlierDate, let laterDate else { return nil }
        let calendar = Calendar.current
        let earlierMonth = normalizeToMonth(earlierDate)
        let laterMonth = normalizeToMonth(laterDate)
        return calendar.dateComponents([.month], from: earlierMonth, to: laterMonth).month
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

        return totalMinimumPayment
    }

    private func cashFlowItems() throws -> [CashFlowItem] {
        var descriptor = FetchDescriptor<CashFlowItem>()
        descriptor.sortBy = [SortDescriptor(\CashFlowItem.name)]
        return try context.fetch(descriptor)
    }

    private func nextDueDate(for item: CashFlowItem, after date: Date) -> Date? {
        let calendar = Calendar.current
        let anchor = item.firstPaymentDate ?? item.createdAt

        switch item.frequency.normalized {
        case .weekly:
            return nextDate(from: anchor, after: date, adding: .day, value: 7)
        case .biweekly:
            return nextDate(from: anchor, after: date, adding: .day, value: 14)
        case .semimonthly:
            return nextSemimonthlyDate(for: item, after: date)
        case .socialSecurity:
            let birthdayDay = item.ssaWednesday ?? item.dayOfMonth ?? 1
            return SocialSecuritySchedule.nextPaymentDate(after: date, birthdayDay: birthdayDay)
        case .monthly:
            return nextMonthlyDate(for: item, after: date)
        case .quarterly, .semiAnnual, .yearly:
            return BillReservePlanner.nextDue(for: item, asOf: date).nextDueDate
        case .oneTime:
            guard anchor > date else { return nil }
            return calendar.startOfDay(for: anchor)
        case .biWeekly, .twiceMonthly, .annual:
            return nextDueDate(for: item, after: date)
        }
    }

    private func nextDate(from anchor: Date, after date: Date, adding component: Calendar.Component, value: Int) -> Date? {
        let calendar = Calendar.current
        var next = calendar.startOfDay(for: anchor)
        let threshold = calendar.startOfDay(for: date)
        while next <= threshold {
            guard let advanced = calendar.date(byAdding: component, value: value, to: next) else { return nil }
            next = calendar.startOfDay(for: advanced)
        }
        return next
    }

    private func nextMonthlyDate(for item: CashFlowItem, after date: Date) -> Date? {
        let calendar = Calendar.current
        let day = item.dayOfMonth ?? calendar.component(.day, from: item.firstPaymentDate ?? item.createdAt)
        var components = calendar.dateComponents([.year, .month], from: date)

        for offset in 0...24 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: normalizeToMonth(date)) else { continue }
            components = calendar.dateComponents([.year, .month], from: month)
            components.day = clampedDay(day, inMonthContaining: month)
            if let candidate = calendar.date(from: components), candidate > date {
                return calendar.startOfDay(for: candidate)
            }
        }
        return nil
    }

    private func nextSemimonthlyDate(for item: CashFlowItem, after date: Date) -> Date? {
        let calendar = Calendar.current
        let firstDay = item.dayOfMonth ?? calendar.component(.day, from: item.firstPaymentDate ?? item.createdAt)
        let secondDay = min(firstDay + 15, 31)
        let monthStart = normalizeToMonth(date)

        for offset in 0...24 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: monthStart) else { continue }
            for day in [firstDay, secondDay] {
                var components = calendar.dateComponents([.year, .month], from: month)
                components.day = clampedDay(day, inMonthContaining: month)
                if let candidate = calendar.date(from: components), candidate > date {
                    return calendar.startOfDay(for: candidate)
                }
            }
        }
        return nil
    }

    private func clampedDay(_ day: Int, inMonthContaining date: Date) -> Int {
        let range = Calendar.current.range(of: .day, in: .month, for: date) ?? 1..<29
        return min(max(day, range.lowerBound), range.upperBound - 1)
    }

    private func recurringMonthlyIncome(from items: [CashFlowItem]) -> Decimal {
        items
            .filter { item in
                switch item.frequency {
                case .monthly, .semimonthly, .twiceMonthly, .biweekly, .biWeekly, .weekly, .socialSecurity:
                    return true
                default:
                    return false
                }
            }
            .reduce(0) { $0 + ($1.amount * $1.frequency.monthlyEquivalentFactor) }
            .rounded(2)
    }

    private func recurringMonthlyBills(from items: [CashFlowItem]) -> Decimal {
        items
            .filter { $0.frequency == .monthly }
            .reduce(0) { $0 + ($1.amount * $1.frequency.monthlyEquivalentFactor) }
            .rounded(2)
    }

    private func incomeFundingAllocationTotals() throws -> [UUID: Decimal] {
        let allocations = try context.fetch(FetchDescriptor<BillFundingAllocation>())
        return IncomeScheduler.incomeFundingAllocationTotals(from: allocations)
    }

    private func allocationSourceNames(incomeNamesByID: [UUID: String]) throws -> [UUID: String] {
        let allocations = try context.fetch(FetchDescriptor<BillFundingAllocation>())
        let sortedAllocations = allocations.sorted { lhs, rhs in
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            return lhs.createdAt < rhs.createdAt
        }

        return sortedAllocations.reduce(into: [UUID: String]()) { result, allocation in
            guard result[allocation.billID] == nil, let incomeName = incomeNamesByID[allocation.incomeID] else { return }
            result[allocation.billID] = incomeName
        }
    }

    private func fundingSourceName(
        for item: CashFlowItem,
        incomeNamesByID: [UUID: String],
        allocationSourceNames: [UUID: String]
    ) -> String? {
        if let incomeID = item.fundingIncomeID, let incomeName = incomeNamesByID[incomeID] {
            return incomeName
        }
        return allocationSourceNames[item.id]
    }

    private func importBatchReviewSummary(
        for batch: ImportBatch,
        transactions: [Transaction],
        balances: [BalanceSnapshot],
        holdings: [HoldingSnapshot]
    ) -> AssistantImportBatchReviewSummary {
        let batchID = batch.id
        let batchTransactions = transactions.filter { $0.importBatch?.id == batchID }
        let batchBalances = balances.filter { $0.importBatch?.id == batchID }
        let batchHoldings = holdings.filter { $0.importBatch?.id == batchID }
        let institutionNames = (
            batchTransactions.compactMap { $0.account?.institutionName }
                + batchBalances.compactMap { $0.account?.institutionName }
                + batchHoldings.compactMap { $0.account?.institutionName }
        )
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        let detectedInstitutionName = Dictionary(grouping: institutionNames, by: { $0 })
            .max { lhs, rhs in
                if lhs.value.count == rhs.value.count {
                    return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedDescending
                }
                return lhs.value.count < rhs.value.count
            }?.key

        return AssistantImportBatchReviewSummary(
            importedAt: batch.createdAt,
            label: sanitizedImportLabel(batch.label, sourceFileName: batch.sourceFileName),
            parserName: batch.parserId,
            detectedInstitutionName: detectedInstitutionName,
            importedBalanceCount: batchBalances.count,
            importedTransactionCount: batchTransactions.count,
            importedHoldingCount: batchHoldings.count,
            excludedRecordCount: batchTransactions.filter(\.isExcluded).count
                + batchBalances.filter(\.isExcluded).count
                + batchHoldings.filter(\.isExcluded).count,
            editedRecordCount: batchTransactions.filter { $0.isUserEdited || $0.isUserModified }.count
                + batchBalances.filter(\.isUserModified).count
                + batchHoldings.filter(\.isUserModified).count,
            unresolvedAccountMappingCount: unresolvedAccountMappingCount(
                transactions: batchTransactions,
                balances: batchBalances,
                holdings: batchHoldings
            )
        )
    }

    private func duplicateImportedTransactionCandidateCount(_ transactions: [Transaction]) -> Int {
        let keys = transactions.compactMap { transaction -> String? in
            let key = (transaction.importHashKey ?? transaction.hashKey)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        let counts = Dictionary(grouping: keys, by: { $0 }).mapValues(\.count)
        return keys.filter { (counts[$0] ?? 0) > 1 }.count
    }

    private func unresolvedAccountMappingCount(
        transactions: [Transaction],
        balances: [BalanceSnapshot],
        holdings: [HoldingSnapshot]
    ) -> Int {
        transactions.filter { $0.account == nil && $0.accountID == nil }.count
            + balances.filter { $0.account == nil && $0.accountID == nil }.count
            + holdings.filter { $0.account == nil }.count
    }

    private func importReviewNotes(
        importCount: Int,
        duplicateTransactionCandidateCount: Int,
        conflictCount: Int,
        unresolvedAccountMappingCount: Int
    ) -> [String] {
        var notes: [String] = []
        if importCount == 0 {
            notes.append("No completed imports are available to review.")
        }
        if duplicateTransactionCandidateCount > 0 {
            notes.append("\(duplicateTransactionCandidateCount) imported transaction record(s) share duplicate import keys and may need duplicate review.")
        }
        if conflictCount > 0 {
            notes.append("\(conflictCount) imported record(s) are excluded or have user edits, so review screens may show conflicts or adjustments.")
        }
        if unresolvedAccountMappingCount > 0 {
            notes.append("\(unresolvedAccountMappingCount) imported record(s) are not linked to an account and may need account mapping review.")
        }
        if notes.isEmpty {
            notes.append("Recent imports do not show duplicate, conflict, or unresolved mapping counts.")
        }
        return notes
    }

    private func sanitizedImportLabel(_ label: String, sourceFileName: String) -> String {
        let candidate = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? sourceFileName
            : label
        let baseName = (candidate as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return baseName.isEmpty ? "Import" : baseName
    }

    private func formatCurrency(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settings.currencyCode
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value) \(settings.currencyCode)"
    }

    private func cashFlowMissingDataNotes(items: [CashFlowItem], reserveAdjustedAvailableForDebt: Decimal?) -> [String] {
        var notes: [String] = []
        let incomeCount = items.filter { $0.kind == .income }.count
        let billCount = items.filter { $0.kind == .bill }.count
        let missingScheduleCount = items.filter { $0.firstPaymentDate == nil && $0.dayOfMonth == nil }.count

        if incomeCount == 0 {
            notes.append("No income items are configured yet.")
        }
        if billCount == 0 {
            notes.append("No bill items are configured yet.")
        }
        if missingScheduleCount > 0 {
            notes.append("Schedule details are missing for \(missingScheduleCount) cash-flow item(s); DebtScope used the item creation date or current month fallback.")
        }
        if reserveAdjustedAvailableForDebt == nil {
            notes.append("Reserve-adjusted debt budget is unavailable with the current payoff budget settings.")
        }
        return notes
    }

    private func sanitizedDefaultSpread(_ value: Int) -> Int {
        [3, 6, 12].contains(value) ? value : 12
    }

    private func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
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

    private func strategyComparisonMissingDataNotes(
        liabilities: [DebtAccountInput],
        monthlyBudget: Decimal?,
        totalMinimumPayment: Decimal,
        strategyErrors: [Error?]
    ) -> [String] {
        var notes: [String] = []

        if liabilities.isEmpty {
            notes.append("No active credit-card or loan debts with current balances are available to compare.")
        }

        let missingAPRCount = liabilities.filter { $0.apr == nil }.count
        if missingAPRCount > 0 {
            notes.append("APR is missing for \(missingAPRCount) debt account(s), so avalanche ordering may not reflect true interest cost.")
        }

        let missingMinimumPaymentCount = liabilities.filter(\.missingMinimumPayment).count
        if missingMinimumPaymentCount > 0 {
            notes.append("Minimum payment is missing for \(missingMinimumPaymentCount) debt account(s); DebtScope is using its fallback payment estimate.")
        }

        if let infeasibleMinimum = strategyErrors.compactMap({ error -> Decimal? in
            guard let debtPlanError = error as? DebtPlanError,
                  case let .infeasibleBudget(requiredMinimum) = debtPlanError else {
                return nil
            }
            return requiredMinimum
        }).max() {
            if let monthlyBudget {
                notes.append("Current monthly payoff budget is \(formatCurrency(monthlyBudget)), but minimum payments require at least \(formatCurrency(infeasibleMinimum)).")
            } else {
                notes.append("DebtScope needs at least \(formatCurrency(infeasibleMinimum)) per month for minimum payments before it can compare payoff strategies.")
            }
        } else if let monthlyBudget, monthlyBudget < totalMinimumPayment {
            notes.append("Current monthly payoff budget is \(formatCurrency(monthlyBudget)), below total minimum payments of \(formatCurrency(totalMinimumPayment)).")
        } else if monthlyBudget == nil, !liabilities.isEmpty {
            notes.append("DebtScope could not determine a monthly payoff budget from the current budget settings.")
        }

        var seen = Set<String>()
        return notes.filter { seen.insert($0).inserted }
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
