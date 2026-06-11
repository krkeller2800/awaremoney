# Add Internal DebtScope Assistant

## Goal

Add an in-app DebtScope assistant that uses Apple's Foundation Models framework to answer user questions about their DebtScope data. The assistant should run inside DebtScope, use on-device model capabilities when available, and access app data only through explicit Swift tool calls that return scoped summaries from SwiftData.

The assistant must not give the model broad database access, raw store-file access, or full backup exports by default. Each answer should be grounded in small, purpose-built summaries produced by DebtScope code.

## Product Shape

The first version should be a read-only financial explainer, not an autonomous data editor.

It should answer questions like:

- What is my current debt picture?
- Which debt should I focus on first?
- What bills are coming up soon?
- Can I afford to add a specific amount to monthly debt payments?
- Why did DebtScope choose this payoff order?
- What changed after my latest import?
- What accounts or transactions need review?

It should avoid:

- Moving money, deleting data, or editing accounts without a separate confirmed workflow.
- Giving regulated financial advice as certainty.
- Sending data to a network model unless a separate opt-in cloud feature is explicitly designed later.

## High-Level Architecture

Use this flow:

1. User opens an Assistant view inside DebtScope.
2. User asks a question.
3. `DebtScopeAssistantViewModel` sends the question to a `LanguageModelSession`.
4. The session has instructions that define the assistant's scope, tone, privacy rules, and limitations.
5. The session is configured with a small set of Foundation Models tools.
6. When the model needs app data, it calls one of those tools.
7. Each tool calls a Swift service that fetches only the needed SwiftData records through `ModelContext`.
8. The service returns a compact, Codable summary.
9. The model explains the summary in plain language.
10. The UI displays the response and, when useful, source notes such as "Based on 4 debt accounts and the current payoff settings."

## Proposed Files

Add a new assistant feature folder:

- `DebtScope/DebtScope/Assistant/DebtScopeAssistantView.swift`
- `DebtScope/DebtScope/Assistant/DebtScopeAssistantViewModel.swift`
- `DebtScope/DebtScope/Assistant/DebtScopeAssistantService.swift`
- `DebtScope/DebtScope/Assistant/DebtScopeAssistantModels.swift`
- `DebtScope/DebtScope/Assistant/DebtScopeAssistantTools.swift`
- `DebtScope/DebtScope/Assistant/DebtScopeAssistantAvailabilityView.swift`

Optional later files:

- `DebtScope/DebtScope/Assistant/DebtScopeAssistantHistoryStore.swift`
- `DebtScope/DebtScope/Testing/DebtScopeAssistantServiceTests.swift`
- `DebtScope/DebtScope/Testing/DebtScopeAssistantToolTests.swift`

## Step 1: Add a Feature Flag and Setting

Add settings to `SettingsStore`:

- `assistantEnabled`
- `assistantIncludeTransactions`
- `assistantRetainConversationHistory`

Suggested defaults:

- `assistantEnabled`: `false` for first internal builds, `true` only after validation.
- `assistantIncludeTransactions`: `false` unless the user enables it or confirms per question.
- `assistantRetainConversationHistory`: `false` for privacy-first behavior.

Add a section to `SettingsView` under Data & Privacy:

- Toggle: "DebtScope Assistant"
- Toggle: "Allow transaction details"
- Toggle: "Keep assistant history"
- Short explanation that the assistant uses on-device Apple Intelligence when available and only receives scoped summaries.

## Step 2: Define the Assistant Data Contracts

Create `DebtScopeAssistantModels.swift` with small Codable structs that are safe to pass to the model.

Recommended summaries:

- `AssistantDebtSummary`
- `AssistantDebtAccountSummary`
- `AssistantCashFlowSummary`
- `AssistantUpcomingBillSummary`
- `AssistantPayoffPlanSummary`
- `AssistantNetWorthSummary`
- `AssistantImportSummary`
- `AssistantTransactionPatternSummary`

Keep the structs compact. Do not expose internal SwiftData objects directly.

Example shape:

```swift
struct AssistantDebtSummary: Codable, Sendable {
    let generatedAt: Date
    let currencyCode: String
    let debtCount: Int
    let totalDebt: Decimal
    let totalMinimumPayment: Decimal
    let highestAPRDebtName: String?
    let highestAPR: Decimal?
    let accounts: [AssistantDebtAccountSummary]
}
```

Use display-safe fields:

- Account name
- Account type
- Latest balance
- APR
- Minimum payment
- Payoff date when available

Avoid unnecessary fields:

- Persistent model IDs
- Raw transaction hashes
- Import hash keys
- Full memo text unless the user explicitly asks for transaction detail
- Backup DTOs

