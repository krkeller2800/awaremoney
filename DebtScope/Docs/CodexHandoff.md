# Codex Handoff

## Current Focus
- Backup restore/open behavior is stable on real devices after backup type cleanup.
- `Share Backup...` now creates flat `.ambackup` files again, matching the older backup files that restore correctly through the file picker.
- `Export Backup...` remains package-style `.dsbackup` and is handled as a package backup.

## Completed This Checkpoint
- `DebtScope/Utils/SettingsView.swift`
  - Reset App Data now clears all restore-counted SwiftData models, including `BillFundingAllocation`, `AccountImportMapping`, and leftover `Security` rows.
  - This prevents the “app already has data” restore confirmation from appearing after a real reset.
- `DebtScope/Info.plist`
  - Declares flat backup and package backup document types separately.
  - Flat backup extensions: `ambackup`, `debtscopebackup`.
  - Package backup extension: `dsbackup`.
  - Keeps open-in-place support at the top level.
- `DebtScope/Backup/UTTypes+DebtScope.swift`
  - Centralizes backup extensions.
  - Adds distinct flat and package backup UTTypes.
  - Keeps `.debtscopebackup` readable for test files already created during this work.
- `DebtScope/Backup/BackupRestoreView.swift`
  - `Share Backup...` creates `.ambackup` flat JSON backups.
  - `Export Backup...` uses the package backup UTType.
  - Restore picker is back on SwiftUI `fileImporter` with `[.debtScopeBackup, .json, .data]` after the UIKit picker experiment caused decode failures.
  - Removed temporary restore debug logging.
- `DebtScope/Backup/BackupOpenHandler.swift` and `DebtScope/DebtScopeApp.swift`
  - External URL/open routing uses the centralized backup extension list and supports legacy JSON.

## Validation
- Full Xcode project builds succeeded after the final cleanup.
- User verified on a real device:
  - Shared `.ambackup` backups restore by URL/tap.
  - Shared `.ambackup` backups restore through Backup & Restore -> Restore from Backup.
  - Exported `.dsbackup` backups restore by URL/tap.
  - Exported `.dsbackup` backups restore through Backup & Restore -> Restore from Backup.
- Simulator-only issue remains: backup files are visible/bright in the file picker but cannot be selected, even though the same flows work on real hardware. Simulator logs include IconServices/system document-picker noise such as `Unable to get ISSymbol for UTI: com.apple.ios-simulator`.

## Known Constraints / Risks
- Treat the Simulator file-picker failure as a Simulator/Files behavior regression unless it reproduces on physical hardware.
- Current restore behavior still adds/upserts backup records into existing data; it is not a replace-all restore or conflict-resolution workflow.
- Backup identity remains weak for older/current backups because exporter still uses surrogate IDs derived from SwiftData `persistentModelID` for many DTO IDs.
- Worktree previously had unrelated existing changes in `DebtScope/View/QuickStartView.swift` and `DebtScope.xcodeproj/project.pbxproj`; they were not intentionally modified for this backup work.

## Recommended Next Step
- Commit this checkpoint.
- Use real-device validation for backup open/import flows. Do not spend more time chasing the Simulator-only picker behavior unless it appears on hardware.
