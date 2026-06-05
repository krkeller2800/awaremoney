# Codex Handoff

## Current Focus
- Manual asset detail on iPhone is now stable enough for real-device smoke testing.
- The latest work restored `AccountDetailView` derived-balance/link refresh using scalar mirror IDs instead of SwiftData relationship predicates, then added a direct asset value editor for manual assets.

## Completed This Checkpoint
- `DebtScope/Models/Transaction.swift`
  - Added optional `accountID` mirror field.
  - Initializes `accountID` from the assigned `Account`.
- `DebtScope/Models/BalanceSnapshot.swift`
  - Added optional `accountID` mirror field.
  - Initializes `accountID` from the assigned `Account`.
- `DebtScope/Debt/AssetLiabilityLink.swift`
  - Added optional `assetID` and `liabilityID` mirror fields.
  - Initializes mirror IDs from the linked asset/liability accounts.
- `DebtScope/Models/DebtScopeSchema.swift`
  - Added schema V4 and lightweight V3 -> V4 migration for the mirror fields.
- `DebtScope/DebtScopeApp.swift`
  - Updated app schema construction to V4.
  - Important: no launch-time relationship backfill is running. A previous attempt crashed on real iPhone because it dereferenced invalidated relationship objects during launch.
- `DebtScope/Backup/BackupImporter.swift`
  - Keeps imported/updated transaction and balance mirror IDs synced.
  - Keeps asset-liability link mirror IDs synced when importing links.
- `DebtScope/Account/AccountDetailView.swift`
  - Re-enabled `.task(id:)` derived-balance recompute and active linked-liability load.
  - Changed Account Detail background fetches from relationship predicates like `tx.account?.id == accountID`, `snapshot.account?.id == accountID`, and `link.asset.id == assetID` to scalar mirror-ID predicates.
  - Changed linked-liability selection guards/no-op checks to use `liabilityID`.
  - Hid the compact top-right `Transactions` shortcut for manual assets; non-asset accounts still show it.
  - Added a manual-asset-only `Asset Value` row under `Balance Info`; editing it updates or creates the latest `BalanceSnapshot`, marks it user-modified, sets `accountID`, saves, and refreshes the displayed cached balance.
  - Fixed the `Asset Value` text field so it keeps raw editable numeric draft text while focused, then shows currency formatting when not focused.
- `DebtScope/View/QuickStartView.swift`
  - Changed active asset-liability lookup to use `AssetLiabilityLink.assetID`.
  - Changed linked-liability lookup and picker binding to use `liabilityID`.
  - Keeps `assetID`/`liabilityID` synced when changing an existing linked liability.

## Validation
- Xcode live diagnostics clean for touched files during this checkpoint.
- Full Xcode project builds succeeded after the final changes.
- Real iPhone smoke test reported by user:
  - Launch crash is gone.
  - Quick Start asset tap opens the asset detail successfully.
  - `Asset Value` accepts full numeric entry and shows formatted currency when not editing.

## Known Constraints / Risks
- Existing legacy rows may have nil mirror IDs until they are touched/imported or newly created. The current path avoids launch-time backfill because dereferencing invalidated SwiftData relationships at launch caused a fatal real-device crash.
- Any future mirror-ID backfill must avoid direct SwiftData relationship dereferences on potentially invalidated objects. Prefer a controlled migration/repair design that can tolerate missing backing data, or avoid backfill and only use mirror IDs for new/touched records.
- Other screens still contain relationship-backed predicates outside this asset-detail path. This checkpoint only addresses the Quick Start/manual asset and Account Detail path involved in the real-device crash.

## Recommended Next Step
- Commit this checkpoint now that launch, Quick Start asset navigation, and manual asset value editing passed real-device smoke testing.
- After the commit, consider a separate focused pass to replace relationship-backed predicates in other screens with safer scalar-ID lookups where appropriate.
