import Combine
import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AssistantMessageAction: Identifiable, Hashable {
    let title: String
    let destination: DebtScopeAppSection
    let accountID: UUID?
    let focus: DebtScopeAppRouteFocus?

    init(
        title: String,
        destination: DebtScopeAppSection,
        accountID: UUID? = nil,
        focus: DebtScopeAppRouteFocus? = nil
    ) {
        self.title = title
        self.destination = destination
        self.accountID = accountID
        self.focus = focus
    }

    var id: String {
        "\(destination.rawValue):\(accountID?.uuidString ?? "section"):\(focus?.rawValue ?? "none"):\(title)"
    }
}

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
    let actions: [AssistantMessageAction]

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        actions: [AssistantMessageAction] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.actions = actions
    }
}

private struct AssistantGeneratedResponse {
    let text: String
    let actions: [AssistantMessageAction]

    init(text: String, actions: [AssistantMessageAction] = []) {
        self.text = text
        self.actions = actions
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

                let trimmedResponse = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayText = trimmedResponse.isEmpty
                    ? "DebtScope could not generate a response for that question."
                    : trimmedResponse

                self.messages.append(AssistantMessage(role: .assistant, text: displayText, actions: response.actions))
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

        return "DebtScope Assistant could not answer that question. Try again with a more specific prompt."
    }

    private func generateResponse(to prompt: String) async throws -> AssistantGeneratedResponse {
        if let directResponse = try directResponse(for: prompt) {
            return directResponse
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = sessionStorage as? LanguageModelSession ?? makeSession()
            sessionStorage = session
            let response = try await session.respond(to: prompt)
            return AssistantGeneratedResponse(text: response.content)
        }
        #endif

        throw DebtScopeAssistantViewModelError.foundationModelsUnavailable
    }

    private func directResponse(for prompt: String) throws -> AssistantGeneratedResponse? {
        let intent = AssistantPromptIntent(prompt: prompt)
        if let pendingResponse = try pendingExtraPaymentStrategyResponse(for: prompt, intent: intent) {
            return pendingResponse
        }

        if intent != .none {
            pendingExtraPaymentStrategyChoice = nil
        }

        switch intent {
        case .debtPicture:
            return AssistantGeneratedResponse(text: try formatDebtPicture(service.debtSummary()))
        case .payoffFocus:
            return AssistantGeneratedResponse(text: try formatPayoffFocus(service.payoffPlanSummary(startDate: Date())))
        case .strategySavings:
            let startDate = Date()
            let monthlyBudgetOverride = requestedStrategyComparisonMonthlyBudget(in: prompt)
            do {
                return AssistantGeneratedResponse(text: try formatStrategySavings(
                    service.payoffStrategyComparison(
                        startDate: startDate,
                        monthlyBudgetOverride: monthlyBudgetOverride
                    ),
                    startDate: startDate,
                    error: nil
                ))
            } catch {
                AMLogging.error(
                    "Assistant strategy comparison failed errorType=\(String(describing: type(of: error)))",
                    component: "DebtScopeAssistantViewModel"
                )
                return AssistantGeneratedResponse(text: formatStrategySavings(nil, startDate: startDate, error: error))
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
                return AssistantGeneratedResponse(text: "Choose which strategy to use (minimums, avalanche, or snowball) when applying the extra payment.")
            }

            guard let extraMonthlyPayment else {
                return AssistantGeneratedResponse(text: "Tell me the extra monthly payment amount to simulate, such as $100 per month.")
            }
            pendingExtraPaymentStrategyChoice = nil
            return AssistantGeneratedResponse(text: try formatExtraPaymentSimulation(
                service.extraPaymentSimulation(
                    extraMonthlyPayment: extraMonthlyPayment,
                    startDate: Date(),
                    scenarioStrategy: scenarioStrategy
                )
            ))
        case .importReview:
            return AssistantGeneratedResponse(text: try formatImportReview(service.importReviewSummary(), prompt: prompt))
        case .cleanupRecommendations:
            return try cleanupRecommendationResponse(service.cleanupRecommendationSummary(), prompt: prompt)
        case .upcomingBills:
            return AssistantGeneratedResponse(text: try formatUpcomingBills(service.upcomingBills(days: 30), currencyCode: settings.currencyCode))
        case .debtAffordability:
            return AssistantGeneratedResponse(text: try formatDebtAffordability(service.cashFlowSummary(months: 3), prompt: prompt))
        case .transactionDetails:
            return AssistantGeneratedResponse(text: "Transaction details are disabled or not included in the current assistant tools. I can summarize DebtScope debt, payoff plans, upcoming bills, and cash-flow context, but I cannot show raw transactions or full memo text.")
        case .none:
            return nil
        }
    }

