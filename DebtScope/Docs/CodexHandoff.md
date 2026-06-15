# Codex Handoff

## Current Focus
- Expanded sensitive Spotlight indexing is complete, verified on a real iOS device, and committed.
- Current uncommitted work is focused on Assistant discoverability/privacy UX, Settings consistency, and QuickStart cleanup.
- The assistant remains read-only, privacy-first, and on-device only. There is no off-device AI fallback.

## Completed And Committed
- Added `DebtScopeSpotlightIndexingOptions` and separate Settings categories for financial Spotlight results:
  - account names
  - bill names
  - transaction payees
  - debt and payoff names
- Updated Settings > Data & Privacy so Spotlight category toggles sit under the master `Allow financial details in Spotlight` toggle.
- Expanded `DebtScopeSpotlightIndexer` to index selected label-only financial results in the sensitive Spotlight domain.
- Deduplicated transaction payee Spotlight entries by normalized payee.
- Added Spotlight identifier prefixes for accounts, bills, transaction payees, and debt/payoff results.
- Updated `QuickStartView` Spotlight continuation routing for generic sections, accounts, bills, transaction payees, and debt/payoff results.
- User verified every Spotlight Settings combination on a real iOS device and committed the change.

## Current Uncommitted Changes
- Assistant discoverability:
  - QuickStart always shows the Assistant topic, even when the assistant is disabled.
  - Assistant App Shortcut/Spotlight routing no longer redirects away when the assistant is disabled.
  - The disabled Assistant banner now opens Assistant Settings instead of partially enabling the assistant directly.
- Assistant settings sheet:
  - Added a `gearshape` toolbar button in the Assistant screen.
  - The button opens a focused `Assistant Settings` sheet, not the general app Settings list.
  - The sheet contains Assistant on/off, transaction details, assistant history, availability status, and privacy notes.
- Assistant wording/privacy copy:
  - Copy now says the assistant uses on-device Apple Intelligence only.
  - Copy avoids implying an off-device AI fallback when Apple Intelligence is unavailable.
  - Simplified one assistant failure message to ask for a more specific prompt.
- Settings consistency:
  - Spotlight financial-detail child toggles now match the Assistant child-toggle pattern.
  - Turning off the Spotlight financial-details master switch clears all Spotlight category toggles.
  - On launch, Spotlight category toggles restore as enabled only when the master Spotlight financial-details toggle is enabled.
- QuickStart cleanup:
  - The `Review` section is hidden unless there are pending review items.
  - If the last review item is removed while `Needs Review` is selected, QuickStart routes back to Liability Accounts and clears that compact route.

## Latest Validation
- Live diagnostics were clean for recently modified files, including:
  - `DebtScope/DebtScope/Assistant/DebtScopeAssistantView.swift`
  - `DebtScope/DebtScope/Assistant/DebtScopeAssistantAvailability.swift`
  - `DebtScope/DebtScope/View/QuickStartView.swift`
  - `DebtScope/DebtScope/Models/SettingsStore.swift`
  - `DebtScope/DebtScope/Utils/SettingsView.swift`
- Full Xcode project build succeeded after the Assistant settings sheet, Settings consistency, wording, and QuickStart review-section changes.

## Privacy / Scope Rules
- Default Spotlight behavior remains generic app-section results only unless the master financial-details toggle is enabled.
- Financial Spotlight results expose labels only.
- Do not add amounts, balances, dates, memos, notes, account numbers, import filenames, hashes, or raw database identifiers to Spotlight result text.
- Do not add write-capable AI/App Intent workflows without a confirmed normal app UI workflow and audit trail.
- Keep transaction-level assistant work aggregated by default and gated by `assistantIncludeTransactions` plus an explicit user request.
- Assistant copy should continue to state that AI use is on-device only and that unavailable Apple Intelligence means the assistant stays unavailable.

## Known Notes / Risks
- Transaction payee Spotlight indexing fetches transactions only when that Spotlight category is enabled; it is not held as a persistent root query.
- Bill names are driven by the root `CashFlowItem` query in `QuickStartView`, so bill label changes refresh while QuickStart is active.
- iOS Spotlight can cache and refresh asynchronously on device, so newly changed labels may not appear instantly.

## Recommended Next Step
- Review the current uncommitted Assistant UX/Settings/QuickStart changes on device or simulator.
- If the Assistant settings sheet and QuickStart behavior look right, commit the pending changes.
