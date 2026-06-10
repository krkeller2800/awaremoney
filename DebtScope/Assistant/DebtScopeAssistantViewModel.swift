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
        responseTask = Task { [weak self] in
            guard let self else { return }

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
                AMLogging.error("Assistant response failed: \(error.localizedDescription)", component: "DebtScopeAssistantViewModel")
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
