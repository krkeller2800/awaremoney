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
struct DebtScopeAssistantToolFactory {
    @MainActor
    static func debtAndPayoffTools(service: DebtScopeAssistantService) -> [any Tool] {
        [
            GetDebtSummaryTool(service: service),
            GetPayoffPlanTool(service: service)
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

    @MainActor
    static func logFailure(toolName: String, error: Error) {
        AMLogging.error("Assistant tool failed name=\(toolName): \(error.localizedDescription)", component: "DebtScopeAssistantTools")
    }
}
#endif