    private func pendingExtraPaymentStrategyResponse(for prompt: String, intent: AssistantPromptIntent) throws -> AssistantGeneratedResponse? {
        guard
            intent == .none,
            let pendingExtraPaymentStrategyChoice,
            let scenarioStrategy = AssistantPromptAmountParser.extraPaymentStrategy(in: prompt)
        else {
            return nil
        }

        self.pendingExtraPaymentStrategyChoice = nil
        return AssistantGeneratedResponse(text: try formatExtraPaymentSimulation(
            service.extraPaymentSimulation(
                extraMonthlyPayment: pendingExtraPaymentStrategyChoice.extraMonthlyPayment,
                startDate: pendingExtraPaymentStrategyChoice.startDate,
                scenarioStrategy: scenarioStrategy
            )
        ))
    }

    private func formatDebtPicture(_ summary: AssistantDebtSummary) -> String {
        guard summary.debtCount > 0 else {
            return missingDataResponse("I do not see active debt accounts with current balances in DebtScope yet.", notes: summary.missingDataNotes)
        }

        var lines = [
            "DebtScope shows \(summary.debtCount) active debt \(summary.debtCount == 1 ? "account" : "accounts") totaling \(formatCurrency(summary.totalDebt, currencyCode: summary.currencyCode))."
        ]

        var overview = [
            "Total minimum payments: \(formatCurrency(summary.totalMinimumPayment, currencyCode: summary.currencyCode)) per month"
        ]
        if let name = summary.highestAPRDebtName, let apr = summary.highestAPR {
            overview.append("Highest APR debt: \(name) at \(formatPercent(apr))")
        }
        appendSection("Overview", items: overview, to: &lines)

        let accountLines = summary.accounts.prefix(3).map { account in
            "\(account.name): \(formatCurrency(account.latestBalance, currencyCode: summary.currencyCode))" + (account.apr.map { " at \(formatPercent($0))" } ?? "")
        }
        appendSection("Top Debts", items: accountLines, to: &lines)
        appendNotes(summary.missingDataNotes, to: &lines)
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
            "Focus on \(first.name) first under DebtScope's current \(formatStrategy(summary.strategy)) plan."
        ]

