Continue Fake PDF Generator rollout from `FakePDFGenImpPlan`.

Current state:
- User asked to implement Step 1: create the standalone Swift CLI package under `Tools/FakePDFGen`.
- Step 1 files have been added outside the app target:
  - `Tools/FakePDFGen/Package.swift`
  - `Tools/FakePDFGen/Sources/FakePDFGen/main.swift`
- The CLI scaffold imports `Foundation`, `PDFKit`, and `AppKit`, prints help for expected arguments, lists planned commands (`inspect`, `build-recipes`, `render`, `verify`), and explicitly states that this step-one scaffold does not read backups, app data, or private folders.
- Repo-level `.gitignore` was updated with required privacy/generated-output rules:
  - `Tools/FakePDFGen/Inputs/`
  - `Tools/FakePDFGen/Output/`
  - `Tools/FakePDFGen/Recipes/generated/`
  - `*.dsbackup`

Validation status:
- Do not run `swift run`, `swift build`, or related SwiftPM commands from the Xcode-hosted Codex terminal unless the user explicitly asks.
- Previous SwiftPM attempts from Codex hit sandbox/cache permission problems and then appeared to freeze/crash Xcode after retrying with redirected cache paths.
- The issue is likely specific to the Xcode/Codex execution environment, not necessarily the package itself.
- User can validate manually in a normal Terminal if desired with:
  - `cd Tools/FakePDFGen`
  - `swift run FakePDFGen --help`

Important constraints:
- Keep FakePDFGen outside the shipping app target.
- Never add private `.dsbackup` exports, original statements, raw generated working files, or generated output directories to the app bundle.
- Do not parse or copy original PDFs in the first pass.
- Generated recipes/PDFs must never contain real names, addresses, account numbers, institution names, payees, memo text, source filenames, original PDF pages/images/fonts/metadata/hidden text, check numbers, confirmation IDs, authorization codes, phone numbers, emails, or URLs from statements.

Next suggested step:
- Review Step 1 scaffold manually or validate from an external Terminal, not Codex.
- Then proceed to Step 2: read `.dsbackup` package directories, locate/decode `manifest.json`, and list import batches/accounts/transaction counts/balance counts without touching the live app store or sandbox.
- After reviewing the Step 1 changes, make a git commit before starting Step 2.
