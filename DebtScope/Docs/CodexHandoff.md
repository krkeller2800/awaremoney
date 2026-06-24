Current state:
- The First Look screen and sample data onboarding flow are implemented in `QuickStartView.swift`.
- Fresh installs default to `.user` mode and show the "How DebtScope Works" intro when there are no accounts and no pending review items.
- "See Sample Data" only sets the auto-navigation intent and switches to `.sample`; sample data loading is owned by sample-mode `onAppear`, not by the button.
- Removed the explicit `sampleDataLoadRequestID` / `requestSampleData()` path because it could be observed by a stale user-backed `QuickStartView` during the mode transition and insert sample records into My Data.
- `QuickStartView` uses `isUsingActiveModelContext` to require the installed environment `modelContext` to match `dataModeController.activeContainer.mainContext` before loading sample data or processing pending user imports.
- Sample loading now uses a private throwaway `ImportViewModel` and `StatementImportCoordinator` instead of the visible QuickStart import VM. This should prevent iPad from presenting repeated per-statement import sheets; the user should only see the single QuickStart import-progress banner.
- Sample imports are marked with `sample.` parser IDs before save, so `ImportViewModel.approveAndSave` does not consume free import allowance. Existing-import allowance migration/counting now also ignores `ImportBatch.dataSetRaw == "sample"` in `ImportViewModel`, `QuickIngestor`, and `ImportFlowView`.
- Imports started while viewing sample data stage selected files first, switch to `.user`, and publish pending Quick Start import requests through `ImportOpenRouter`.
- Settings data-set switching only calls `dataModeController.switchTo(mode)`; sample mode self-loads through the same `onAppear` fallback.
- Normal user-mode imports still use the existing direct queue path.

Validation status:
- No remaining Swift references to `requestSampleData()` or `sampleDataLoadRequestID`.
- `XcodeRefreshCodeIssuesInFile` reported no issues for edited files: `QuickStartView.swift`, `ImportViewModel.swift`, `QuickIngestHints.swift`, `ImportFlowView.swift`, `DebtScopeApp.swift`, and `SettingsView.swift`.
- Full Xcode build succeeded after the sample allowance and iPad spinner cleanup.
- Current modified files: `DebtScope/View/QuickStartView.swift`, `DebtScope/DebtScopeApp.swift`, `DebtScope/Utils/SettingsView.swift`, `DebtScope/Models/ImportViewModel.swift`, `DebtScope/Parsers/QuickIngestHints.swift`, `DebtScope/View/Import/ImportFlowView.swift`, and this handoff.

Recommended next step:
- Delete/reinstall the app in Simulator before retesting, because the current simulator user store may already contain sample records from the prior bug.
- Re-run the Simulator smoke test on iPad and iPhone: clean install, tap See Sample Data, confirm the sample banner appears, confirm only one progress banner appears during sample load, confirm free imports used does not increase, then import a personal statement from sample mode and confirm My Data contains only the personal import.
- Commit after the clean retest passes.
