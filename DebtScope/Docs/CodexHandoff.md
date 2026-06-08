# Codex Handoff

## Current Focus
- Backup restore now blocks silent restore into non-empty app data and asks the user to confirm before adding backup data that may duplicate existing records.
- The confirmation UI is now a sheet with the core warning visible immediately and current-app vs backup counts hidden behind a `DisclosureGroup`.

## Completed This Checkpoint
- `DebtScope/Backup/BackupRestorePreflight.swift`
  - Added preflight count helpers for existing app data.
  - Decodes backup manifests from package or single-file backups to count backup contents and read `generatedAt`.
  - Provides structured `RestoreSummary` data and count rows for UI rendering.
- `DebtScope/Backup/BackupRestoreConfirmationView.swift`
  - Added shared SwiftUI confirmation sheet.
  - Shows warning copy, `Cancel`, destructive `Restore Anyway`, and a `DisclosureGroup` for current app and backup data counts.
- `DebtScope/Backup/BackupRestoreView.swift`
  - Local file-picker restore now imports immediately only when the app has no restorable data.
  - If data exists, it stores the selected backup payload and presents `BackupRestoreConfirmationView` before importing.
- `DebtScope/Backup/BackupOpenHandler.swift`
  - External/open-from-Files backup restores now use the same preflight and pending restore summary flow.
  - Accepts `dsbackup`, `debtscopebackup`, `ambackup`, and `json` extensions.
- `DebtScope/View/RootView.swift`
  - Keeps normal import result/error alerts.
  - Presents the shared restore confirmation sheet when a backup opened from outside the app targets a non-empty data store.

## Validation
- Xcode live diagnostics clean for all touched backup/root files.
- Full Xcode project builds succeeded after the confirmation sheet change.
- User confirmed the initial warning flow worked as described before the disclosure-sheet refinement.

## Known Constraints / Risks
- This is a warning/confirmation flow only. Restore behavior still adds/upserts backup records into the current app data; it does not implement merge conflict resolution or replace-all restore.
- Backup identity remains weak for older/current backups because exporter still uses surrogate IDs derived from SwiftData `persistentModelID` for many DTO IDs.
- Worktree had unrelated existing changes in `DebtScope/View/QuickStartView.swift` and `DebtScope.xcodeproj/project.pbxproj`; they were not intentionally modified for the backup confirmation task.

## Recommended Next Step
- Review the restore confirmation sheet on iPhone and iPad with a non-empty app and a backup package to confirm the disclosure layout feels right.
- Commit this checkpoint before starting backup identity, replace-all restore, or merge-policy work.
