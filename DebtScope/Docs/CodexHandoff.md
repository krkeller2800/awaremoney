# Codex Handoff

## Current Focus
- Quick Start assets were expanded from property-only tracking to high-level manual asset buckets.
- A real-device iPhone crash when tapping assets was isolated to `AccountDetailView` relationship-backed refresh work running from `.task`.

## Completed Changes
- `DebtScope/Models/Account.swift`
  - Added optional `assetCategoryRaw` to `Account`.
  - Added `Account.AssetCategory` buckets: Property, Vehicle, Business, Collectible, Crypto, Retirement, HSA, Other.
  - Added helpers for manual assets, linked-liability support, and LTV visibility.
- `DebtScope/Models/DebtScopeSchema.swift`
  - Added schema V3 with lightweight migration from V2.
- `DebtScope/Backup/BackupExporter.swift`, `DebtScope/Backup/BackupImporter.swift`
  - Preserved `assetCategoryRaw` in backup export/import.
- `DebtScope/View/Import/ManualAssetSheet.swift`
  - Added bucket picker to `+ Asset`.
  - Saves property as `.property`; other buckets as `.other` with `assetCategoryRaw` set.
  - Allows optional linked liability and shows Net Equity; LTV only for Property/Vehicle.
- `DebtScope/View/QuickStartView.swift`
  - Quick Start asset section now lists manual assets by category.
  - Added editable bucket picker in the detail column.
  - Allows linked liabilities for all manual asset categories.
  - Hardened iPhone compact asset list by using `persistentModelID` for row identity/selection and removing broad relationship traversal from row rendering.
- `DebtScope/View/QuickStartAccountDetailByPersistentID.swift`
  - Added resolver view that navigates from a SwiftData `PersistentIdentifier` to `AccountDetailView(accountID:)`.
- `DebtScope/Account/AccountDetailView.swift`
  - Added bucket picker for manual assets.
  - Generalized financing labels to Linked Liability / Net Equity.
  - Shows LTV only for Property/Vehicle assets.
  - Fixed manual-asset description editing so `.other` category assets do not rename themselves like imported institution accounts.
  - Temporarily disabled `.task` and transaction-notification relationship refresh work after confirming it caused the iPhone invalidated-model crash.

## Validation
- Live diagnostics clean for touched files.
- Full Xcode builds succeeded after changes.
- Real iPhone smoke test: Quick Start asset screen opens and asset tap no longer crashes after disabling `AccountDetailView` relationship refresh.

## Known Tradeoff
- `AccountDetailView` currently skips async derived-balance refresh and initial linked-liability load from `.task` to avoid SwiftData invalidated-model crashes.
- Reintroduce this later using a safer data shape, ideally stored foreign-key UUIDs on snapshots/transactions/links or another approach that avoids predicates like `snapshot.account?.id == accountID` and `link.asset.id == assetID` during navigation.

## Recommended Next Step
- Commit this checkpoint before restoring any relationship-backed refresh logic.
- After commit, design a safe refresh path for Account Detail that does not dereference potentially invalidated SwiftData relationship objects.
