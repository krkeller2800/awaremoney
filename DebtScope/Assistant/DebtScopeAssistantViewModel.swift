import Combine
import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AssistantMessage: Identifiable, Hashable {
    enum Role: Hashable {
        case user
        case assistant
        case systemNotice
    }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

private struct PendingExtraPaymentStrategyChoice {
    let extraMonthlyPayment: Decimal
    let startDate: Date
}

enum AssistantImportReviewQuestionFocus {
    case latestImport
    case duplicates
    case accountMapping
    case conflicts
    case general

    init(prompt: String) {
        let normalized = prompt.lowercased()
        if normalized.containsAnyImportReviewTerms(["duplicate", "duplicates", "dupe", "duplicated"]) {
            self = .duplicates
        } else if normalized.containsAnyImportReviewTerms(["account mapping", "mapping issue", "mapping issues", "unmapped", "unresolved mapping", "linked to an account"]) {
            self = .accountMapping
        } else if normalized.containsAnyImportReviewTerms(["conflict", "conflicts", "excluded", "skipped", "edited", "adjustment", "adjustments"]) {
            self = .conflicts
        } else if normalized.containsAnyImportReviewTerms(["latest import", "last import", "most recent import", "what changed after my import", "what changed after my latest import"]) {
            self = .latestImport
        } else {
            self = .general
        }
    }
}

enum AssistantCleanupRecommendationFocus {
    case missingAPR
    case missingMinimumPayments
    case accountMapping
    case duplicateImports
    case cashFlowSchedules
    case general

    init(prompt: String) {
        let normalized = prompt.lowercased()
        if normalized.containsAnyCleanupTerms(["apr", "interest rate"]) {
            self = .missingAPR
        } else if normalized.containsAnyCleanupTerms(["minimum payment", "minimum payments", "minimums"]) {
            self = .missingMinimumPayments
        } else if normalized.containsAnyCleanupTerms(["account mapping", "mapping issue", "mapping issues", "unmapped", "unresolved mapping", "resolve account"]) {
            self = .accountMapping
        } else if normalized.containsAnyCleanupTerms(["duplicate import", "duplicate imports", "duplicate candidate", "duplicate candidates"]) {
            self = .duplicateImports
        } else if normalized.containsAnyCleanupTerms(["bill and income", "income and bill", "bill schedule", "income schedule", "schedules", "complete bill", "complete income"]) {
            self = .cashFlowSchedules
        } else {
            self = .general
        }
    }
}

@MainActor
final class DebtScopeAssistantViewModel: ObservableObject {
    @Published var currentInput = ""
    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var availability: DebtScopeAssistantAvailability

    private let settings: SettingsStore
    private let service: DebtScopeAssistantService
    private var responseTask: Task<Void, Never>?
    private var pendingExtraPaymentStrategyChoice: PendingExtraPaymentStrategyChoice?

    private var sessionStorage: Any?

    init(context: ModelContext, settings: SettingsStore) {
        self.settings = settings
        self.service = DebtScopeAssistantService(context: context, settings: settings)
        self.availability = DebtScopeAssistantAvailability.current(assistantEnabled: settings.assistantEnabled)
    }

    var canSendPrompt: Bool {
        availability.isAvailable && !isLoading && !currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshAvailability() {
        availability = DebtScopeAssistantAvailability.current(assistantEnabled: settings.assistantEnabled)

        if !availability.isAvailable {
            resetSession(clearMessages: false)
        }
    }

    func sendCurrentPrompt() {
        sendPrompt(currentInput)
    }

    func sendPrompt(_ prompt: String) {
        refreshAvailability()

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        guard !isLoading else { return }
        guard availability.isAvailable else {
            appendSystemNotice(availability.message)
            return
        }

        if !settings.assistantRetainConversationHistory {
            resetSession(clearMessages: false)
        }

        errorMessage = nil
        currentInput = ""
        isLoading = true

        let userMessage = AssistantMessage(role: .user, text: trimmedPrompt)
        if settings.assistantRetainConversationHistory {
            messages.append(userMessage)
        } else {
            messages = [userMessage]
        }

        responseTask?.cancel()
        let readOnlyDefaultsSnapshot = DebtScopeAssistantReadOnlyDefaultsSnapshot.capture()
        responseTask = Task { [weak self] in
            guard let self else { return }
            defer { readOnlyDefaultsSnapshot.restore() }

            do {
                let response = try await self.generateResponse(to: trimmedPrompt)
                guard !Task.isCancelled else { return }

                let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayText = trimmedResponse.isEmpty
                    ? "DebtScope could not generate a response for that question."
                    : trimmedResponse

                self.messages.append(AssistantMessage(role: .assistant, text: displayText))
                self.isLoading = false

                if !self.settings.assistantRetainConversationHistory {
                    self.resetSession(clearMessages: false)
                }
            } catch is CancellationError {
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                let message = self.userFacingErrorMessage(for: error)
                self.errorMessage = message
                self.messages.append(AssistantMessage(role: .systemNotice, text: message))
                self.isLoading = false
                self.resetSession(clearMessages: false)
                AMLogging.error(
                    "Assistant response failed errorType=\(String(describing: type(of: error)))",
                    component: "DebtScopeAssistantViewModel"
                )
            }
        }
    }

    func cancelResponse() {
        responseTask?.cancel()
        responseTask = nil
        isLoading = false
    }

    func resetSession(clearMessages: Bool = true) {
        responseTask?.cancel()
        responseTask = nil
        isLoading = false
        errorMessage = nil

        sessionStorage = nil

        if clearMessages {
            pendingExtraPaymentStrategyChoice = nil
            messages = []
        }
    }

    private func appendSystemNotice(_ text: String) {
        errorMessage = text
        messages.append(AssistantMessage(role: .systemNotice, text: text))
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), error is LanguageModelSession.ToolCallError {
            return "DebtScope could not fetch the app data needed to answer that question."
        }
        #endif

        if error is CancellationError {
            return "The assistant response was canceled."
        }

        return "DebtScope Assistant could not answer that question. Try again with a shorter, more specific prompt."
    }

    private func generateResponse(to prompt: String) async throws -> String {
        if let directResponse = try directResponse(for: prompt) {
            return directResponse
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = sessionStorage as? LanguageModelSession ?? makeSession()
            sessionStorage = session
            let response = try await session.respond(to: prompt)
            return response.content
        }
        #endif

        throw DebtScopeAssistantViewModelError.foundationModelsUnavailable
    }

    private func directResponse(for prompt: String) throws -> String? {
        let intent = AssistantPromptIntent(prompt: prompt)
        if let pendingResponse = try pendingExtraPaymentStrategyResponse(for: prompt, intent: intent) {
            return pendingResponse
        }

        if intent != .none {
            pendingExtraPaymentStrategyChoice = nil
        }

        switch intent {
        case .debtPicture:
            return try formatDebtPicture(service.debtSummary())
        case .payoffFocus:
            return try formatPayoffFocus(service.payoffPlanSummary(startDate: Date()))
        case .strategySavings:
            let startDate = Date()
            let monthlyBudgetOverride = requestedStrategyComparisonMonthlyBudget(in: prompt)
            do {
                return try formatStrategySavings(
                    service.payoffStrategyComparison(
                        startDate: startDate,
                        monthlyBudgetOverride: monthlyBudgetOverride
                    ),
                    startDate: startDate,
                    error: nil
                )
            } catch {
                AMLogging.error(
                    "Assistant strategy comparison failed errorType=\(String(describing: type(of: error)))",
                    component: "DebtScopeAssistantViewModel"
                )
                return formatStrategySavings(nil, startDate: startDate, error: error)
            }
        case .extraPaymentSimulation:
            let scenarioStrategy = AssistantPromptAmountParser.extraPaymentStrategy(in: prompt)
            let extraMonthlyPayment = AssistantPromptAmountParser.signedMonthlyAmount(in: prompt)

            guard let scenarioStrategy else {
                if let extraMonthlyPayment {
                    pendingExtraPaymentStrategyChoice = PendingExtraPaymentStrategyChoice(
                        extraMonthlyPayment: extraMonthlyPayment,
                        startDate: Date()
                    )
                }
                return "Choose which strategy to use (minimums, avalanche, or snowball) when applying the extra payment."
            }

            guard let extraMonthlyPayment else {
                return "Tell me the extra monthly payment amount to simulate, such as $100 per month."
            }
            pendingExtraPaymentStrategyChoice = nil
            return try formatExtraPaymentSimulation(
                service.extraPaymentSimulation(
                    extraMonthlyPayment: extraMonthlyPayment,
                    startDate: Date(),
                    scenarioStrategy: scenarioStrategy
                )
            )
        case .importReview:
            return try formatImportReview(service.importReviewSummary(), prompt: prompt)
        case .cleanupRecommendations:
            return try formatCleanupRecommendations(service.cleanupRecommendationSummary(), prompt: prompt)
        case .upcomingBills:
            return try formatUpcomingBills(service.upcomingBills(days: 30), currencyCode: settings.currencyCode)
        case .debtAffordability:
            return try formatDebtAffordability(service.cashFlowSummary(months: 3), prompt: prompt)
        case .transactionDetails:
            return "Transaction details are disabled or not included in the current assistant tools. I can summarize DebtScope debt, payoff plans, upcoming bills, and cash-flow context, but I cannot show raw transactions or full memo text."
        case .none:
            return nil
        }
    }

    private func pendingExtraPaymentStrategyResponse(for prompt: String, intent: AssistantPromptIntent) throws -> String? {
        guard
            intent == .none,
            let pendingExtraPaymentStrategyChoice,
            let scenarioStrategy = AssistantPromptAmountParser.extraPaymentStrategy(in: prompt)
        else {
            return nil
        }

        self.pendingExtraPaymentStrategyChoice = nil
        return try formatExtraPaymentSimulation(
            service.extraPaymentSimulation(
                extraMonthlyPayment: pendingExtraPaymentStrategyChoice.extraMonthlyPayment,
                startDate: pendingExtraPaymentStrategyChoice.startDate,
                scenarioStrategy: scenarioStrategy
            )
        )
    }

    private func formatDebtPicture(_ summary: AssistantDebtSummary) -> String {
        guard summary.debtCount > 0 else {
            return missingDataResponse("I do not see active debt accounts with current balances in DebtScope yet.", notes: summary.missingDataNotes)
        }

        var lines = [
            "DebtScope shows \(summary.debtCount) active debt \(summary.debtCount == 1 ? "account" : "accounts") totaling \(formatCurrency(summary.totalDebt, currencyCode: summary.currencyCode)).",
            "Total minimum payments are \(formatCurrency(summary.totalMinimumPayment, currencyCode: summary.currencyCode)) per month."
        ]

        if let name = summary.highestAPRDebtName, let apr = summary.highestAPR {
            lines.append("The highest APR debt is \(name) at \(formatPercent(apr)).")
        }

        let accountLines = summary.accounts.prefix(3).map { account in
            "- \(account.name): \(formatCurrency(account.latestBalance, currencyCode: summary.currencyCode))" + (account.apr.map { " at \(formatPercent($0))" } ?? "")
        }
        lines.append(contentsOf: accountLines)
        lines.append(contentsOf: summary.missingDataNotes.prefix(3))
        return lines.joined(separator: "\n")
    }

    private func formatPayoffFocus(_ summary: AssistantPayoffPlanSummary?) -> String {
        guard let summary else {
            return "DebtScope could not compute a payoff plan with the current debt and payoff settings. Check that active debts have balances and payoff settings are configured."
        }
        guard let first = summary.payoffOrder.first else {
            return "DebtScope found a payoff plan, but there is no active debt in the payoff order."
        }

        var lines = [
            "Based on DebtScope's current \(formatStrategy(summary.strategy)) plan, focus on \(first.name) first.",
            "It starts at \(formatCurrency(first.startingBalance, currencyCode: summary.currencyCode))" + (first.apr.map { " with \(formatPercent($0)) APR." } ?? "."),
            "Projected total interest is \(formatCurrency(summary.totalInterest, currencyCode: summary.currencyCode))."
        ]
        if let date = first.payoffDate {
            lines.append("Projected payoff for that debt: \(formatDate(date)).")
        }
        if let budget = summary.monthlyBudget {
            lines.append("Current monthly debt budget: \(formatCurrency(budget, currencyCode: summary.currencyCode)).")
        }
        return lines.joined(separator: "\n")
    }

    private func formatStrategySavings(
        _ summary: AssistantPayoffStrategyComparisonSummary?,
        startDate: Date,
        error: Error?
    ) -> String {
        guard let summary else {
            let details = service.payoffStrategyComparisonUnavailableDetails(startDate: startDate, error: error)
            return (["DebtScope could not compare avalanche and snowball with the current payoff setup."] + details.prefix(4)).joined(separator: "\n")
        }

        guard summary.avalanche.paymentFeasible, summary.snowball.paymentFeasible else {
            var lines = ["DebtScope could not compare avalanche and snowball with the current payoff setup."]
            if summary.minimumPayments.paymentFeasible {
                lines.append("Minimum-payment interest: \(formatCurrency(summary.minimumPayments.totalInterest, currencyCode: summary.currencyCode)).")
            }
            lines.append(contentsOf: summary.missingDataNotes.prefix(4))
            return lines.joined(separator: "\n")
        }

        var lines = [
            comparisonBasisLine(summary),
            "Using avalanche instead of snowball saves \(formatCurrency(summary.interestSavingsUsingAvalanche, currencyCode: summary.currencyCode)) in projected interest.",
            "Avalanche interest: \(formatCurrency(summary.avalanche.totalInterest, currencyCode: summary.currencyCode)).",
            "Snowball interest: \(formatCurrency(summary.snowball.totalInterest, currencyCode: summary.currencyCode)).",
            "Minimum-payment interest: \(formatCurrency(summary.minimumPayments.totalInterest, currencyCode: summary.currencyCode))."
        ]
        if !summary.minimumPayments.paymentFeasible {
            lines.append("The minimum-payment strategy is not feasible with the current setup.")
        }
        if let months = summary.avalancheDebtFreeDateAdvantageMonths {
            if months > 0 {
                lines.append("Avalanche is projected to finish \(months) \(months == 1 ? "month" : "months") sooner.")
            } else if months == 0 {
                lines.append("Both strategies are projected to finish in the same month.")
            }
        }
        if let first = summary.avalanche.payoffOrder.first {
            lines.append("Avalanche starts with \(first.name).")
        }
        lines.append(contentsOf: summary.missingDataNotes.prefix(4))
        return lines.joined(separator: "\n")
    }

    private func comparisonBasisLine(_ summary: AssistantPayoffStrategyComparisonSummary) -> String {
        if let monthlyBudget = summary.monthlyBudget {
            return "Comparison basis: \(formatCurrency(monthlyBudget, currencyCode: summary.currencyCode)) monthly debt budget starting \(formatMonthYear(summary.startDate))."
        }

        return "Comparison basis: payoff settings starting \(formatMonthYear(summary.startDate))."
    }

    private func formatExtraPaymentSimulation(_ summary: AssistantExtraPaymentSimulationSummary) -> String {
        switch summary.status {
        case .invalidAmount:
            return summary.validationMessage ?? "DebtScope could not simulate that extra payment amount."
        case .unavailable:
            var lines = [summary.validationMessage ?? "DebtScope could not compute that extra-payment simulation."]
            lines.append(extraPaymentStrategyLine(summary))
            lines.append(contentsOf: summary.missingDataNotes.prefix(4))
            return lines.joined(separator: "\n")
        case .valid:
            guard let baseline = summary.baseline, let scenario = summary.scenario else {
                return "DebtScope could not compute both the baseline and extra-payment payoff plans."
            }

            var lines = [
                extraPaymentStrategyLine(summary),
                "Extra payment simulated: \(formatCurrency(summary.extraMonthlyPayment, currencyCode: summary.currencyCode)) per month starting \(formatMonthYear(summary.startDate)).",
                "Baseline monthly debt budget: \(formatCurrency(summary.baselineMonthlyBudget ?? 0, currencyCode: summary.currencyCode)).",
                "Temporary scenario monthly debt budget: \(formatCurrency(summary.scenarioMonthlyBudget ?? 0, currencyCode: summary.currencyCode)).",
                "Baseline result: \(formatCurrency(baseline.totalInterest, currencyCode: summary.currencyCode)) interest, debt-free date \(formatOptionalMonthYear(baseline.projectedDebtFreeDate)).",
                "Scenario result: \(formatCurrency(scenario.totalInterest, currencyCode: summary.currencyCode)) interest, debt-free date \(formatOptionalMonthYear(scenario.projectedDebtFreeDate)).",
                "Projected interest saved: \(formatCurrency(summary.interestSaved ?? 0, currencyCode: summary.currencyCode))."
            ]

            if summary.extraMonthlyPayment == 0 {
                lines.append("Because the extra payment is $0.00, the scenario matches the baseline.")
            }

            if let months = summary.debtFreeDateAdvantageMonths {
                if months > 0 {
                    lines.append("The extra payment is projected to finish payoff \(months) \(months == 1 ? "month" : "months") sooner.")
                } else if months == 0 {
                    lines.append("Baseline and scenario are projected to finish in the same month.")
                }
            }
            if let firstAffectedAccountName = summary.firstAffectedAccountName {
                lines.append("First affected debt: \(firstAffectedAccountName).")
            }
            lines.append(contentsOf: summary.missingDataNotes.prefix(3))
            return lines.joined(separator: "\n")
        }
    }

    private func formatImportReview(_ summary: AssistantImportReviewSummary, prompt: String) -> String {
        guard summary.importCount > 0 else {
            return missingDataResponse("DebtScope does not show completed imports yet.", notes: summary.reviewNotes)
        }

        let focus = AssistantImportReviewQuestionFocus(prompt: prompt)
        var lines: [String]

        switch focus {
        case .duplicates:
            lines = [
                "DebtScope shows \(summary.duplicateTransactionCandidateCount) duplicate import candidate record(s)."
            ]
            if summary.duplicateTransactionCandidateCount == 0 {
                lines.append("Recent imports do not show duplicate transaction import-key matches.")
            }
            appendLatestImportContextIfUseful(to: &lines, summary: summary)
            appendTransactionPrivacyLineIfNeeded(to: &lines, summary: summary)
            lines.append(contentsOf: summary.reviewNotes.filter { $0.contains("duplicate") }.prefix(2))
            return lines.joined(separator: "\n")

        case .accountMapping:
            lines = [
                "DebtScope shows \(summary.unresolvedAccountMappingCount) imported record(s) that may need account mapping review."
            ]
            if let latest = summary.latestImport {
                lines.append("Latest import mapping count: \(latest.unresolvedAccountMappingCount) unresolved record(s).")
            }
            lines.append("Mapped imported account count: \(summary.mappedAccountCount).")
            appendTransactionPrivacyLineIfNeeded(to: &lines, summary: summary)
            lines.append(contentsOf: summary.reviewNotes.filter { $0.contains("mapping") || $0.contains("linked to an account") }.prefix(2))
            return lines.joined(separator: "\n")

        case .conflicts:
            lines = [
                "DebtScope shows \(summary.conflictCount) imported record(s) that are excluded, edited, or adjusted."
            ]
            if let latest = summary.latestImport {
                lines.append("Latest import has \(latest.excludedRecordCount) excluded record(s) and \(latest.editedRecordCount) edited record(s).")
            }
            appendTransactionPrivacyLineIfNeeded(to: &lines, summary: summary)
            lines.append(contentsOf: summary.reviewNotes.filter { $0.contains("excluded") || $0.contains("edits") || $0.contains("conflicts") || $0.contains("adjustments") }.prefix(2))
            return lines.joined(separator: "\n")

        case .latestImport, .general:
            lines = []
        }

        if let latest = summary.latestImport {
            lines.append("Latest import: \(latest.label) on \(formatDate(latest.importedAt)).")
            lines.append("Imported \(latest.importedBalanceCount) balance(s), \(latest.importedTransactionCount) transaction(s), and \(latest.importedHoldingCount) holding(s).")
            if let parserName = latest.parserName {
                lines.append("Parser: \(parserName).")
            }
            if let institutionName = latest.detectedInstitutionName {
                lines.append("Detected institution: \(institutionName).")
            }
            if latest.unresolvedAccountMappingCount > 0 {
                lines.append("\(latest.unresolvedAccountMappingCount) record(s) from the latest import still need account mapping review.")
            }
            if latest.excludedRecordCount > 0 || latest.editedRecordCount > 0 {
                lines.append("Latest import has \(latest.excludedRecordCount) excluded record(s) and \(latest.editedRecordCount) edited record(s).")
            }
        }

        if focus == .general {
            lines.append("Across imports: \(summary.totalImportedBalanceCount) balance(s), \(summary.totalImportedTransactionCount) transaction(s), \(summary.totalImportedHoldingCount) holding(s).")
            lines.append("Review counts: \(summary.duplicateTransactionCandidateCount) duplicate candidate record(s), \(summary.conflictCount) conflict/adjustment record(s), \(summary.unresolvedAccountMappingCount) unresolved mapping record(s).")
        }
        appendTransactionPrivacyLineIfNeeded(to: &lines, summary: summary)
        lines.append(contentsOf: summary.reviewNotes.prefix(4))
        return lines.joined(separator: "\n")
    }

    private func appendLatestImportContextIfUseful(to lines: inout [String], summary: AssistantImportReviewSummary) {
        guard let latest = summary.latestImport else { return }
        lines.append("Latest import: \(latest.label), with \(latest.importedTransactionCount) imported transaction(s).")
    }

    private func appendTransactionPrivacyLineIfNeeded(to lines: inout [String], summary: AssistantImportReviewSummary) {
        if !summary.transactionLevelDetailAvailable {
            lines.append("Transaction-level detail is disabled, so this answer stays at count level.")
        }
    }

    private func formatCleanupRecommendations(_ summary: AssistantCleanupRecommendationSummary, prompt: String) -> String {
        let focus = AssistantCleanupRecommendationFocus(prompt: prompt)
        if focus != .general {
            return formatFocusedCleanupGuidance(summary, focus: focus)
        }

        guard !summary.recommendations.isEmpty else {
            return "DebtScope doesn't show any needed cleanup."
        }

        var lines = [
            "DebtScope found \(summary.recommendationCount) cleanup recommendation(s).",
            "These are suggestions only; each change requires normal app confirmation."
        ]

        lines.append(contentsOf: summary.recommendations.prefix(5).map { recommendation in
            "- \(recommendation.title): review \(recommendation.affectedRecordCount) item(s) in \(recommendation.destination). \(recommendation.expectedBenefit)"
        })

        if !summary.transactionLevelDetailAvailable {
            lines.append("Transaction-level detail is disabled, so import-related recommendations stay at count level.")
        }

        return lines.joined(separator: "\n")
    }

    private func formatFocusedCleanupGuidance(
        _ summary: AssistantCleanupRecommendationSummary,
        focus: AssistantCleanupRecommendationFocus
    ) -> String {
        let recommendationKind: AssistantCleanupRecommendationKind
        let cleanStateLine: String
        let guidanceLines: [String]

        switch focus {
        case .missingAPR:
            recommendationKind = .missingAPR
            cleanStateLine = "DebtScope doesn't show missing APR cleanup right now."
            guidanceLines = [
                "To fix APRs in the app, go to Debt Payoff, choose the liability account, enter the APR from your statement in the APR field, and tap the checkmark or Done to confirm.",
                "Adding APRs improves avalanche ordering and projected interest totals."
            ]
        case .missingMinimumPayments:
            recommendationKind = .missingMinimumPayments
            cleanStateLine = "DebtScope doesn't show missing minimum-payment cleanup right now."
            guidanceLines = [
                "To fix minimum payments in the app, go to Debt Payoff, choose the liability account, enter the minimum payment from your statement in the Typical payment field, and tap the checkmark or Done to confirm.",
                "Adding minimum payments reduces fallback estimates and makes payoff projections more reliable."
            ]
        case .accountMapping:
            recommendationKind = .missingAccountMappings
            cleanStateLine = "DebtScope doesn't show account mapping cleanup right now."
            guidanceLines = [
                "Account mapping happens during statement import review. When DebtScope cannot confidently match imported records to an account, choose the correct DebtScope account before accepting the import.",
                "Mapping imported records improves account balances, import review clarity, and future duplicate detection."
            ]
        case .duplicateImports:
            recommendationKind = .duplicateImports
            cleanStateLine = "DebtScope doesn't show duplicate import cleanup right now."
            guidanceLines = [
                "Duplicate review happens during statement import review. When you import a statement, DebtScope flags possible duplicates before you accept the import so you can choose what to keep or exclude.",
                "Duplicate review helps prevent imported activity from being counted twice."
            ]
        case .cashFlowSchedules:
            recommendationKind = .incompleteCashFlowSetup
            cleanStateLine = "DebtScope doesn't show incomplete bill or income schedules right now."
            guidanceLines = [
                "To complete schedules in the app, open Income & Bills, choose the bill or income item, add the due date or payment day, and confirm the change.",
                "Complete schedules improve upcoming bill timing, monthly cash-flow summaries, and reserve planning."
            ]
        case .general:
            return formatCleanupRecommendations(summary, prompt: "")
        }

        var lines: [String]
        if let recommendation = summary.recommendations.first(where: { $0.kind == recommendationKind }) {
            lines = [
                "DebtScope shows \(recommendation.affectedRecordCount) item(s) to review for \(recommendation.title.lowercased())."
            ]
        } else {
            lines = [cleanStateLine]
        }

        lines.append(contentsOf: guidanceLines)
        lines.append("I can't make the change directly; it needs the normal app confirmation flow.")
        return lines.joined(separator: "\n")
    }

    private func extraPaymentStrategyLine(_ summary: AssistantExtraPaymentSimulationSummary) -> String {
        if summary.strategy == summary.scenarioStrategy {
            return "Strategy used for both baseline and scenario: \(formatStrategy(summary.strategy))."
        }

        return "Baseline strategy: \(formatStrategy(summary.strategy)); extra-payment scenario strategy: \(formatStrategy(summary.scenarioStrategy))."
    }

    private func formatUpcomingBills(_ bills: [AssistantUpcomingBillSummary], currencyCode: String) -> String {
        guard !bills.isEmpty else {
            return "DebtScope does not show bills due in the next 30 days."
        }

        let lines = bills.prefix(8).map { bill in
            let date = bill.dueDate.map { formatDate($0) } ?? "no due date"
            var line = "- \(bill.name): \(formatCurrency(bill.amount, currencyCode: currencyCode)) due \(date)"
            if let fundingSourceName = bill.fundingSourceName {
                line += ", funded by \(fundingSourceName)"
            }
            return line
        }
        return (["Upcoming bills in the next 30 days:"] + lines).joined(separator: "\n")
    }

    private func formatDebtAffordability(_ summary: AssistantCashFlowSummary, prompt: String) -> String {
        guard summary.incomeItemCount > 0 || summary.billItemCount > 0 else {
            return missingDataResponse("DebtScope does not have enough income and bill data to judge whether an extra debt payment fits your cash flow.", notes: summary.missingDataNotes)
        }

        let requestedAmount = requestedMonthlyAmount(in: prompt) ?? 100
        let available = summary.reserveAdjustedAvailableForDebt ?? summary.recurringNet
        let canFit = available >= requestedAmount
        var lines = [
            canFit
                ? "Based on DebtScope cash-flow data, an extra \(formatCurrency(requestedAmount, currencyCode: summary.currencyCode)) monthly debt payment appears to fit the current budget context."
                : "Based on DebtScope cash-flow data, an extra \(formatCurrency(requestedAmount, currencyCode: summary.currencyCode)) monthly debt payment does not appear to fit the current budget context.",
            "Reserve-adjusted amount available for debt: \(formatCurrency(available, currencyCode: summary.currencyCode)).",
            "Recurring monthly income: \(formatCurrency(summary.monthlyIncome, currencyCode: summary.currencyCode)); recurring monthly bills: \(formatCurrency(summary.monthlyBills, currencyCode: summary.currencyCode)).",
            "This is a DebtScope planning estimate, not financial advice."
        ]
        lines.append(contentsOf: summary.missingDataNotes.prefix(3))
        return lines.joined(separator: "\n")
    }

    private func missingDataResponse(_ lead: String, notes: [String]) -> String {
        let noteLines = notes.prefix(3).map { "- \($0)" }
        guard !noteLines.isEmpty else { return lead }
        return ([lead, "Missing data:"] + noteLines).joined(separator: "\n")
    }

    private func requestedMonthlyAmount(in prompt: String) -> Decimal? {
        guard let match = prompt.range(of: #"\$?\d+(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        let value = prompt[match].replacingOccurrences(of: "$", with: "")
        return Decimal(string: value)
    }

    private func requestedStrategyComparisonMonthlyBudget(in prompt: String) -> Decimal? {
        let normalized = prompt.lowercased()
        guard normalized.contains("budget") else { return nil }

        if let match = prompt.range(of: #"\$\s*\d+(?:,\d{3})*(?:\.\d+)?"#, options: .regularExpression) {
            let value = prompt[match]
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
            return Decimal(string: value)
        }

        guard normalized.contains("monthly") else { return nil }
        guard let match = prompt.range(of: #"\d+(?:,\d{3})*(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        let value = prompt[match].replacingOccurrences(of: ",", with: "")
        return Decimal(string: value)
    }

    private func formatCurrency(_ value: Decimal, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value) \(currencyCode)"
    }

    private func formatPercent(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func formatMonthYear(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private func formatOptionalMonthYear(_ date: Date?) -> String {
        date.map { formatMonthYear($0) } ?? "unavailable"
    }

    private func formatStrategy(_ strategy: AssistantPayoffStrategy) -> String {
        switch strategy {
        case .minimumsOnly:
            return "minimums-only"
        case .snowball:
            return "snowball"
        case .avalanche:
            return "avalanche"
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            tools: DebtScopeAssistantToolFactory.debtAndPayoffTools(service: service),
            instructions: DebtScopeAssistantInstructions.defaultInstructions
        )
    }
    #endif
}

private enum DebtScopeAssistantViewModelError: Error {
    case foundationModelsUnavailable
}

private extension String {
    func containsAnyImportReviewTerms(_ needles: [String]) -> Bool {
        needles.contains { contains($0) }
    }

    func containsAnyCleanupTerms(_ needles: [String]) -> Bool {
        needles.contains { contains($0) }
    }
}

enum AssistantPromptAmountParser {
    static func extraPaymentStrategy(in prompt: String) -> AssistantPayoffStrategy? {
        let tokens = prompt
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }

        if tokens.contains("minimum")
            || tokens.contains("minimums")
            || (tokens.contains("minimum") && tokens.contains("payments")) {
            return .minimumsOnly
        }

        if tokens.contains("avalanche") {
            return .avalanche
        }

        if tokens.contains("snowball") {
            return .snowball
        }

        return nil
    }

    static func signedMonthlyAmount(in prompt: String) -> Decimal? {
        let tokens = prompt
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }

        if tokens.contains("zero") {
            return 0
        }

        guard let match = prompt.range(of: #"-?\$?\s*\d+(?:,\d{3})*(?:\.\d+)?"#, options: .regularExpression) else {
            return nil
        }

        let value = prompt[match]
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Decimal(string: value)
    }
}

struct DebtScopeAssistantReadOnlyDefaultsSnapshot {
    private static let protectedKeys = [
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

    static func capture(defaults: UserDefaults = .standard) -> DebtScopeAssistantReadOnlyDefaultsSnapshot {
        var values: [String: Any] = [:]
        var missingKeys = Set<String>()

        for key in protectedKeys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            } else {
                missingKeys.insert(key)
            }
        }

        return DebtScopeAssistantReadOnlyDefaultsSnapshot(values: values, missingKeys: missingKeys)
    }

    func restore(defaults: UserDefaults = .standard) {
        for key in Self.protectedKeys {
            if missingKeys.contains(key) {
                defaults.removeObject(forKey: key)
            } else if let value = values[key] {
                defaults.set(value, forKey: key)
            }
        }
    }
}
