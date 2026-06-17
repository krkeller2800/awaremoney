# Codex Handoff

## Current Focus
- Pricing strategy implementation has started.
- The first coding change, Paywall Model, is complete.
- Backup & Restore soft Premium upsell is complete.
- User reported smoke testing and git commit are complete.

## Completed / Verified Context
- Added `PaywallSource` as a lightweight source model for Premium/paywall presentations.
- Updated `PaywallView` to accept `source: PaywallSource = .unknown`.
- Wired known paywall sources for import limit, external import, Settings, About, QuickStart trial banner, and Backup & Restore.
- Added a soft Premium section to Backup & Restore explaining that Premium supports unlimited imports and long-term local data portability.
- Backup & Restore clearly states that backup export, sharing, and restore remain available below.
- Added an Upgrade to Premium button in Backup & Restore that opens `PaywallView(source: .backupRestore)`.
- No backup, share, restore, StoreKit, price, entitlement, or free import rules were changed.
- Focused Xcode diagnostics passed for touched files.
- Full Xcode builds passed after the changes.
- User completed smoke testing and committed the work.

## Files Touched
- `DebtScope/Models/PaywallSource.swift`
- `DebtScope/Models/PaywallView.swift`
- `DebtScope/View/Import/ImportFlowView.swift`
- `DebtScope/View/Import/ReviewImportView.swift`
- `DebtScope/View/QuickStartView.swift`
- `DebtScope/Utils/SettingsView.swift`
- `DebtScope/View/AboutView.swift`
- `DebtScope/Backup/BackupRestoreView.swift`
- `DebtScope/Docs/CodexHandoff.md`

## Important Product Decisions
- Backup and restore should remain available to all users for now.
- Backup & Restore should be a soft Premium value message, not a blocker.
- Paywall source tracking is currently behind-the-scenes only; it does not create visible debug counters or source-specific copy yet.
- No remote analytics should be added for the pricing diagnostics pass.

## Suggested Next Step
- Continue with the next section in `pricingStratigyPlan.md`: update `PurchaseManager` responsibilities.
- Keep the lifetime product ID and free import allowance unchanged.
- Add local debug-only conversion counters for paywall impressions by source, purchase taps/outcomes, and product load outcomes.
- Expose a concise debug summary for developer/debug settings.

## Notes / Risks
- `PaywallSource` is now available for diagnostics, but no counters consume it yet.
- Backup/restore source can only be observed through the Upgrade button until `PurchaseManager` debug tracking is implemented.
- Any next pass touching purchase flows should be careful not to alter entitlement behavior or StoreKit product configuration unless explicitly requested.
