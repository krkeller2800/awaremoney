# Codex Handoff

## Current Focus
- Pricing strategy implementation is in progress.
- Paywall source modeling, Backup & Restore soft Premium upsell, local debug conversion diagnostics, lifetime paywall messaging refresh, and trial language cleanup are complete.
- User smoke tested the trial language/paywall presentation pass and committed the work.

## Completed / Verified Context
- Added `PaywallSource` as a lightweight source model for Premium/paywall presentations.
- Updated `PaywallView` to accept `source: PaywallSource = .unknown` and record DEBUG-only local conversion diagnostics.
- Wired known paywall sources for import limit, external import, Settings, About, QuickStart trial banner, and Backup & Restore.
- Added a soft Premium section to Backup & Restore while preserving free backup export, sharing, and restore access.
- Added DEBUG-only local conversion counters in `PurchaseManager`, backed by `UserDefaults`.
- Settings Developer section exposes a concise `Conversion Diagnostics` summary.
- Refreshed `PaywallView` copy around `Unlock Lifetime Premium`, broader local finance planning value, no subscription/ads/bank login, concise value bullets, and `Unlock Lifetime - {price}` button text.
- Added source-specific paywall messages for fifth import, external import, backup/restore, assistant, and payoff result.
- Updated trial/import allowance wording away from quota-only copy:
  - Active status uses `Trial active: {remaining} statement imports included` in shared status contexts.
  - Sidebar `TrialBanner` uses compact copy like `Trial: 4 statement imports` to avoid truncation.
  - Exhausted import gates use trial/lifetime wording and `Unlock Lifetime` CTAs.
- Updated `PaywallView` to present at the large detent only so the Premium paywall opens full height.
- No remote analytics were added.
- Lifetime product ID, free import allowance, entitlement behavior, StoreKit configuration, backup/share/restore access, and price behavior were not changed.
- Focused Xcode diagnostics passed for touched files.
- Full Xcode builds passed after the changes.
- User smoke tested and committed the work.

## Recent Smoke Test Results
- Trial banner no longer truncates in the iPad sidebar after compact copy change.
- Fifth-import Premium paywall opens full height after using only the large presentation detent.
- Trial/exhausted messaging was exercised through the import/paywall flow.
- Previous conversion diagnostics smoke pass showed source attribution working for fifth-import, Settings, About, and Backup & Restore entry points.

## Files Recently Touched
- `DebtScope/Models/PaywallSource.swift`
- `DebtScope/Models/PaywallView.swift`
- `DebtScope/Models/PurchaseManager.swift`
- `DebtScope/Models/ImportViewModel.swift`
- `DebtScope/Parsers/QuickIngestHints.swift`
- `DebtScope/Utils/TrialBanner.swift`
- `DebtScope/Utils/SettingsView.swift`
- `DebtScope/View/Import/ImportFlowView.swift`
- `DebtScope/View/Import/ReviewImportView.swift`
- `DebtScope/View/QuickStartView.swift`
- `DebtScope/View/AboutView.swift`
- `DebtScope/Backup/BackupRestoreView.swift`
- `DebtScope/Docs/CodexHandoff.md`

## Important Product Decisions
- Backup and restore should remain available to all users for now.
- Backup & Restore should be a soft Premium value message, not a blocker.
- Conversion diagnostics should remain local-only and DEBUG-only unless privacy/App Store messaging is explicitly updated later.
- Avoid changing entitlement behavior or StoreKit product configuration unless explicitly requested.
- Keep the current low lifetime price during this conversion-improvement pass.

## Suggested Next Step
- Continue `pricingStratigyPlan.md` with Settings/About upgrade row context improvements.
- Settings suggested row: `Lifetime Premium` with supporting text `Unlimited imports, backup/restore, payoff insights, and private local tools.`
- About suggested context: `Unlock Lifetime Premium` with supporting text `Unlimited local planning with no subscription.`
- Keep restore purchase access nearby and unchanged.
- Keep free import allowance, gating rules, StoreKit product ID, entitlement behavior, restore flow, and price behavior unchanged.

## Notes / Risks
- The debug summary previously showed one `unknown` paywall impression/tap from a default-source path. This is acceptable for diagnostics, but can be cleaned up later by assigning a concrete `PaywallSource` where appropriate.
- External import, payoff result, and assistant paywall source messages exist but have not all been exercised in the latest smoke passes.
- Any future remote analytics would require explicit privacy/App Store messaging review first.