## Step 3: Build a SwiftData Query Service

Create `DebtScopeAssistantService.swift` as a `@MainActor` service that owns no global state and receives dependencies explicitly:

```swift
@MainActor
final class DebtScopeAssistantService {
    private let context: ModelContext
    private let settings: SettingsStore

    init(context: ModelContext, settings: SettingsStore) {
        self.context = context
        self.settings = settings
    }
}
```

Add read-only methods:

- `debtSummary() throws -> AssistantDebtSummary`
- `cashFlowSummary(months: Int) throws -> AssistantCashFlowSummary`
- `upcomingBills(days: Int) throws -> [AssistantUpcomingBillSummary]`
- `payoffPlanSummary(startDate: Date) throws -> AssistantPayoffPlanSummary?`
- `netWorthSummary() throws -> AssistantNetWorthSummary`
- `recentTransactionPatterns(days: Int, limit: Int) throws -> AssistantTransactionPatternSummary`

Reuse existing app logic where possible:

- Use `PayoffPlanProvider` for payoff calculations.
- Use `IncomeScheduler` and `PlanBudgetDisplay` for budget/cash-flow calculations.
- Use existing latest-balance query patterns from `PayoffPlanProvider`, `NetWorthView`, and chart views.
- Use `CashFlowItem` and `BillFundingAllocation` for income/bill context.

Do not duplicate payoff math inside the assistant. The assistant should explain DebtScope's calculations, not create a second planning engine.

## Step 4: Add Foundation Models Availability Handling

Create an availability layer before showing the assistant.

Use Foundation Models concepts:

- `SystemLanguageModel.default`
- `SystemLanguageModel.Availability`
- `LanguageModelSession`

Handle unavailable cases clearly:

- Device does not support Apple Intelligence.
- Apple Intelligence is disabled.
- The model is still downloading or not ready.
- Unknown unavailability.

The UI should show a normal unavailable state, not crash or hide the feature silently.

## Step 5: Create Tool Calls for Scoped Data Access

Create `DebtScopeAssistantTools.swift` with Foundation Models tools that call `DebtScopeAssistantService`.

Start with four tools:

1. `GetDebtSummaryTool`
   - Use for questions about debt balances, APRs, minimums, payoff priority, and debt totals.

2. `GetCashFlowSummaryTool`
   - Use for questions about income, bills, recurring net, non-monthly income, reserve-adjusted budget, and affordability.

3. `GetUpcomingBillsTool`
   - Use for questions about bills due soon.
   - Inputs: `days`, clamped to a safe range such as 1...90.

4. `GetPayoffPlanTool`
   - Use for questions about payoff order, payoff dates, interest, and strategy comparisons.
   - Start with current default strategy. Add strategy comparison later.

Tool rules:

- Clamp all ranges and limits.
- Return summaries, not raw model objects.
- Mark missing data explicitly, such as missing APR or missing payment amount.
- Keep results small enough for the model context window.
- Log tool failures with `AMLogging`, but do not log sensitive financial details.

## Step 6: Write the Model Instructions

Create a single assistant instruction string in `DebtScopeAssistantViewModel` or a small helper.

The instructions should say:

- You are DebtScope's in-app assistant.
- Use tools for current app data; do not invent balances, bills, dates, APRs, or payoff results.
- Explain calculations in plain language.
- When data is missing, say what is missing.
- Do not claim to be a financial advisor.
- Do not recommend irreversible actions.
- If the user asks to change data, explain what can be reviewed and require an app confirmation flow.
- Keep responses concise unless the user asks for detail.

Avoid putting user-imported data or transaction text in the high-priority instructions. Only pass user data through tool results or prompts.

## Step 7: Build the Assistant View Model

Create `DebtScopeAssistantViewModel.swift` as an observable object.

Responsibilities:

- Track messages.
- Track current input.
- Track loading/error state.
- Create and hold a `LanguageModelSession` when available.
- Send user prompts.
- Receive streamed or final responses.
- Reset the session when needed.
- Avoid retaining history if `assistantRetainConversationHistory` is false.

Suggested message model:

```swift
struct AssistantMessage: Identifiable, Hashable {
    enum Role { case user, assistant, systemNotice }
    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
}
```

Start with simple final responses. Add streaming after the basic tool loop is stable.

## Step 8: Build the SwiftUI Assistant UI

Create `DebtScopeAssistantView.swift`.

The first version should include:

- A navigation title: "Assistant"
- Message list
- Text input
- Send button
- Stop/reset button if generation is active
- Availability/unavailable state
- Privacy notice for first launch
- Suggested prompt chips, such as:
  - "Summarize my debts"
  - "What bills are due soon?"
  - "Can I pay extra this month?"
  - "Explain my payoff plan"

