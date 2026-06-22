Continue Fake PDF Generator rollout from `FakePDFGenImpPlan`.

Current state:
- Steps 1, 2, and 3 have been reviewed and committed.
- Step 4 has been implemented in the standalone Swift CLI package under `Tools/FakePDFGen`, still outside the app target.
- `build-recipes` now writes generated recipe JSON, runs privacy validation immediately afterward, and writes `privacy-validation-report.json` next to the generated recipes.
- Added `Tools/FakePDFGen/Sources/FakePDFGen/PrivacyValidator.swift`.
- Updated `Tools/FakePDFGen/Sources/FakePDFGen/main.swift` to print validation status and support `--allow-risky-output`.

Step 4 behavior:
- Builds a denylist from source backup strings: account names, institution names, last-four values, import labels, source filenames, payees, and memos.
- Filters very short strings and common generic terms to avoid excessive false positives.
- Scans generated recipe JSON string fields and records findings with generated file name, JSON field path, source kind, and matched source value.
- Fails `build-recipes` when findings exist unless `--allow-risky-output` is supplied.
- The override flag preserves the failed report and only allows local inspection to continue.

Validation status:
- Do not run `swift run`, `swift build`, or related SwiftPM commands from the Xcode-hosted Codex terminal unless the user explicitly asks.
- Step 4 was validated without SwiftPM using:
  - `swiftc -parse Tools/FakePDFGen/Sources/FakePDFGen/BackupManifestModels.swift Tools/FakePDFGen/Sources/FakePDFGen/BackupPackageReader.swift Tools/FakePDFGen/Sources/FakePDFGen/Decimal+FakePDFGen.swift Tools/FakePDFGen/Sources/FakePDFGen/PrivacyTransformer.swift Tools/FakePDFGen/Sources/FakePDFGen/SampleRecipeBuilder.swift Tools/FakePDFGen/Sources/FakePDFGen/PrivacyValidator.swift Tools/FakePDFGen/Sources/FakePDFGen/main.swift`
  - a temporary direct `swiftc` binary for `build-recipes`
  - synthetic `.dsbackup` packages in `/tmp`, confirming a clean recipe exits 0 with a passed report, an intentional leaked source string exits 1 with file/field findings, and `--allow-risky-output` exits 0 while preserving the failed report

Important constraints:
- Keep FakePDFGen outside the shipping app target.
- Never add private `.dsbackup` exports, original statements, raw generated working files, or generated output directories to the app bundle.
- Do not parse or copy original PDFs in the first pass.
- Generated recipes/PDFs must never contain real names, addresses, account numbers, institution names, payees, memo text, source filenames, original PDF pages/images/fonts/metadata/hidden text, check numbers, confirmation IDs, authorization codes, phone numbers, emails, or URLs from statements.

Working tree expected before commit:
- `Tools/FakePDFGen/Sources/FakePDFGen/main.swift` modified
- `Tools/FakePDFGen/Sources/FakePDFGen/PrivacyValidator.swift` added
- `DebtScope/Docs/CodexHandoff.md` modified by this handoff update

Next suggested step:
- Review and commit Step 4.
- Then proceed to Step 5: render brand-new text-based, importable fake statement PDFs from sanitized recipes using generic templates, without copying original PDF content or metadata.
