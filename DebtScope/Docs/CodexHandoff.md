Continue Fake PDF Generator rollout from `FakePDFGenImpPlan`.

Current state:
- Step 1 was manually validated and committed before this handoff update.
- Step 2 has been implemented in the standalone Swift CLI package under `Tools/FakePDFGen`, still outside the app target.
- Added local manifest DTOs in `Tools/FakePDFGen/Sources/FakePDFGen/BackupManifestModels.swift`.
- Added read-only `.dsbackup` package loading in `Tools/FakePDFGen/Sources/FakePDFGen/BackupPackageReader.swift`.
- Wired `inspect --input /path/to/Backup.dsbackup` in `Tools/FakePDFGen/Sources/FakePDFGen/main.swift`.

Step 2 behavior:
- Requires a `.dsbackup` package directory with root `manifest.json`.
- Decodes manifest version, generated date, accounts, import batches, transactions, and balance snapshots.
- Lists total counts plus per-import-batch and per-account transaction/balance counts.
- Optionally indexes `statements/<batchID>/*.pdf` by count only; it does not parse or copy statement PDFs.
- Missing `statements` is valid.
- Missing package, non-directory input, missing manifest, and invalid manifest fail with clear messages.
- Inspect output avoids payees, memos, source filenames, account names, institution names, and last-four values.

Validation status:
- Do not run `swift run`, `swift build`, or related SwiftPM commands from the Xcode-hosted Codex terminal unless the user explicitly asks.
- Previous SwiftPM attempts from Codex hit sandbox/cache permission problems and then appeared to freeze/crash Xcode after retrying with redirected cache paths.
- This Step 2 change was validated without SwiftPM using:
  - `swiftc -parse Tools/FakePDFGen/Sources/FakePDFGen/BackupManifestModels.swift Tools/FakePDFGen/Sources/FakePDFGen/BackupPackageReader.swift Tools/FakePDFGen/Sources/FakePDFGen/main.swift`
  - a temporary direct `swiftc` binary for `--help`
  - a synthetic `.dsbackup` package in `/tmp` for `inspect --input`, confirming counts print and private fixture strings are not emitted

Important constraints:
- Keep FakePDFGen outside the shipping app target.
- Never add private `.dsbackup` exports, original statements, raw generated working files, or generated output directories to the app bundle.
- Do not parse or copy original PDFs in the first pass.
- Generated recipes/PDFs must never contain real names, addresses, account numbers, institution names, payees, memo text, source filenames, original PDF pages/images/fonts/metadata/hidden text, check numbers, confirmation IDs, authorization codes, phone numbers, emails, or URLs from statements.

Working tree expected before commit:
- `Tools/FakePDFGen/Sources/FakePDFGen/BackupManifestModels.swift` added
- `Tools/FakePDFGen/Sources/FakePDFGen/BackupPackageReader.swift` added
- `Tools/FakePDFGen/Sources/FakePDFGen/main.swift` modified
- `DebtScope/Docs/CodexHandoff.md` modified by this handoff update

Next suggested step:
- Review and commit Step 2.
- Then proceed to Step 3: build sanitized recipe JSON from parsed manifest data, preserving only allowed pattern data and replacing all private source strings with deterministic fictional values.
