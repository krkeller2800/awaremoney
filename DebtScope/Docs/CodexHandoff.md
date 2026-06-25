Current state:
- Sample-data and first-import smoke testing is complete.
- The free-import paywall issue was traced to persisted Keychain allowance state, not to the current sample-data load or the Amazon import. The confirming log was `Free imports loaded from Keychain used=4 remaining=0 migrationFlag=true` at app startup.
- `PurchaseManager` now logs free-import allowance load, migration, reset, and completed-import increments with source/location details so future counter jumps can be attributed directly.
- Quick Start import now uses single-file selection. `QuickStartView` no longer enables multi-select or schedules `urls.dropFirst()` follow-up imports, matching the app's one-active-review workflow.
- The Amazon review sheet observed during testing was the normal Review Import sheet for the selected user statement.

Validation status:
- `XcodeRefreshCodeIssuesInFile` reported no issues for `PurchaseManager.swift` and `QuickStartView.swift` after the latest edits.
- Full Xcode build succeeded after adding allowance diagnostics and changing Quick Start to single-file import.
- Smoke test is finished.
- Commit is finished.

Recommended next step:
- Continue from a clean working state. If free-import allowance behavior is retested again, reset free imports from Settings > Developer first, relaunch, and confirm the startup log shows `used=0 remaining=4 migrationFlag=true` before importing.
