# Codex Handoff

## Current Focus
- Internal DebtScope Assistant implementation is following `DebtScope/DebtScope/Docs/addAIAssistant.md`.
- Steps 1-4 are complete: assistant settings, assistant-safe `Codable` contracts, read-only SwiftData service summaries for debt/payoff, Foundation Models availability handling, and fallback UI are in place.
- Step 5 slice is complete: the initial four scoped Foundation Models tools now exist for debt summary, cash-flow summary, upcoming bills, and payoff plan.

## Completed This Checkpoint
- `DebtScope/DebtScope/Assistant/DebtScopeAssistantService.swift`
  - Added `cashFlowSummary(months:)` with defensive 1...24 month clamping.
  - Added `upcomingBills(days:)` with defensive 1...90 day clamping and compact output capped at 30 bills.
  - Reused existing app logic from `IncomeScheduler`, `PlanBudgetDisplay`, `BillReservePlanner`, and `SocialSecuritySchedule` instead of duplicating planning math.
  - Included recurring income, recurring bills, recurring net, non-monthly income monthly average, reserve-adjusted debt budget, upcoming bill context, funding source names, reserve balances, and missing setup notes.
  - Added frequency-aware upcoming due-date handling for weekly, biweekly, semimonthly, Social Security, monthly, quarterly, semiannual, yearly, and one-time bills.
- `DebtScope/DebtScope/Assistant/DebtScopeAssistantTools.swift`
  - Added `GetCashFlowSummaryTool` for income, bills, recurring net, non-monthly income spread, reserve-adjusted budget, and affordability context.
  - Added `GetUpcomingBillsTool` for bills due soon.
  - Added shared argument clamping for integer tool ranges.
  - Updated `DebtScopeAssistantToolFactory.debtAndPayoffTools(service:)` to return the four initial Step 5 tools: debt summary, cash-flow summary, upcoming bills, and payoff plan.
  - Kept Foundation Models code behind `canImport(FoundationModels)` and iOS 26 availability, with service calls, JSON encoding, and failure logging isolated through the main actor.

## Validation
- Live diagnostics reported no issues for `DebtScopeAssistantService.swift`.
- Live diagnostics reported no issues for `DebtScopeAssistantTools.swift`.
- Full Xcode project build succeeded after the cash-flow/upcoming-bills changes.
- Xcode test discovery still reports `0 tests` in the active `DebtScope` test plan, so automated tests cannot currently be run through the active plan.

## Known Constraints / Risks
- Apple Intelligence/Foundation Models behavior cannot be fully validated in the iOS Simulator; simulator validation should focus on fallback/service behavior.
- Real model availability, tool invocation behavior, and model-ready states must be validated on Apple Intelligence-capable physical hardware with Apple Intelligence enabled.
- Active Xcode test plan currently discovers zero tests; fix test discovery/target configuration before relying on automated test runs for assistant service, tool, or UI coverage.
- The assistant still does not create a `LanguageModelSession`, define model instructions, or present a chat UI.

## Recommended Next Step
- Proceed to Step 6 in `addAIAssistant.md`: define concise model instructions for the in-app assistant.
- After instructions are in place, continue toward creating the assistant view model/session wiring and chat UI.
