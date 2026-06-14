# Codex Handoff

## Current Focus
- Enhanced in-app search is complete and remains entirely inside DebtScope.
- App Shortcuts and Spotlight indexing are privacy-first and navigation-only by default.
- The assistant remains read-only and privacy-first.

## Completed Recently
- Added navigation-only App Intents and App Shortcuts for Debt Summary, Upcoming Bills, Assistant, and Debt Payoff Plan.
- Added generic Core Spotlight indexing for the same app sections via `DebtScopeSpotlightIndexer`.
- Spotlight result continuation routes back into `QuickStartView` using the existing app-section routing path.
- Added a Settings preference: `Allow financial details in Spotlight`.
- Generic app sections are indexed by default. Sensitive financial Spotlight indexing remains gated by the preference and no sensitive financial indexer has been implemented yet.
- Reordered Data & Privacy settings so the assistant hint sits under assistant preferences.
- Added reset-data explanatory copy under `Reset App Data`.
- Added a dedicated read-only `DebtPayoffPlanView` and routed the Debt Payoff Plan shortcut to it.
- Renamed the old Debt Payoff setup/list destination to Liability Accounts and renamed QuickStart Money Flow to Cash Flow.
- Added QuickStart toolbar in-app search across accounts, transactions, and balances.

## Latest Validation
- Full Xcode project build succeeded after Spotlight/indexing implementation.
- Live diagnostics were clean for `DebtScope/DebtScope/Assistant/DebtScopeSpotlightIndexer.swift`.
- Live diagnostics were clean for `DebtScope/DebtScope/Utils/SettingsView.swift` after the settings text adjustments.

## Known Constraints / Risks
- Do not expose transaction keywords, balances, account names, import filenames, payoff amounts, payoff dates, or transaction details to system search without a separate privacy review and explicit user opt-in.
- The new Spotlight preference is only a gate for future sensitive indexing; current indexing remains generic app sections only.
- Do not add write-capable AI/App Intent workflows without a confirmed normal app UI workflow and audit trail.
- Keep transaction-level assistant work aggregated by default and gated by `assistantIncludeTransactions` plus an explicit user request.
- In-app search still uses straightforward localized substring matching, not fuzzy matching.

## Recommended Next Step
- Commit the completed Spotlight/settings checkpoint.
- If continuing search work, the next increment should be either fuzzy matching inside the app or implementing sensitive Spotlight/App Entity indexing behind the completed privacy gate, after explicit user approval for the exact financial data types to expose.
