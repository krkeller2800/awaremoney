# Fake PDF Generator Implementation Plan

## Goal

Create a developer-only tool that turns a private DebtScope backup export into fictional, importable sample statement PDFs. The generated PDFs should exercise DebtScope's normal PDF import path and provide a better first-look experience than CSV sample files, without shipping real user statements or private financial data.

## Placement

Keep the tool outside the shipping app target but inside the same repository:

```text
DebtScope/
  Tools/
    FakePDFGen/
      Package.swift
      Sources/
        FakePDFGen/
          main.swift
          BackupPackageReader.swift
          BackupManifestModels.swift
          SampleRecipeBuilder.swift
          PrivacyTransformer.swift
          FakeStatementPDFRenderer.swift
          TextExtractionVerifier.swift
      Recipes/
        generated/
      Output/
        PDFs/
```

The app should only consume approved generated PDFs later, for example:

```text
DebtScope/Resources/SampleData/
  Sample-Checking.pdf
  Sample-Credit-Card.pdf
  Sample-Auto-Loan.pdf
```

Do not add real statements, private backups, or raw generated working files to the app bundle.

## Input And Output

### Input

The tool reads a DebtScope backup package exported from the app:

```text
DebtScope-Backup-YYYY-MM-DD_HHMMSS.dsbackup/
  manifest.json
  statements/
    <batchID>/
      <sourceFileName>.pdf
```

`manifest.json` provides structured parsed data: accounts, transactions, balances, import batches, cash-flow items, and related model data. The `statements` folder may contain copied source PDFs for visual/layout reference, but the first version should not need to parse or copy original PDF content.

### Output

The tool writes two artifacts:

```text
Tools/FakePDFGen/Recipes/generated/*.json
Tools/FakePDFGen/Output/PDFs/*.pdf
```

The recipe JSON is the inspectable sanitized source of truth. The PDFs are brand-new fictional statements rendered from those recipes.

## Privacy Rules

Never copy these from the backup into generated recipes or PDFs:

- Real names.
- Real addresses.
- Real account numbers or last four digits.
- Real institution names.
- Real payee names.
- Real memo text.
- Source document filenames.
- Check numbers, confirmation IDs, authorization codes, phone numbers, emails, or URLs from statements.
- Original PDF pages, images, fonts, metadata, or hidden text.

Allowed pattern data:

- Account type.
- Transaction count.
- Date spacing within a statement period.
- Debit vs credit direction.
- Rough amount distribution after scaling.
- Balance movement pattern after recomputation.
- Presence of statement summary concepts such as payment due, minimum payment, APR, or ending balance.

## Generated Recipe Shape

Use a small Codable model that is independent of SwiftData and stable over time:

```json
{
  "schemaVersion": 1,
  "statementKind": "checking",
  "issuerName": "Northstar Credit Union",
  "customerName": "Jordan Morgan",
  "customerAddress": ["1842 Cedar Ridge Ave", "Springfield, OH 45502"],
  "accountName": "Everyday Checking",
  "accountLast4": "1047",
  "statementStart": "2026-02-01",
  "statementEnd": "2026-02-28",
  "openingBalance": 1452.37,
  "summary": {
    "endingBalance": 4218.72,
    "minimumPayment": null,
    "paymentDueDate": null,
    "aprPercent": null
  },
  "transactions": [
    {
      "date": "2026-02-03",
      "description": "Payroll Deposit - Northstar Design Co",
      "amount": 2866.50,
      "balance": 4318.87,
      "category": "income"
    }
  ]
}
```

## Implementation Steps

## Step 1: Create The Swift CLI Package

### Scope

Add a standalone Swift package under `Tools/FakePDFGen`.

### Implementation

- Create an executable target named `FakePDFGen`.
- Use `Foundation` for JSON and file handling.
- Use `PDFKit` to verify generated text extraction.
- Use AppKit/Core Graphics for PDF rendering on macOS.
- Do not make this package a dependency of the DebtScope app target.

### Acceptance Criteria

- `swift run FakePDFGen --help` prints expected arguments.
- The package builds independently from the app.
- Running the tool without arguments does not inspect app data or private folders.

## Step 2: Read DebtScope Backup Packages

### Scope

Read `.dsbackup` package directories exported by DebtScope.

### Implementation

- Accept `--input /path/to/Backup.dsbackup`.
- Locate and decode `manifest.json`.
- Optionally index `statements/<batchID>/*.pdf` for later reference, but do not parse them by default.
- Define local DTOs matching the backup manifest fields needed by the generator.
- Treat missing `statements` as valid; parsed manifest data is enough for the first version.

### Acceptance Criteria

- The tool can list import batches, accounts, transaction counts, and balance counts from a backup.
- The tool does not require access to the live SwiftData store or app sandbox.
- The tool fails with a clear message if `manifest.json` is missing or invalid.

## Step 3: Build Sanitized Recipes From Parsed Data

### Scope

Convert real parsed DebtScope data into fictional statement recipe JSON.

### Implementation

