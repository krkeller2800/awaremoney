# Codex Handoff

## Current Focus
- Pricing strategy implementation is in progress.
- Paywall source modeling, Backup & Restore soft Premium upsell, and local debug conversion diagnostics are complete.
- User reported smoke testing and git commit are complete for the diagnostics pass.

## Completed / Verified Context
- Added `PaywallSource` as a lightweight source model for Premium/paywall presentations.
- Updated `PaywallView` to accept `source: PaywallSource = .unknown`.
- Wired known paywall sources for import limit, external import, Settings, About, QuickStart trial banner, and Backup & Restore.
- Added a soft Premium section to Backup & Restore that preserves free backup export, sharing, and restore access.
- Added DEBUG-only local conversion counters in `PurchaseManager`, backed by `UserDefaults`.
- Debug counters now track paywall impressions by source, purchase taps by source, purchase outcomes, and product load outcomes.
- Settings Developer section now exposes a concise `Conversion Diagnostics` summary.
- No remote analytics were added.
- Lifetime product ID, free import allowance, entitlement behavior, StoreKit configuration, backup/share/restore access, and price behavior were not changed.
- Focused Xcode diagnostics passed for touched files.
- Full Xcode builds passed after the changes.
- User smoke tested diagnostics successfully and committed the work.

## Recent Smoke Test Results
- Paywall impressions incremented for Settings, About, Backup & Restore, and an unknown/default source path.
- Purchase tap attribution incremented.
- Cancelled StoreKit outcome incremented.
- Product load success incremented.
- No unexpected product-load empty/error, failed purchase, pending purchase, or unverified purchase counters appeared.

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

## Suggested Next Step
- Continue with the next coding section in `pricingStratigyPlan.md`: refresh `PaywallView` copy around outcomes rather than import quota only.
- Suggested paywall direction from the plan: `Unlock Lifetime Premium`, broader local finance planning value, no subscription/ads/bank login, concise `Label` value bullets, and `Unlock Lifetime - {price}` button text.
- Add source-specific messages only where useful, especially fifth import, external import, and backup/restore.
- Keep StoreKit price display, restore flow, product ID, and free import rules unchanged.
- After paywall copy, continue to trial language cleanup for free import banners/status text.

## Notes / Risks
- The debug summary showed one `unknown` paywall impression/tap during smoke testing. This likely comes from a default-source presentation/helper path and is acceptable for diagnostics, but it can be cleaned up later by assigning a concrete `PaywallSource` where appropriate.
- `PaywallView` still has mostly import-centered copy; this is the next conversion-improvement opportunity.
- `PurchaseManager.freeImportStatusText` still says `free imports remaining`; trial-language cleanup should update this carefully because multiple UI surfaces may consume it.