Keep the UI work-focused and compact. This is an app tool, not a marketing page.

## Step 9: Add an Entry Point

Integrate the assistant from `QuickStartView`.

Recommended entry point:

- Add an "Assistant" utility item near Settings, Backup, and Help.
- Present `DebtScopeAssistantView` as a sheet or navigation destination.
- Pass `modelContext` and `settings` through environment like the rest of the app.

If the assistant is behind a feature flag, hide or disable the entry point based on `settings.assistantEnabled`.

## Step 10: Add Privacy and Safety Guardrails

Use these guardrails for version one:

- Read-only tools only.
- No raw full-database export to the prompt.
- No backup JSON passed into the model.
- No transaction-level tool unless explicitly enabled.
- No persistent chat history unless explicitly enabled.
- No sensitive values in logs.
- Require app UI confirmation before any future write action.

For transaction summaries, aggregate first:

- Top merchants by spend
- Total spending by month
- Large transactions above a threshold
- Repeated charges

Only include individual transactions if the user asks and the setting allows it.

## Step 11: Add Tests

Add focused tests for the service layer before relying on model behavior.

Test cases:

- Empty data returns empty summaries instead of failures.
- Debt summary totals loan and credit-card balances only.
- Latest balance uses the newest non-excluded balance snapshot.
- Missing APR is represented as missing, not zero, unless the existing app calculation requires zero.
- Upcoming bills clamps date windows correctly.
- Payoff plan summary matches `PayoffPlanProvider` output.
- Transaction pattern summaries obey limits and exclusion rules.

Use the Swift Testing framework for service tests. Model session behavior can be smoke-tested manually because generated text is nondeterministic.

## Step 12: Validate Manually

Manual validation checklist:

- Build succeeds on the active Xcode scheme.
- Assistant unavailable state works on devices/simulators without Foundation Models availability.
- Assistant answers debt summary questions using real DebtScope data.
- Assistant explains missing data instead of inventing values.
- Assistant does not expose transaction detail while transaction access is disabled.
- Assistant handles an empty database gracefully.
- Assistant handles large import histories without context-window failures.
- Assistant does not log sensitive balances, payees, or memos.

Use Instruments later to inspect token use and model/tool performance once the first version works.

## Step 13: Rollout Plan

Recommended rollout sequence:

1. Internal debug-only assistant with debt summary and payoff plan tools.
2. Add cash-flow and upcoming-bill tools.
3. Add availability UI and settings controls.
4. Add service-layer tests.
5. Enable for TestFlight with read-only behavior.
6. Add transaction-pattern tool only after privacy controls are validated.
7. Consider App Intents later if the goal expands to Siri/Shortcuts access.

## Future Enhancements

Detailed implementation sequencing is tracked in `Assistant-Future-Enhancements-Implementation-Plan.md`.

After the read-only assistant is stable:

- Strategy comparison: avalanche vs snowball vs minimums.
- What-if simulations for extra monthly payments.
- Import review explanations from `ImportBatch`, statement classifier results, and conflicts.
- Suggested cleanup actions for duplicate imports or missing account mappings.
- App Intents for narrow actions like "Show my debt summary" or "Open upcoming bills."
- Spotlight/App Entity indexing for non-sensitive entities if useful.

Do not add write-capable AI tools until there is a clear confirmation UI and audit trail.

## Implementation Notes for This Project

Relevant existing files:

- `DebtScope/DebtScope/View/RootView.swift` injects app-level routing and presents `QuickStartView`.
- `DebtScope/DebtScope/View/QuickStartView.swift` owns the main app shell and utility sheets.
- `DebtScope/DebtScope/Utils/SettingsView.swift` is the place for privacy and assistant settings.
- `DebtScope/DebtScope/Models/SettingsStore.swift` stores user defaults backed settings.
- `DebtScope/DebtScope/Models/DebtScopeSchema.swift` lists SwiftData models.
- `DebtScope/DebtScope/Models/Account.swift` contains account type and loan term data.
- `DebtScope/DebtScope/Models/BalanceSnapshot.swift` contains dated balances and APR snapshots.
- `DebtScope/DebtScope/Models/CashFlowItem.swift` contains income and bill data.
- `DebtScope/DebtScope/Models/Transaction.swift` contains transaction data.
- `DebtScope/DebtScope/Debt/PayoffPlanProvider.swift` should be reused for payoff summaries.
- `DebtScope/DebtScope/Debt/DebtPayoffEngine.swift` should remain the canonical payoff calculation engine.

Main principle: keep the assistant as a thin natural-language layer over existing DebtScope services and calculations.
