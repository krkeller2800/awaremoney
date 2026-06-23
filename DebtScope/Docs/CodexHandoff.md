Continue Fake PDF Generator rollout from `FakePDFGenImpPlan`.

Current state:
- Steps 1, 2, 3, 4, and 5 have been reviewed and committed.
- Step 6 tool work is implemented and manually validated through the app path.
- The generated PDF set was built from `/Users/karlkeller/Downloads/DebtScope-Backup-2026-06-09_113052.ambackup` using FakePDFGen recipe generation, render, and verify commands.
- Manual app-path imports made it through all generated statements after the FakePDFGen fixes.

Important Step 6 fixes:
- `FakeStatementPDFRenderer.swift` now paginates from actual table position so transaction rows do not fall under the footer or overlap summary content.
- Header rendering was adjusted so issuer name and `Statement` extract on the same logical line.
- Fake issuer domain URLs such as `www.northstar-credit-union.com` are rendered in the header so the app's existing `StatementIntakeClassifier` can infer fictional institutions without app parser changes.
- `SampleRecipeBuilder.swift` now normalizes liability statement signs, deduplicates same-date/description/amount identities, and raises generated checking opening balances when needed so statements avoid overdraft endings that the app misreads.
- `PrivacyTransformer.swift` uses parser-safe fictional transaction labels, including `Courtesy Credit` instead of `Interest Credit` and payment-style credit card credit labels.
- `TextExtractionVerifier.swift` verifies rendered PDF text against recipes and checks transaction presence, balance reconciliation, summary ending balance, and duplicate import identities.
- `BackupPackageReader.swift` supports flat `.ambackup` input as well as `.dsbackup` packages.
- Swift 6 concurrency issues in FakePDFGen were fixed by avoiding shared non-Sendable formatter/attributed-string statics.
- Generated recipes/PDF outputs remain ignored and must not be bundled yet.

Important correction:
- Temporary app-target parser changes were backed out. Do not modify `StatementImportCoordinator.swift` for this fake statement naming issue. The root cause was FakePDFGen header/extraction shape, and the accepted fix is tool-only.

Validation status:
- FakePDFGen `build-recipes`, `render`, and `verify` passed from Terminal with 11 generated PDFs and privacy findings 0.
- Manual import through the app path passed for all generated statements after rerendering and copying PDFs into the simulator container.
- If rerunning from Terminal:
  - `cd /Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/Tools/FakePDFGen`
  - `swift run FakePDFGen build-recipes --input /Users/karlkeller/Downloads/DebtScope-Backup-2026-06-09_113052.ambackup --recipes Recipes/generated --seed debtscope-first-look-v1`
  - `swift run FakePDFGen render --recipes Recipes/generated --output Output/PDFs`
  - `swift run FakePDFGen verify --output Output/PDFs --recipes Recipes/generated`
  - `APP_CONTAINER=$(xcrun simctl get_app_container booted com.komakode.awaremoney data)`
  - `mkdir -p "$APP_CONTAINER/Documents/FakePDFs"`
  - `cp Output/PDFs/*.pdf "$APP_CONTAINER/Documents/FakePDFs/"`

Current next step:
- Commit the Step 6 FakePDFGen changes.
- Then proceed to Step 7: bundle only approved sanitized sample PDFs into DebtScope sample data resources.
