import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct GetDebtSummaryTool: Tool {
    let name = "get_debt_summary"
    let description = "Get current debt balances, APRs, minimum payments, payoff dates, and missing debt data notes."

    private let serviceBox: DebtScopeAssistantToolServiceBox

    @MainActor
    init(service: DebtScopeAssistantService) {
        self.serviceBox = DebtScopeAssistantToolServiceBox(service: service)
    }

    @Generable
    struct Arguments {
        @Guide(description: "True when the user asks about debt totals, balances, APRs, minimums, payoff priority, or missing debt setup data.")
        let includeDetails: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            return try await MainActor.run {
                let summary = try serviceBox.service.debtSummary()
                return try DebtScopeAssistantToolEncoding.encode(summary)
            }
        } catch {
            await DebtScopeAssistantToolEncoding.logFailure(toolName: name, error: error)
            throw error
        }
    }
}

@available(iOS 26.0, *)
struct GetCashFlowSummaryTool: Tool {
    let name = "get_cash_flow_summary"
    let description = "Get income, bills, recurring net, non-monthly income spread, reserve-adjusted budget, and near-term bill context."

    private let serviceBox: DebtScopeAssistantToolServiceBox

    @MainActor
    init(service: DebtScopeAssistantService) {
        self.serviceBox = DebtScopeAssistantToolServiceBox(service: service)
    }

    @Generable
    struct Arguments {
        @Guide(description: "Number of months to summarize. Use 12 unless the user asks for a shorter or longer period. Clamped to 1 through 24.")
        let months: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let months = DebtScopeAssistantToolEncoding.clamp(arguments.months ?? 12, to: 1...24)
            return try await MainActor.run {
                let summary = try serviceBox.service.cashFlowSummary(months: months)
                return try DebtScopeAssistantToolEncoding.encode(summary)
            }
        } catch {
            await DebtScopeAssistantToolEncoding.logFailure(toolName: name, error: error)
            throw error
        }
    }
}

@available(iOS 26.0, *)
struct GetUpcomingBillsTool: Tool {
    let name = "get_upcoming_bills"
    let description = "Get compact summaries of bills due soon, including amount, due date, frequency, account, reserve balance, and funding source when available."

    private let serviceBox: DebtScopeAssistantToolServiceBox

    @MainActor
    init(service: DebtScopeAssistantService) {
        self.serviceBox = DebtScopeAssistantToolServiceBox(service: service)
    }

    @Generable
    struct Arguments {
        @Guide(description: "Number of days ahead to search for bills. Use 30 unless the user asks for a different range. Clamped to 1 through 90.")
        let days: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let days = DebtScopeAssistantToolEncoding.clamp(arguments.days ?? 30, to: 1...90)
            return try await MainActor.run {
                let summaries = try serviceBox.service.upcomingBills(days: days)
                return try DebtScopeAssistantToolEncoding.encode(summaries)
            }
        } catch {
            await DebtScopeAssistantToolEncoding.logFailure(toolName: name, error: error)
            throw error
        }
    }
}

@available(iOS 26.0, *)
struct GetPayoffPlanTool: Tool {
    let name = "get_payoff_plan"
    let description = "Get DebtScope's current payoff plan, payoff order, projected dates, interest, and budget source."

    private let serviceBox: DebtScopeAssistantToolServiceBox

    @MainActor
    init(service: DebtScopeAssistantService) {
        self.serviceBox = DebtScopeAssistantToolServiceBox(service: service)
    }

    @Generable
    struct Arguments {
        @Guide(description: "Optional payoff plan start date as YYYY-MM-DD. Leave empty unless the user asks for another start date.")
        let startDate: String?
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let startDate = DebtScopeAssistantToolEncoding.date(from: arguments.startDate) ?? Date()
            return try await MainActor.run {
                let summary = try serviceBox.service.payoffPlanSummary(startDate: startDate)

                guard let summary else {
                    return "{\"payoffPlanAvailable\":false,\"reason\":\"DebtScope could not compute a payoff plan with the current debt and payoff settings.\"}"
                }

                return try DebtScopeAssistantToolEncoding.encode(summary)
            }
        } catch {
            await DebtScopeAssistantToolEncoding.logFailure(toolName: name, error: error)
            throw error
        }
    }
}

@available(iOS 26.0, *)
struct ComparePayoffStrategiesTool: Tool {
    let name = "compare_payoff_strategies"
    let description = "Compare DebtScope's minimum-payment, avalanche, and snowball payoff strategies, including total interest, feasibility, payoff order, projected debt-free dates, avalanche interest savings, and missing input notes."

    private let serviceBox: DebtScopeAssistantToolServiceBox

    @MainActor
    init(service: DebtScopeAssistantService) {
        self.serviceBox = DebtScopeAssistantToolServiceBox(service: service)
    }

