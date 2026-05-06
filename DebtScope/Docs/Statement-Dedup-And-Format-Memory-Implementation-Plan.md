# Statement Dedup And Format Memory Implementation Plan

## Goal

Implement duplicate-statement detection and statement-format memory in the current DebtScope import pipeline without adding a permanent batch interrogation screen.

This plan is intentionally incremental and aligned to the current codebase.

## Current Integration Points

### Import Entry

- [ImportFlowView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ImportFlowView.swift:66)
- [QuickStartView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/QuickStartView.swift:98)

These are the places where a file first enters the intake/classification flow.

### Import Execution

- [StatementImportCoordinator.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Parsers/StatementImportCoordinator.swift:34)

This is the best place to centralize:

- fingerprint generation
- duplicate checks
- format-memory lookups
- post-import persistence

### Imported Batch Storage

- [ImportBatch.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Models/ImportBatch.swift:11)
- [ImportBatchDetailView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ImportBatchDetailView.swift:9)

`ImportBatch` already gives the project a natural anchor for linking imported data back to a source file.

### Classification And Parsing Signals

- [StatementIntakeClassifier.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Parsers/StatementIntakeClassifier.swift:31)
- [PDFTextExtractor.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Extractors/PDFTextExtractor.swift:5)
- [PDFSummaryParser.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Parsers/PDFSummaryParser.swift:1)
- [ImportRoutingService.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ImportRoutingService.swift:1)

These already expose most of the signals needed for matching.

## Recommended Rollout Order

### Phase 1: Exact Duplicate Detection

Implement exact and near-exact duplicate detection first.

Why first:

- highest value
- lowest ambiguity
- minimal UX cost

Deliverables:

1. Persist one fingerprint record per successful import batch.
2. Detect exact duplicate hash matches on next import.
3. Show a lightweight duplicate warning sheet.

### Phase 2: Format Memory

Implement recurring statement-format memory second.

Why second:

- improves classification and routing
- reuses existing successful decisions
- still keeps import fast

Deliverables:

1. Persist format-memory rows after successful import.
2. Match new imports against prior formats.
3. Reuse saved institution/type/routing hints when confidence is strong.

### Phase 3: Replace Existing

Implement replace-existing only after the first two phases are stable.

Why third:

- requires reliable linkage between imported records and fingerprinted batches
- easiest place to make destructive mistakes

## New Models

Add two SwiftData models under `DebtScope/Models/`.

### 1. StatementImportFingerprint

Suggested path:

- `DebtScope/Models/StatementImportFingerprint.swift`

Purpose:

- exact duplicate detection
- near-duplicate detection
- historical audit trail for imported statements

Suggested fields:

- `id: UUID`
- `createdAt: Date`
- `sourceFileName: String`
- `sourceFileLocalPath: String?`
- `institutionName: String?`
- `statementTypeRaw: String?`
- `accountLabelsData: Data?`
- `statementStartDate: Date?`
- `statementEndDate: Date?`
- `asOfDate: Date?`
- `transactionCount: Int`
- `balanceCount: Int`
- `normalizedContentHash: String`
- `normalizedStructureHash: String`
- `formatSignature: String`
- `importBatchID: UUID?`

Implementation note:

Use `Data` or JSON-encoded string arrays for label storage if you want to avoid custom transform work immediately.

### 2. StatementFormatMemory

Suggested path:

- `DebtScope/Models/StatementFormatMemory.swift`

Purpose:

- recurring statement layout recognition
- reuse of prior classification/routing outcomes

Suggested fields:

- `id: UUID`
- `createdAt: Date`
- `lastSeenAt: Date`
- `formatSignature: String`
- `institutionName: String?`
- `statementTypeRaw: String?`
- `preferredAccountTypesData: Data?`
- `preferredAccountLabelsData: Data?`
- `routingHintsData: Data?`
- `headerTokensData: Data?`
- `domainHintsData: Data?`
- `sampleHeaderHash: String?`
- `successCount: Int`
- `lastImportBatchID: UUID?`

## Supporting Service

Create a small service object instead of spreading this logic across views.

Suggested path:

- `DebtScope/Parsers/StatementImportMemoryService.swift`

Responsibilities:

- build fingerprints
- build format signatures
- query for duplicates
- query for format-memory matches
- persist fingerprint rows
- persist/update format-memory rows

This service should not own UI.

## Fingerprint Inputs

Build from data already available after parsing.

### Inputs Available Today

From `StatementImportCoordinator` and parsed results:

