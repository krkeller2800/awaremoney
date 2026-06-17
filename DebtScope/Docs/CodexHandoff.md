# Codex Handoff

## Current Focus
- Pricing strategy implementation is in progress.
- Paywall source modeling, Backup & Restore soft Premium upsell, local debug conversion diagnostics, and lifetime paywall messaging refresh are complete.
- User reported smoke testing and git commit are complete for the paywall messaging pass.

## Completed / Verified Context
- Added `PaywallSource` as a lightweight source model for Premium/paywall presentations.
- Updated `PaywallView` to accept `source: PaywallSource = .unknown`.
- Wired known paywall sources for import limit, external import, Settings, About, QuickStart trial banner, and Backup & Restore.
- Added a soft Premium section to Backup & Restore that preserves free backup export, sharing, and restore access.
- Added DEBUG-only local conversion counters in `PurchaseManager`, backed by `UserDefaults`.
- Debug counters track paywall impressions by source, purchase taps by source, purchase outcomes, and product load outcomes.
- Settings Developer section exposes a concise `Conversion Diagnostics` summary.
- Refreshed `PaywallView` copy around `Unlock Lifetime Premium`, broader local finance planning value, no subscription/ads/bank login, concise `Label` value bullets, and `Unlock Lifetime - {price}` button text.
- Added source-specific paywall messages for fifth import, external import, backup/restore, assistant, and payoff result.
- No remote analytics were added.
- Lifetime product ID, free import allowance, entitlement behavior, StoreKit configuration, backup/share/restore access, and price behavior were not changed.
- Focused Xcode diagnostics passed for touched files.
- Full Xcode builds passed after the changes.
- User smoke tested diagnostics and paywall messaging successfully and committed the work.

## Recent Smoke Test Results
- Paywall impressions: fifthImport 2, settings 2, about 2, backupRestore 3, unknown 1; externalImport/payoffResult/assistant remained 0 in this pass.
- Purchase taps: fifthImport 1, unknown 1; other sources 0.
- Purchase outcomes: cancelled 2; success/pending/unverified/failed 0.
- Product loads: success 2; empty/error 0.
- Source attribution worked for tested fifth-import, Settings, About, and Backup & Restore entry points.
- The existing `unknown` impression/tap path remains acceptable for diagnostics and can be assigned a concrete `PaywallSource` later.

## Files Recently Touched
- `DebtScope/Models/PaywallSource.swift`
- `DebtScope/Models/PaywallView.swift`
- `DebtScope/Models/PurchaseManager.swift`
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
- Continue with trial language cleanup from `pricingStratigyPlan.md`.
- Update `PurchaseManager.freeImportStatusText` and consuming UI surfaces away from quota-only wording like `free imports remaining`.
- Suggested active copy: `Trial active: {remaining} statement imports included`.
- Suggested exhausted copy where needed: `Trial imports used. Unlock Lifetime Premium for unlimited local planning.`
- Keep the free import allowance, gating rules, StoreKit product ID, entitlement behavior, restore flow, and price behavior unchanged.
- After trial language cleanup, consider improving Settings/About upgrade row context before opening the paywall.

## Notes / Risks
- `PurchaseManager.freeImportStatusText` is likely consumed by multiple UI surfaces; update carefully and smoke test each visible location.
- The debug summary still shows one `unknown` paywall impression/tap from a default-source path. This is acceptable for diagnostics, but can be cleaned up later by assigning a concrete `PaywallSource` where appropriate.
- External import, payoff result, and assistant paywall source messages exist but were not exercised in the latest smoke pass.
