Continue Fake PDF Generator rollout from `FakePDFGenImpPlan`.

Current state:
- Step 1 was manually validated and committed before the prior handoff.
- Step 2 was reviewed and committed.
- Step 3 has been implemented in the standalone Swift CLI package under `Tools/FakePDFGen`, still outside the app target.
- `build-recipes --input /path/to/Backup.dsbackup --recipes Tools/FakePDFGen/Recipes/generated --seed debtscope-first-look-v1` is now wired in `Tools/FakePDFGen/Sources/FakePDFGen/main.swift`.
- Added `Tools/FakePDFGen/Sources/FakePDFGen/SampleRecipeBuilder.swift` for grouping manifest transactions, choosing statement kinds, shifting statement periods, scaling amounts, recomputing balances, and writing pretty sorted recipe JSON.
- Added `Tools/FakePDFGen/Sources/FakePDFGen/PrivacyTransformer.swift` for deterministic fictional issuers, customers, addresses, account names, last-four values, opening balances, amount scaling, and direction-appropriate transaction descriptions.
- Added `Tools/FakePDFGen/Sources/FakePDFGen/Decimal+FakePDFGen.swift` for shared Decimal conversion.

Step 3 behavior:
- Groups non-excluded transactions by import batch and account when possible.
- Resolves supported statement kinds: `checking`, `creditCard`, `autoLoan`, `mortgage`, and `genericLoan`.
- Preserves relative date spacing while shifting statements to fictional 2026 periods.
- Scales transaction amounts deterministically from the seed and recomputes running balances from fictional opening balances.
- Replaces source account, institution, last-four, payee, and memo data with deterministic fictional values.
- Writes readable recipe JSON to the requested recipes directory.
- Does not parse or copy original PDFs.

Validation status:
- Do not run `swift run`, `swift build`, or related SwiftPM commands from the Xcode-hosted Codex terminal unless the user explicitly asks.
- Step 3 was validated without SwiftPM using:
  - `swiftc -parse Tools/FakePDFGen/Sources/FakePDFGen/BackupManifestModels.swift Tools/FakePDFGen/Sources/FakePDFGen/BackupPackageReader.swift Tools/FakePDFGen/Sources/FakePDFGen/Decimal+FakePDFGen.swift Tools/FakePDFGen/Sources/FakePDFGen/PrivacyTransformer.swift Tools/FakePDFGen/Sources/FakePDFGen/SampleRecipeBuilder.swift Tools/FakePDFGen/Sources/FakePDFGen/main.swift`
  - a temporary direct `swiftc` binary for `build-recipes`
  - a synthetic `.dsbackup` package in `/tmp`, confirming one recipe was written, relative dates and balances were sane, and private fixture strings were not emitted

Important constraints:
- Keep FakePDFGen outside the shipping app target.
- Never add private `.dsbackup` exports, original statements, raw generated working files, or generated output directories to the app bundle.
- Do not parse or copy original PDFs in the first pass.
- Generated recipes/PDFs must never contain real names, addresses, account numbers, institution names, payees, memo text, source filenames, original PDF pages/images/fonts/metadata/hidden text, check numbers, confirmation IDs, authorization codes, phone numbers, emails, or URLs from statements.

Working tree expected before commit:
- `Tools/FakePDFGen/Sources/FakePDFGen/main.swift` modified
- `Tools/FakePDFGen/Sources/FakePDFGen/Decimal+FakePDFGen.swift` added
- `Tools/FakePDFGen/Sources/FakePDFGen/PrivacyTransformer.swift` added
- `Tools/FakePDFGen/Sources/FakePDFGen/SampleRecipeBuilder.swift` added
- `DebtScope/Docs/CodexHandoff.md` modified by this handoff update

Next suggested step:
- Review and commit Step 3.
- Then proceed to Step 4: add privacy validation that builds a denylist from source backup strings, scans generated recipe JSON, and writes a validation report before PDF rendering.