- Group transactions by import batch where possible.
- Resolve account type from associated accounts.
- Pick a supported statement kind: `checking`, `creditCard`, `autoLoan`, `mortgage`, or `genericLoan`.
- Shift each statement period to a fictional period.
- Preserve relative date spacing, not absolute dates.
- Scale amounts with a deterministic multiplier per generated statement.
- Recompute balances from a fictional opening balance.
- Replace payees with category-appropriate fictional descriptions.
- Replace account and institution information with sample personas.

### Acceptance Criteria

- Generated recipes contain no source account names, institution names, payees, real last four digits, or source filenames.
- Recipes are deterministic for the same input and seed.
- Recipes are readable enough to manually audit before PDF generation.

## Step 4: Add Privacy Validation

### Scope

Add automated checks that catch obvious leakage before PDFs are written.

### Implementation

- Build a denylist from source backup strings: account names, institution names, last four digits, import labels, source filenames, payees, and memos.
- Scan generated recipe JSON for denylisted strings.
- Require `--allow-risky-output` or a similar explicit flag to continue if validation fails.
- Write a validation report next to generated recipes.

### Acceptance Criteria

- The tool refuses to render PDFs when generated recipes contain source strings.
- The report identifies which generated file and field failed validation.
- Common short words and generic terms do not create excessive false positives.

## Step 5: Render Importable Fake PDFs

### Scope

Render brand-new text-based PDFs from sanitized recipes.

### Implementation

- Use simple in-house statement templates, not bank-specific layouts.
- Include real selectable text, not image-only pages.
- Use clear table headers compatible with DebtScope's PDF text extraction:

```text
Date        Description                  Amount       Balance
02/03/2026  Payroll Deposit              2866.50      4318.87
```

- Add account summary sections expected by DebtScope parsers:
  - Checking: opening balance, deposits, withdrawals, ending balance.
  - Credit card: previous balance, payments, purchases, interest/fees, new balance, minimum payment, due date, APR.
  - Loans: principal balance, payment amount, interest rate, due date, recent payments.
- Keep page layout visually statement-like but generic.

### Acceptance Criteria

- Generated PDFs open cleanly in Preview.
- Text selection works in the generated PDFs.
- `PDFDocument.page.string` returns the expected statement text.
- PDFs contain no original PDF metadata or copied assets.

## Step 6: Verify Against DebtScope Extraction

### Scope

Confirm generated PDFs can be consumed by the real DebtScope import path.

### Implementation

- Add a verifier mode that uses the same extraction/parsing code path if practical, or a smaller text-extraction check first.
- For app-level validation, manually import generated PDFs into DebtScope and confirm review/account creation behavior.
- Record the expected account count, transaction count, balances, and loan/card summary fields for each sample PDF.

### Acceptance Criteria

- Sample checking PDF imports with expected transactions and balance snapshots.
- Sample credit card PDF imports with expected transactions, balance, minimum payment, due date, and APR where applicable.
- Generated PDFs do not require special-case parser code just for sample data.

## Step 7: Bundle Approved PDFs Into DebtScope

### Scope

After generated PDFs pass validation, add only approved outputs to the app resources and wire them into the first-look sample-data flow.

### Implementation

- Create an app resource folder such as `DebtScope/Resources/SampleData`.
- Add only fake PDFs, not recipes derived from private backups unless they are fully sanitized and intentionally shipped.
- Add sample-data UI that imports or stages these PDFs through existing import behavior.
- Keep the tool and private inputs out of the app target.

### Acceptance Criteria

- A clean install can start the sample-data flow from the first-look screen.
- Sample data exercises the normal statement review/import path.
- App Store builds do not include `.dsbackup` files, private statements, or tool working directories.

## Gitignore Requirements

Add ignore rules before using real exports:

```gitignore
Tools/FakePDFGen/Inputs/
Tools/FakePDFGen/Output/
Tools/FakePDFGen/Recipes/generated/
*.dsbackup
```

If approved generated PDFs are copied into `DebtScope/Resources/SampleData`, those specific files should be committed intentionally.

## Suggested CLI

```sh
swift run FakePDFGen \
  --input /path/to/DebtScope-Backup.dsbackup \
  --output Tools/FakePDFGen/Output/PDFs \
  --recipes Tools/FakePDFGen/Recipes/generated \
  --seed debtscope-first-look-v1
```

Optional modes:

```sh
swift run FakePDFGen inspect --input /path/to/Backup.dsbackup
swift run FakePDFGen build-recipes --input /path/to/Backup.dsbackup --recipes Tools/FakePDFGen/Recipes/generated
swift run FakePDFGen render --recipes Tools/FakePDFGen/Recipes/generated --output Tools/FakePDFGen/Output/PDFs
swift run FakePDFGen verify --output Tools/FakePDFGen/Output/PDFs
```

## Open Decisions

- Whether recipe JSON should ever be committed, or treated as generated/private working material.
- Whether the first version should support only checking and credit card statements.
- Whether to share parser code with DebtScope later, or keep verification manual to avoid making the app depend on the tool.
- Whether to create one fictional household persona or multiple personas for different sample scenarios.

## Recommended First Pass

Start with one checking statement and one credit card statement generated from an exported `.dsbackup` manifest. Do not parse original PDFs in the first pass. Use existing parsed transactions and balances to create recipes, render text-based PDFs, manually import them into DebtScope, then only bundle the approved fake PDFs once the import path is proven.
