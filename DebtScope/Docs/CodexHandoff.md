# Codex Handoff

## Current Focus
- Sensitive Spotlight indexing was expanded behind the existing `Allow financial details in Spotlight` master toggle.
- The user is testing on a real iOS device.
- Spotlight financial results are intentionally label-only: no amounts, balances, due dates, transaction dates, memos, notes, account numbers, hashes, import filenames, or raw record details.

## Completed This Session
- Added `DebtScopeSpotlightIndexingOptions` and separate settings for Spotlight financial result categories:
  - account names
  - bill names
  - transaction payees
  - debt and payoff names
- Updated Settings > Data & Privacy to show the category toggles only as subordinate options under the master financial Spotlight toggle.
- Expanded `DebtScopeSpotlightIndexer` to index selected label-only financial results in the sensitive Spotlight domain.
- Transaction payee Spotlight entries are deduplicated by normalized payee so repeated merchants do not flood Spotlight.
- Added separate Spotlight identifier prefixes for accounts, bills, transaction payees, and debt/payoff results.
- Updated `QuickStartView` Spotlight continuation routing:
  - generic sections still route to their existing app sections
  - account results route to the relevant account area
  - bill results route to Income & Bills
  - transaction payee results route through the linked account when available, otherwise Cash Flow
  - debt/payoff results route to Liability Accounts with the liability selected
- Kept generic navigation-only app section indexing intact.

## Latest Validation
- Live diagnostics were clean for:
  - `DebtScope/DebtScope/Assistant/DebtScopeSpotlightIndexer.swift`
  - `DebtScope/DebtScope/View/QuickStartView.swift`
  - `DebtScope/DebtScope/Models/SettingsStore.swift`
  - `DebtScope/DebtScope/Utils/SettingsView.swift`
- Full Xcode project build succeeded after the expanded Spotlight implementation.

## Privacy / Scope Rules
- Default behavior remains generic app-section Spotlight results only unless the master financial details toggle is enabled.
- Financial Spotlight results expose labels only.
- Do not add amounts, balances, dates, memos, notes, account numbers, import filenames, hashes, or raw database identifiers to Spotlight result text.
- Do not add write-capable AI/App Intent workflows without a confirmed normal app UI workflow and audit trail.
- Keep transaction-level assistant work aggregated by default and gated by `assistantIncludeTransactions` plus an explicit user request.

## Known Notes / Risks
- Transaction payee indexing currently fetches transactions only when that Spotlight category is enabled; it is not held as a persistent root query.
- Bill names are driven by the root `CashFlowItem` query in `QuickStartView`, so bill label changes should refresh while QuickStart is active.
- Real-device Spotlight behavior may lag indexing updates because iOS Spotlight can cache and refresh asynchronously.

## Recommended Next Step
- On the real iOS device, verify each Settings combination:
  - master toggle off clears sensitive results
  - account names appear only when account names are enabled
  - bill names appear only when bill names are enabled
  - transaction payees appear only when transaction payees are enabled
  - debt/payoff names appear only when debt/payoff names are enabled
- If real-device testing behaves correctly, commit the Spotlight/settings changes.
