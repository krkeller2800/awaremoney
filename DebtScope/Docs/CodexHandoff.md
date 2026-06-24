Current state:
- The First Look screen and sample data onboarding flow are implemented in `QuickStartView.swift`.
- Fresh installs default to `.user` mode and show the "How DebtScope Works" intro when there are no accounts and no pending review items.
- "See Sample Data" now calls `dataModeController.requestSampleData()`, so it both switches to sample mode and issues a load request when sample mode is already active.
- Sample data loads into the isolated sample store and auto-routes to `Debt Summary` when launched from the First Look action.
- Imports started while viewing sample data now stage selected files first, switch to `.user`, and publish pending Quick Start import requests through `ImportOpenRouter` so the rebuilt user-mode `QuickStartView` owns the actual import.
- Pending Quick Start imports refuse to process in `.sample` mode; they switch to `.user` and leave the request intact for the user-mode view.
- Normal user-mode imports still use the existing direct queue path.

Validation status:
- `XcodeRefreshCodeIssuesInFile` reported no issues for `QuickStartView.swift`.
- Full Xcode build succeeded after the import timing and sample request corrections.
- Current modified files: `DebtScope/View/QuickStartView.swift` and this handoff.

Recommended next step:
- Manually smoke-test the sample-data-to-user-import path in Simulator: view sample data, tap Import, choose a personal statement, confirm the app returns to My Data/user mode and routes the import review correctly.
- Commit the completed First Look and import timing changes after smoke testing.
