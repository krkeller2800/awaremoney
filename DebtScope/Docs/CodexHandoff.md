# Codex Handoff

## Current Focus
- Fuzzy matching inside DebtScope in-app search is implemented, smoke tested, and ready to commit if it has not already been committed.
- The assistant remains read-only, privacy-first, and on-device only. There is no off-device AI fallback.
- The prior handoff's "next privacy-scoped assistant/App Intent improvement" was too vague. The recommended next product direction is now Assistant Action Routing.

## Completed / Verified Context
- `DebtScopeFuzzySearch` exists in `DebtScope/Utils/DebtScopeFuzzySearch.swift`.
- `AccountSearchView` in `QuickStartView` uses the shared fuzzy matcher for account, transaction, and balance result groups.
- Focused fuzzy-search tests passed: 4 passed, 0 failed.
- Full Xcode project build passed after the fuzzy-search work.
- Assistant tooling is already broader than the old plan implied: debt summary, cash flow, upcoming bills, payoff plan, strategy comparison, extra-payment simulation, import review, and cleanup recommendations are present.
- Navigation-only App Shortcuts and Spotlight section routing already exist.
- Sensitive Spotlight labels for accounts, bills, transaction payees, and debt payoff items can route back into the app when the user enables the financial-details indexing toggles.

## Next Step
Build Assistant Action Routing instead of adding another assistant data tool.

The next implementer should:
- Convert assistant cleanup/import recommendation destinations from plain strings into structured, privacy-safe app destinations.
- Reuse existing QuickStart routing so recommendations can open the relevant normal app screen:
  - Missing APR / minimum payment -> Liability Accounts.
  - Incomplete bill or income schedules -> Income & Bills.
  - Duplicate imports / account mapping issues -> Statement Review or the existing import review workflow when available.
- Add assistant suggested prompts for the newer capabilities:
  - `What should I clean up next?`
  - `Compare avalanche and snowball`
  - `What changed after my latest import?`
  - `What if I add $100 avalanche?`
- Keep all routing navigation-only. Any data change must still happen through the normal app UI with user confirmation.

## Privacy / Scope Rules
- Do not add write-capable AI/App Intent workflows without a confirmed normal app UI workflow and audit trail.
- Keep App Intents narrow and navigation-focused. Do not return balances, dates, account details, transaction details, or import content through Siri or Shortcuts.
- Financial Spotlight results must expose labels only.
- Do not add amounts, balances, dates, memos, notes, account numbers, import filenames, hashes, or raw database identifiers to Spotlight result text.
- Keep transaction-level assistant work aggregated by default and gated by `assistantIncludeTransactions` plus an explicit user request.
- Assistant copy should continue to state that AI use is on-device only and that unavailable Apple Intelligence means the assistant stays unavailable.

## Useful Starting Points
- `DebtScope/Assistant/DebtScopeAssistantService.swift`: `cleanupRecommendationSummary()` currently emits text destinations.
- `DebtScope/Assistant/DebtScopeAssistantModels.swift`: `AssistantCleanupRecommendation` currently stores `destination` as `String`.
- `DebtScope/Assistant/DebtScopeAssistantViewModel.swift`: formats direct assistant responses and can surface action-oriented copy.
- `DebtScope/Assistant/DebtScopeAssistantView.swift`: suggested prompts are currently older and should be refreshed.
- `DebtScope/View/QuickStartView.swift`: existing section, Spotlight, account, bill, transaction, and debt-payoff routing should be reused.
- `DebtScope/Assistant/DebtScopeAppIntents.swift`: keep App Intent behavior navigation-only.

## Notes / Risks
- Avoid expanding system surfaces with sensitive financial data; the valuable next improvement is making existing assistant recommendations actionable inside DebtScope.
- Duplicate/mapping recommendations may not always have an active persisted review item. Route gracefully to Statement Review when available, otherwise explain that the issue is resolved during the next import review.
- After significant complete changes, remind the user to make a git commit.
