Continue Fake PDF Generator rollout from `FakePDFGenImpPlan`.

Current state:
- Steps 1, 2, 3, and 4 have been reviewed and committed.
- Step 5 has been implemented in the standalone Swift CLI package under `Tools/FakePDFGen`, still outside the app target.
- Added `Tools/FakePDFGen/Sources/FakePDFGen/FakeStatementPDFRenderer.swift`.
- Updated `Tools/FakePDFGen/Sources/FakePDFGen/main.swift` so `render --recipes <dir> --output <dir>` renders PDFs instead of printing the placeholder.

Step 5 behavior:
- Reads sanitized recipe JSON files from the recipes directory, excluding `privacy-validation-report.json`.
- Writes brand-new text-based PDFs to the output directory using generic statement templates.
- Includes selectable text, account summary sections, and transaction tables with `Date`, `Description`, `Amount`, and `Balance` headers.
- Supports checking, credit card, auto loan, mortgage, and generic loan recipe kinds.
- Paginates transaction tables and prints rendered PDF name, source recipe, page count, and transaction count.
- Does not open source statement PDFs or copy original PDF pages, images, fonts, or metadata.

Validation status:
- Do not run `swift run`, `swift build`, or related SwiftPM commands from the Xcode-hosted Codex terminal unless the user explicitly asks.
- Step 5 was validated without SwiftPM using:
  - `swiftc -parse` across all FakePDFGen source files.
  - `swiftc -typecheck` across all FakePDFGen source files.
  - a temporary direct `swiftc` binary for `render`.
  - a synthetic recipe under `/private/tmp/fakepdfgen-render-test/recipes`, confirming `render` exits 0 and writes `001-checking.pdf`.
  - PDFKit text extraction with a redirected module cache, confirming the generated PDF contains expected text including `Transaction Activity`, `Payroll Deposit`, `Date`, and `Amount`.

Important constraints:
- Keep FakePDFGen outside the shipping app target.
- Never add private `.dsbackup` exports, original statements, raw generated working files, or generated output directories to the app bundle.
- Do not parse or copy original PDFs in the first pass.
- Generated recipes/PDFs must never contain real names, addresses, account numbers, institution names, payees, memo text, source filenames, original PDF pages/images/fonts/metadata/hidden text, check numbers, confirmation IDs, authorization codes, phone numbers, emails, or URLs from statements.

Working tree expected before commit:
- `Tools/FakePDFGen/Sources/FakePDFGen/FakeStatementPDFRenderer.swift` added.
- `Tools/FakePDFGen/Sources/FakePDFGen/main.swift` modified.
- `DebtScope/Docs/CodexHandoff.md` modified by this handoff update.

Next suggested step:
- Review and commit Step 5.
- Then proceed to Step 6: verify generated PDFs against DebtScope extraction/import behavior, starting with PDF text extraction and then manual import through the app path.
