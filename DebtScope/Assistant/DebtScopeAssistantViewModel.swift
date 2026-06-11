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
        switch AssistantPromptIntent(prompt: prompt) {
        case .debtPicture:
            return try formatDebtPicture(service.debtSummary())
        case .payoffFocus:
            return try formatPayoffFocus(service.payoffPlanSummary(startDate: Date()))
        case .strategySavings:
            let startDate = Date()
            do {
                return try formatStrategySavings(
                    service.payoffStrategyComparison(startDate: startDate),
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

        var lines = [
            "Using avalanche instead of snowball saves \(formatCurrency(summary.interestSavingsUsingAvalanche, currencyCode: summary.currencyCode)) in projected interest.",
            "Avalanche interest: \(formatCurrency(summary.avalanche.totalInterest, currencyCode: summary.currencyCode)).",
            "Snowball interest: \(formatCurrency(summary.snowball.totalInterest, currencyCode: summary.currencyCode)).",
            "Minimum-payment interest: \(formatCurrency(summary.minimumPayments.totalInterest, currencyCode: summary.currencyCode))."
        ]
        if !summary.avalanche.paymentFeasible || !summary.snowball.paymentFeasible || !summary.minimumPayments.paymentFeasible {
            lines.append("At least one strategy is not feasible with the current setup.")
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