    @Generable
    struct Arguments {
        @Guide(description: "Optional comparison start date as YYYY-MM-DD. Leave empty unless the user asks for another start date.")
        let startDate: String?
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let startDate = DebtScopeAssistantToolEncoding.date(from: arguments.startDate) ?? Date()
            return try await MainActor.run {
                let summary = try serviceBox.service.payoffStrategyComparison(startDate: startDate)

                guard let summary else {
                    return "{\"strategyComparisonAvailable\":false,\"reason\":\"DebtScope could not compare avalanche and snowball with the current debt and payoff settings.\"}"
                }

                return try DebtScopeAssistantToolEncoding.encode(summary)
            }
        } catch {
            await DebtScopeAssistantToolEncoding.logFailure(toolName: name, error: error)
            throw error
        }
    }
}

@available(iOS 26.0, *)
struct SimulateExtraDebtPaymentTool: Tool {
    let name = "simulate_extra_debt_payment"
    let description = "Simulate adding an extra monthly debt payment without saving payoff settings, returning baseline versus scenario interest, payoff timing, and first affected debt."

    private let serviceBox: DebtScopeAssistantToolServiceBox

    @MainActor
    init(service: DebtScopeAssistantService) {
        self.serviceBox = DebtScopeAssistantToolServiceBox(service: service)
    }

    @Generable
    struct Arguments {
        @Guide(description: "Extra monthly debt payment amount. Must be zero or greater and realistic.")
        let extraMonthlyPayment: Double?

        @Guide(description: "Strategy to use when applying extra payments. Use minimums, avalanche, or snowball. Do not leave empty when the user asks for an extra-payment simulation.")
        let extraPaymentStrategy: String?

        @Guide(description: "Optional simulation start date as YYYY-MM-DD. Leave empty unless the user asks for another start date.")
        let startDate: String?
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let startDate = DebtScopeAssistantToolEncoding.date(from: arguments.startDate) ?? Date()
            let extraMonthlyPayment = NSDecimalNumber(value: arguments.extraMonthlyPayment ?? -1).decimalValue
            return try await MainActor.run {
                let summary = try serviceBox.service.extraPaymentSimulation(
                    extraMonthlyPayment: extraMonthlyPayment,
                    startDate: startDate,
                    scenarioStrategy: extraPaymentStrategy(from: arguments.extraPaymentStrategy)
                )
                return try DebtScopeAssistantToolEncoding.encode(summary)
            }
        } catch {
            await DebtScopeAssistantToolEncoding.logFailure(toolName: name, error: error)
            throw error
        }
    }

    private func extraPaymentStrategy(from value: String?) -> AssistantPayoffStrategy? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "minimum", "minimums", "minimumsonly", "minimums_only", "minimum payments", "minimum payment":
            return .minimumsOnly
        case "avalanche":
            return .avalanche
        case "snowball":
            return .snowball
        default:
            return nil
        }
    }
}

@available(iOS 26.0, *)
struct GetImportReviewSummaryTool: Tool {
    let name = "get_import_review_summary"
    let description = "Get count-level summaries of recent imports, duplicate candidates, conflicts, and account mapping issues without exposing raw file contents, hashes, memos, or persistent identifiers."

    private let serviceBox: DebtScopeAssistantToolServiceBox

    @MainActor
    init(service: DebtScopeAssistantService) {
        self.serviceBox = DebtScopeAssistantToolServiceBox(service: service)
    }

    @Generable
    struct Arguments {
        @Guide(description: "Number of recent imports to summarize. Use 5 unless the user asks for a different count. Clamped to 1 through 10.")
        let recentLimit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        do {
            let recentLimit = DebtScopeAssistantToolEncoding.clamp(arguments.recentLimit ?? 5, to: 1...10)
            return try await MainActor.run {
                let summary = try serviceBox.service.importReviewSummary(recentLimit: recentLimit)
                return try DebtScopeAssistantToolEncoding.encode(summary)
            }
        } catch {
            await DebtScopeAssistantToolEncoding.logFailure(toolName: name, error: error)
            throw error
        }
    }
}

@available(iOS 26.0, *)
struct DebtScopeAssistantToolFactory {
    @MainActor
    static func debtAndPayoffTools(service: DebtScopeAssistantService) -> [any Tool] {
        [
            GetDebtSummaryTool(service: service),
            GetCashFlowSummaryTool(service: service),
            GetUpcomingBillsTool(service: service),
            GetPayoffPlanTool(service: service),
            ComparePayoffStrategiesTool(service: service),
            SimulateExtraDebtPaymentTool(service: service),
            GetImportReviewSummaryTool(service: service)
        ]
    }
}

@available(iOS 26.0, *)
private final class DebtScopeAssistantToolServiceBox: @unchecked Sendable {
    @MainActor let service: DebtScopeAssistantService

    @MainActor
    init(service: DebtScopeAssistantService) {
        self.service = service
    }
}

private enum DebtScopeAssistantToolEncoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func date(from value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: value)
    }

    nonisolated static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    @MainActor
    static func logFailure(toolName: String, error: Error) {
        AMLogging.error(
            "Assistant tool failed name=\(toolName) errorType=\(String(describing: type(of: error)))",
            component: "DebtScopeAssistantTools"
        )
    }
}
#endif