- `url.lastPathComponent`
- `result.headers`
- `result.rows`
- `staged.transactions`
- `staged.balances`
- `staged.holdings`
- `staged.sourceFileName`
- inferred institution
- inferred statement type
- `PDFTextExtractor.extractText(from:)` when available

### Exact Content Hash

Source:

- normalized extracted PDF text for PDFs
- normalized imported rows for structured formats

Normalization:

- lowercase
- trim whitespace
- collapse repeated whitespace
- remove path-specific noise

Hash:

- existing hashing utilities if suitable, otherwise add a small SHA-based helper in `Utils/Hashing.swift`

### Structure Hash

Source:

- headers
- account labels
- row count bucket
- balance count
- major section tokens
- inferred domains

Goal:

- tolerate simulator/device extraction differences

### Format Signature

Source:

- file extension
- normalized headers
- normalized account labels
- section/header tokens
- parser identifier

Goal:

- match the same monthly statement format without treating it as an exact duplicate

## Duplicate Check Placement

Run duplicate checks after parse success, not only after intake classification.

Best insertion point:

- inside [StatementImportCoordinator.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Parsers/StatementImportCoordinator.swift:113)
- after `staged` is successfully built
- before final save/routing proceeds

Reason:

- at that point you have the strongest metadata
- you avoid false warnings based on weak early classification

## Minimal UI

Do not add a full review screen.

Add a lightweight duplicate sheet.

### Suggested UI Host

Primary candidate:

- [ImportFlowView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ImportFlowView.swift:8)

Secondary candidate for Quick Start path:

- [QuickStartView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/QuickStartView.swift:18)

### Duplicate Warning Content

Show:

- institution
- account labels
- statement period or as-of date
- previous import date
- duplicate confidence

Actions:

- `Import Anyway`
- `Cancel`

Do not implement `Replace Existing` in phase 1.

## Format Memory Reuse Placement

Run after duplicate check and before final routing/account creation.

Best insertion point:

- after parsing in `StatementImportCoordinator`
- before `vm.staged = staged`

Apply only when match confidence is strong.

Safe reused values:

- institution name
- statement type
- preferred account label interpretation
- routing hints used by `ImportRoutingService`

Do not silently override user-chosen hints.

## Persistence Timing

Persist memory only after a successful import has actually created data.

Best persistence trigger:

- wherever `ImportRoutingService` or the final import commit creates the batch and records

If the final imported batch already exists at that point:

- save `StatementImportFingerprint.importBatchID`
- update or insert `StatementFormatMemory`

This avoids learning from failed or abandoned imports.

## Recommended Matching Rules

### Phase 1 Duplicate Warning

Warn when:

1. exact content hash matches
2. or same institution + same account labels + same period + same balances

Do not warn merely because the format signature matches.

### Phase 2 Format Memory Reuse

Reuse when:

1. exact format signature match
2. or strong structure match plus matching institution/domain hints

Do not reuse when:

- the user explicitly selected a different document type
- the matched memory is weak
- the file appears to be an exact duplicate and the user has not confirmed import

## Logging

Keep this feature observable from the start.

Add `Import` logs for:

- fingerprint generated
- duplicate match found
- duplicate sheet shown
- format-memory match found
- memory reused
- memory persisted

This fits the existing logging approach already used in import diagnostics.

## Suggested File Changes

### New Files

- `DebtScope/Models/StatementImportFingerprint.swift`
- `DebtScope/Models/StatementFormatMemory.swift`
- `DebtScope/Parsers/StatementImportMemoryService.swift`

### Existing Files Likely To Change

- [StatementImportCoordinator.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Parsers/StatementImportCoordinator.swift:34)
- [ImportFlowView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ImportFlowView.swift:66)
- [QuickStartView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/QuickStartView.swift:98)
- [ImportBatch.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Models/ImportBatch.swift:11)
- [ImportRoutingService.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ImportRoutingService.swift:1)
- [Hashing.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Utils/Hashing.swift:1)

## First Milestone Definition

The first milestone is complete when:

1. each successful imported statement stores a fingerprint row
2. re-importing the same statement triggers a duplicate warning
3. the user can continue or cancel
4. no full review screen is added
5. existing import paths still behave the same when no duplicate is detected

## Second Milestone Definition

The second milestone is complete when:

1. statement formats are remembered after successful import
2. a repeated monthly statement can reuse prior institution/type/routing data
3. reuse happens silently only when confidence is strong
4. logs make the reuse decision visible

## Recommendation

Build phase 1 first and stop there long enough to validate the matching quality.

If the duplicate warnings are accurate, then add format memory using the same fingerprinting primitives. That sequencing keeps the implementation small, measurable, and aligned with DebtScope's quick-import philosophy.
