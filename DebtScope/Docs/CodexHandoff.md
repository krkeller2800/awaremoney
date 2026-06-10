# Codex Handoff

## Current Focus
- Internal DebtScope Assistant implementation is following `DebtScope/DebtScope/Docs/addAIAssistant.md`.
- Steps 1-6 are complete: assistant settings, assistant-safe `Codable` contracts, read-only SwiftData service summaries, Foundation Models availability handling, the initial scoped Foundation Models tools, and concise model instructions are in place.

## Completed This Checkpoint
- `DebtScope/DebtScope/Assistant/DebtScopeAssistantInstructions.swift`
  - Added `DebtScopeAssistantInstructions.defaultInstructions` as the single reusable instruction string for the future `LanguageModelSession`.
  - Instructions define the assistant as DebtScope's in-app assistant, require tools for current app data, prohibit invented balances/bills/dates/APRs/payoff results, and keep answers grounded in tool results.
  - Instructions tell the assistant to explain missing data, stay concise, avoid claiming to be a financial advisor, avoid irreversible actions, and route data-changing requests through separate app confirmation flows.
  - Kept user-imported data and transaction text out of high-priority instructions.

## Validation
- Live diagnostics reported no issues for `DebtScopeAssistantInstructions.swift`.
- Full Xcode project build succeeded after adding the instructions helper.
- Active `DebtScope` test plan still discovers `0 tests`, so automated tests cannot currently be run through the active plan.

## Known Constraints / Risks
- Apple Intelligence/Foundation Models behavior cannot be fully validated in the iOS Simulator; simulator validation should focus on fallback/service behavior.
- Real model availability, tool invocation behavior, session behavior, and model-ready states must be validated on Apple Intelligence-capable physical hardware with Apple Intelligence enabled.
- Active Xcode test plan currently discovers zero tests; fix test discovery/target configuration before relying on automated test runs for assistant service, tool, view model, or UI coverage.
- The assistant still does not create a `LanguageModelSession`, send prompts, retain/reset conversation state, or present a chat UI.

## Recommended Next Step
- Proceed to Step 7 in `addAIAssistant.md`: create `DebtScopeAssistantViewModel.swift`.
- The view model should track messages/input/loading/error state, create a `LanguageModelSession` with `DebtScopeAssistantInstructions.defaultInstructions` and `DebtScopeAssistantToolFactory.debtAndPayoffTools(service:)` when available, send user prompts, receive final responses, reset sessions, and respect `assistantRetainConversationHistory`.
- Start with simple final responses before adding streaming.