        var details = [
            "Starting balance: \(formatCurrency(first.startingBalance, currencyCode: summary.currencyCode))" + (first.apr.map { " at \(formatPercent($0)) APR" } ?? ""),
            "Projected total interest: \(formatCurrency(summary.totalInterest, currencyCode: summary.currencyCode))"
        ]
        if let date = first.payoffDate {
            details.append("Projected payoff for this debt: \(formatDate(date))")
        }
        if let budget = summary.monthlyBudget {
            details.append("Monthly debt budget: \(formatCurrency(budget, currencyCode: summary.currencyCode))")
        }
        appendSection("Plan Details", items: details, to: &lines)
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
            "Avalanche is projected to save \(formatCurrency(summary.interestSavingsUsingAvalanche, currencyCode: summary.currencyCode)) in interest compared with snowball."
        ]

        if let months = summary.avalancheDebtFreeDateAdvantageMonths {
            if months > 0 {
                lines.append("It is also projected to finish \(months) \(months == 1 ? "month" : "months") sooner.")
            } else if months == 0 {
                lines.append("Both strategies are projected to finish in the same month.")
            }
        }

        lines.append("")
        lines.append("Comparison")
        lines.append("- \(comparisonBasisLine(summary))")
        lines.append("- Avalanche interest: \(formatCurrency(summary.avalanche.totalInterest, currencyCode: summary.currencyCode))")
        lines.append("- Snowball interest: \(formatCurrency(summary.snowball.totalInterest, currencyCode: summary.currencyCode))")
        if let first = summary.avalanche.payoffOrder.first {
            lines.append("- First avalanche target: \(first.name)")
        }

        var caveats: [String] = []
        if !summary.minimumPayments.paymentFeasible {
            caveats.append("The minimum-payment strategy is not feasible with the current setup.")
        }
        caveats.append(contentsOf: summary.missingDataNotes.prefix(4))

        if !caveats.isEmpty {
            lines.append("")
            lines.append("Notes")
            lines.append(contentsOf: caveats.map { "- \($0)" })
        }

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
            appendSection("Scenario", items: [extraPaymentStrategyLine(summary)], to: &lines)
            appendNotes(summary.missingDataNotes, to: &lines, limit: 4)
            return lines.joined(separator: "\n")
        case .valid:
            guard let baseline = summary.baseline, let scenario = summary.scenario else {
                return "DebtScope could not compute both the baseline and extra-payment payoff plans."
            }

            let interestSaved = summary.interestSaved ?? 0
            var lines = [
                "The extra payment is projected to save \(formatCurrency(interestSaved, currencyCode: summary.currencyCode)) in interest."
            ]

            if let months = summary.debtFreeDateAdvantageMonths {
                if months > 0 {
                    lines.append("It is also projected to finish payoff \(months) \(months == 1 ? "month" : "months") sooner.")
                } else if months == 0 {
                    lines.append("Baseline and scenario are projected to finish in the same month.")
                }
            }

            appendSection("Scenario", items: [
                extraPaymentStrategyLine(summary),
                "Extra payment: \(formatCurrency(summary.extraMonthlyPayment, currencyCode: summary.currencyCode)) per month starting \(formatMonthYear(summary.startDate))",
                "Baseline monthly debt budget: \(formatCurrency(summary.baselineMonthlyBudget ?? 0, currencyCode: summary.currencyCode))",
                "Temporary scenario budget: \(formatCurrency(summary.scenarioMonthlyBudget ?? 0, currencyCode: summary.currencyCode))"
            ], to: &lines)

            var results = [
                "Baseline: \(formatCurrency(baseline.totalInterest, currencyCode: summary.currencyCode)) interest, debt-free date \(formatOptionalMonthYear(baseline.projectedDebtFreeDate))",
                "Scenario: \(formatCurrency(scenario.totalInterest, currencyCode: summary.currencyCode)) interest, debt-free date \(formatOptionalMonthYear(scenario.projectedDebtFreeDate))"
            ]
            if let firstAffectedAccountName = summary.firstAffectedAccountName {
                results.append("First affected debt: \(firstAffectedAccountName)")
            }
            appendSection("Results", items: results, to: &lines)

            var notes = Array(summary.missingDataNotes.prefix(3))
            if summary.extraMonthlyPayment == 0 {
                notes.insert("Because the extra payment is $0.00, the scenario matches the baseline.", at: 0)
            }
            appendSection("Notes", items: notes, to: &lines)
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
                summary.duplicateTransactionCandidateCount == 0
                    ? "Recent imports do not show duplicate transaction import-key matches."
                    : "DebtScope shows \(summary.duplicateTransactionCandidateCount) duplicate import candidate record(s)."
            ]
            if let latest = summary.latestImport {
                appendSection("Latest Import", items: ["\(latest.label): \(latest.importedTransactionCount) imported transaction(s)"], to: &lines)
            }
            var notes = Array(summary.reviewNotes.filter { $0.contains("duplicate") }.prefix(2))
            appendPrivacyNoteIfNeeded(to: &notes, summary: summary)
            appendSection("Notes", items: notes, to: &lines)
            return lines.joined(separator: "\n")

        case .accountMapping:
            lines = [
                "DebtScope shows \(summary.unresolvedAccountMappingCount) imported record(s) that may need account mapping review."
            ]
            var mappingItems = ["Mapped imported accounts: \(summary.mappedAccountCount)"]
            if let latest = summary.latestImport {
                mappingItems.insert("Latest import unresolved mappings: \(latest.unresolvedAccountMappingCount)", at: 0)
            }
            appendSection("Mapping", items: mappingItems, to: &lines)
            var notes = Array(summary.reviewNotes.filter { $0.contains("mapping") || $0.contains("linked to an account") }.prefix(2))
            appendPrivacyNoteIfNeeded(to: &notes, summary: summary)
            appendSection("Notes", items: notes, to: &lines)
            return lines.joined(separator: "\n")

        case .conflicts:
            lines = [
                "DebtScope shows \(summary.conflictCount) imported record(s) that are excluded, edited, or adjusted."
            ]
            if let latest = summary.latestImport {
                appendSection("Latest Import", items: [
                    "Excluded records: \(latest.excludedRecordCount)",
                    "Edited records: \(latest.editedRecordCount)"
                ], to: &lines)
            }
            var notes = Array(summary.reviewNotes.filter { $0.contains("excluded") || $0.contains("edits") || $0.contains("conflicts") || $0.contains("adjustments") }.prefix(2))
            appendPrivacyNoteIfNeeded(to: &notes, summary: summary)
            appendSection("Notes", items: notes, to: &lines)
            return lines.joined(separator: "\n")

        case .latestImport, .general:
            lines = []
        }

        if let latest = summary.latestImport {
            lines.append("Latest import was \(latest.label) on \(formatDate(latest.importedAt)).")

            var importedItems = [
                "Balances: \(latest.importedBalanceCount)",
                "Transactions: \(latest.importedTransactionCount)",
                "Holdings: \(latest.importedHoldingCount)"
            ]
            if let parserName = latest.parserName {
                importedItems.append("Parser: \(parserName)")
            }
            if let institutionName = latest.detectedInstitutionName {
                importedItems.append("Detected institution: \(institutionName)")
            }
            appendSection("Imported Records", items: importedItems, to: &lines)

            var reviewItems: [String] = []
            if latest.unresolvedAccountMappingCount > 0 {
                reviewItems.append("Unresolved mappings: \(latest.unresolvedAccountMappingCount)")
            }
            if latest.excludedRecordCount > 0 || latest.editedRecordCount > 0 {
                reviewItems.append("Excluded records: \(latest.excludedRecordCount)")
                reviewItems.append("Edited records: \(latest.editedRecordCount)")
            }
            appendSection("Review", items: reviewItems, to: &lines)
        }

        if focus == .general {
            appendSection("Across Imports", items: [
                "Balances: \(summary.totalImportedBalanceCount)",
                "Transactions: \(summary.totalImportedTransactionCount)",
                "Holdings: \(summary.totalImportedHoldingCount)",
                "Duplicate candidates: \(summary.duplicateTransactionCandidateCount)",
                "Conflicts or adjustments: \(summary.conflictCount)",
                "Unresolved mappings: \(summary.unresolvedAccountMappingCount)"
            ], to: &lines)
        }

        var notes = Array(summary.reviewNotes.prefix(4))
        appendPrivacyNoteIfNeeded(to: &notes, summary: summary)
        appendSection("Notes", items: notes, to: &lines)
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

    private func cleanupRecommendationResponse(_ summary: AssistantCleanupRecommendationSummary, prompt: String) -> AssistantGeneratedResponse {
        AssistantGeneratedResponse(
            text: formatCleanupRecommendations(summary, prompt: prompt),
            actions: cleanupRecommendationActions(summary, prompt: prompt)
        )
    }

    private func cleanupRecommendationActions(_ summary: AssistantCleanupRecommendationSummary, prompt: String) -> [AssistantMessageAction] {
        let focus = AssistantCleanupRecommendationFocus(prompt: prompt)
        let recommendations: [AssistantCleanupRecommendation]

        switch focus {
        case .missingAPR:
            recommendations = summary.recommendations.filter { $0.kind == .missingAPR }
        case .missingMinimumPayments:
            recommendations = summary.recommendations.filter { $0.kind == .missingMinimumPayments }
        case .accountMapping:
            recommendations = summary.recommendations.filter { $0.kind == .missingAccountMappings }
        case .duplicateImports:
            recommendations = summary.recommendations.filter { $0.kind == .duplicateImports }
        case .cashFlowSchedules:
            recommendations = summary.recommendations.filter { $0.kind == .incompleteCashFlowSetup }
        case .general:
            recommendations = Array(summary.recommendations.prefix(5))
        }

        var seenRoutes = Set<String>()
        return recommendations.compactMap { recommendation in
            let route = actionRoute(for: recommendation)
            let routeKey = "\(route.destination.rawValue):\(route.accountID?.uuidString ?? "section"):\(route.focus?.rawValue ?? "none")"
            guard seenRoutes.insert(routeKey).inserted else { return nil }
            return AssistantMessageAction(
                title: actionTitle(for: recommendation),
                destination: route.destination,
                accountID: route.accountID,
                focus: route.focus
            )
        }
    }

    private func actionRoute(for recommendation: AssistantCleanupRecommendation) -> (destination: DebtScopeAppSection, accountID: UUID?, focus: DebtScopeAppRouteFocus?) {
        switch recommendation.kind {
        case .missingAPR:
            guard let accountID = recommendation.targetAccountID else {
                return (recommendation.destination.appSection, nil, nil)
            }
            return (.accountDetail, accountID, .apr)
        case .missingMinimumPayments:
            guard let accountID = recommendation.targetAccountID else {
                return (recommendation.destination.appSection, nil, nil)
            }
            return (.accountDetail, accountID, .paymentAmount)
        case .duplicateImports, .missingAccountMappings, .incompleteCashFlowSetup:
            return (recommendation.destination.appSection, recommendation.targetAccountID, nil)
        }
    }

    private func actionTitle(for recommendation: AssistantCleanupRecommendation) -> String {
        switch recommendation.kind {
        case .missingAPR:
            return recommendation.targetAccountID == nil ? "Open Liability Accounts" : "Open account APR"
        case .missingMinimumPayments:
            return recommendation.targetAccountID == nil ? "Open Liability Accounts" : "Open account payment"
        case .duplicateImports, .missingAccountMappings, .incompleteCashFlowSetup:
            return "Open \(recommendation.destination.title)"
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
            "DebtScope found \(summary.recommendationCount) cleanup recommendation(s)."
        ]

        let recommendations = summary.recommendations.prefix(5).map { recommendation in
            "\(recommendation.title): review \(recommendation.affectedRecordCount) item(s) in \(recommendation.destination.title). \(recommendation.expectedBenefit)"
        }
        appendSection("Recommended Reviews", items: recommendations, to: &lines)

        var notes = ["These are suggestions only; each change requires normal app confirmation."]
        if !summary.transactionLevelDetailAvailable {
            notes.append("Transaction-level detail is disabled, so import-related recommendations stay at count level.")
        }
        appendSection("Notes", items: notes, to: &lines)

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
                "To fix APRs in the app, go to Liability Accounts, choose the liability account, enter the APR from your statement in the APR field, and tap the checkmark or Done to confirm.",
                "Adding APRs improves avalanche ordering and projected interest totals."
            ]
        case .missingMinimumPayments:
            recommendationKind = .missingMinimumPayments
            cleanStateLine = "DebtScope doesn't show missing minimum-payment cleanup right now."
            guidanceLines = [
                "To fix minimum payments in the app, go to Liability Accounts, choose the liability account, enter the minimum payment from your statement in the Typical payment field, and tap the checkmark or Done to confirm.",
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
                "DebtScope shows \(recommendation.affectedRecordCount) item(s) to review for \(recommendation.title.lowercasedFirstLetter())."
            ]
        } else {
            lines = [cleanStateLine]
        }

        appendSection("How To Review", items: guidanceLines, to: &lines)
        appendSection("Notes", items: ["I can't make the change directly; it needs the normal app confirmation flow."], to: &lines)
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

        var lines = [
            "DebtScope shows \(bills.count) bill(s) due in the next 30 days."
        ]
        let billLines = bills.prefix(8).map { bill in
            let date = bill.dueDate.map { formatDate($0) } ?? "no due date"
            var line = "\(bill.name): \(formatCurrency(bill.amount, currencyCode: currencyCode)) due \(date)"
            if let fundingSourceName = bill.fundingSourceName {
                line += ", funded by \(fundingSourceName)"
            }
            return line
        }
        appendSection("Upcoming Bills", items: billLines, to: &lines)
        return lines.joined(separator: "\n")
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
                ? "An extra \(formatCurrency(requestedAmount, currencyCode: summary.currencyCode)) monthly debt payment appears to fit the current budget context."
                : "An extra \(formatCurrency(requestedAmount, currencyCode: summary.currencyCode)) monthly debt payment does not appear to fit the current budget context."
        ]

        appendSection("Cash Flow", items: [
            "Reserve-adjusted amount available for debt: \(formatCurrency(available, currencyCode: summary.currencyCode))",
            "Recurring monthly income: \(formatCurrency(summary.monthlyIncome, currencyCode: summary.currencyCode))",
            "Recurring monthly bills: \(formatCurrency(summary.monthlyBills, currencyCode: summary.currencyCode))"
        ], to: &lines)

        var notes = ["This is a DebtScope planning estimate, not financial advice."]
        notes.append(contentsOf: summary.missingDataNotes.prefix(3))
        appendSection("Notes", items: notes, to: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendSection(_ title: String, items: [String], to lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("")
        lines.append(title)
        lines.append(contentsOf: items.map { "- \($0)" })
    }

    private func appendNotes(_ notes: [String], to lines: inout [String], limit: Int = 3) {
        appendSection("Notes", items: Array(notes.prefix(limit)), to: &lines)
    }

    private func appendPrivacyNoteIfNeeded(to notes: inout [String], summary: AssistantImportReviewSummary) {
        if !summary.transactionLevelDetailAvailable {
            notes.append("Transaction-level detail is disabled, so this answer stays at count level.")
        }
    }

    private func missingDataResponse(_ lead: String, notes: [String]) -> String {
        var lines = [lead]
        appendSection("Missing Data", items: Array(notes.prefix(3)), to: &lines)
        return lines.joined(separator: "\n")
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

    func lowercasedFirstLetter() -> String {
        guard !isEmpty else { return "" }
        return prefix(1).lowercased() + dropFirst()
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
