# Statement Dedup And Format Memory Implementation Plan

## Goal

Improve DebtScope's duplicate-statement detection and statement-format memory from the current implementation without adding a permanent batch interrogation screen.

This plan starts from the behavior that exists today:

- `ReviewImportView` already blocks likely duplicate balance-bearing statements.
- `ImportRoutingService` already persists account-routing mappings through `AccountImportMapping`.
- `CSVColumnMapping` already remembers column mappings for structured imports.

The next work should extend those pieces deliberately instead of treating the feature as unimplemented.

## Current Implementation Baseline

### Snapshot Duplicate Guard

Current location:

- [ReviewImportView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ReviewImportView.swift:922)

Current rule:

- read included `vm.staged?.balances`
- compare each staged balance against existing account balance snapshots
- match when account type, calendar day, and balance amount are the same
- normalize liability signs for loans and credit cards
- show an inline warning when matched
- disable `Approve & Save` while the warning exists

This protects the common same-statement-PDF-twice case.

### Transaction Save Dedup

Current location:

- [ImportViewModel.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Models/ImportViewModel.swift:1839)

Current behavior:

- transaction save uses hash keys to avoid inserting duplicate transactions for an account
- duplicate transactions are skipped during save
- if nothing new is saved, the user sees a save-time error

This avoids duplicate rows, but it is late feedback. It does not warn before review approval.

### Routing Memory

Current location:

- [ImportRoutingService.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ImportRoutingService.swift:261)
- [AccountImportMapping.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Debt/AccountImportMapping.swift:1)

Current behavior:

- account routing mappings are stored by institution and subaccount label
- later imports can reuse those mappings when resolving routing candidates

This is account-routing memory, not full statement-format memory.

### CSV Column Mapping Memory

Current location:

- [ImportFlowView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ImportFlowView.swift:356)
- `CSVColumnMapping`

Current behavior:

- saved column mappings can be auto-applied when incoming headers contain mapped columns

This helps structured imports, but it is not format-scoped enough to be treated as recurring statement-format memory.

## Recommended Rollout Order

### Phase 0: Align Docs And Stabilize Current Behavior

Purpose:

- make the current behavior explicit
- avoid reimplementing existing duplicate protection under a different name
- create a clean place for later rules

Deliverables:

1. Document the current snapshot duplicate guard.
2. Document current limitations.
3. Add or prepare focused tests around the duplicate rule if the code is touched.
4. Do not add new SwiftData models yet.

### Phase 1: Extract Duplicate Evaluation And Add Import-Anyway

Purpose:

- keep the current protection but make it testable and user-overridable

Deliverables:

1. Move duplicate evaluation out of `ReviewImportView` into a small service or helper.
2. Preserve the current same-type/same-day/same-balance rule.
3. Add an explicit duplicate override state.
4. Allow `Import Anyway` after confirmation.
5. Keep `Replace Existing` out of scope.

Why before fingerprints:

- low risk
- directly improves current UX
- keeps behavior visible in the existing review screen

### Phase 2: Add Transaction-Only Duplicate Warnings

Purpose:

- cover CSV/QFX/OFX/QIF imports that may not include balances

Deliverables:

1. Compare staged transaction save keys against existing transaction hash keys for the resolved account when possible.
2. Warn when all or nearly all included staged transactions already exist for the target account.
3. Avoid warning when only a small subset overlaps, because overlap can happen across date-range exports.
4. Reuse the same `Import Anyway` override.

Implementation notes:

- The final account resolution matters for transaction duplicate matching.
- If the target account is ambiguous, keep this as a lower-confidence warning or defer until routing is selected.
- Do not treat shared payees or matching dates alone as duplicates.

### Phase 3: Persist Statement Fingerprints

Purpose:

- move from inferred duplicate checks to durable statement-level memory

Deliverables:

1. Add `StatementImportFingerprint` under `DebtScope/Models/`.
2. Add the model to a new schema version in `DebtScopeSchema.swift`.
3. Add a lightweight `StatementImportMemoryService` under `DebtScope/Parsers/`.
4. Persist one fingerprint row after each successful import that creates transactions, balances, or holdings.
5. Link fingerprints to `ImportBatch.id` when available.
6. Use fingerprints for duplicate checks on later imports.

Suggested model fields:

- `id: UUID`
- `createdAt: Date`
- `sourceFileName: String?`
- `sourceFileLocalPath: String?`
- `institutionName: String?`
- `statementTypeRaw: String?`
- `accountLabelsData: Data?`
- `statementStartDate: Date?`
- `statementEndDate: Date?`
- `asOfDate: Date?`
- `transactionCount: Int`
- `balanceCount: Int`
- `normalizedContentHash: String?`
- `normalizedStructureHash: String?`
- `totalBalanceSignature: String?`
- `formatSignature: String?`
- `importBatchID: UUID?`
- `fingerprintVersion: Int`

### Phase 4: Add Format Memory

Purpose:

- reuse recurring statement layout decisions without confusing layout reuse with duplicate detection

Deliverables:

1. Add `StatementFormatMemory` under `DebtScope/Models/`.
2. Persist or update memory only after successful import.
3. Store institution/type/routing hints in versioned data payloads.
4. Match by exact `formatSignature` or strong structure similarity.
5. Auto-apply only on high confidence.
6. Do not silently override explicit user-selected document hints.

Suggested model fields:

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
- `memoryVersion: Int`

### Phase 5: Replace Existing

Purpose:

- safely replace a prior import with a corrected/newer version of the same statement

Deliverables:

1. Locate the duplicate fingerprint.
2. Resolve the linked `ImportBatch`.
3. Identify the batch-owned transactions, balances, and holdings.
4. Show a clear destructive confirmation.
5. Delete or supersede the prior batch records.
6. Save the new import and update memory.

Do not implement this before fingerprint-to-batch linkage is reliable.

## New Supporting Service

Recommended path:

- `DebtScope/Parsers/StatementImportMemoryService.swift`

Start small. The first version can be a non-persistent evaluator used by `ReviewImportView`.

Responsibilities over time:

- evaluate current snapshot duplicate rule
- evaluate transaction-only duplicate overlap
- build normalized content hashes
- build structure hashes
- build balance signatures
- build format signatures
- query duplicate fingerprints
- query format memories
- persist fingerprint rows
- persist or update format-memory rows

This service should not own UI state.

## Suggested Service API Shape

Phase 1 can start with simple values:

```swift
struct StatementDuplicateResult {
    enum Confidence {
        case none
        case low
        case medium
        case high
    }

    let confidence: Confidence
    let message: String?
    let reason: String
    let matchedImportBatchID: UUID?
}
```

Useful methods:

```swift
func evaluateSnapshotDuplicate(
    staged: StagedImport,
    accountType: Account.AccountType,
    accounts: [Account]
) -> StatementDuplicateResult

func evaluateTransactionDuplicate(
    staged: StagedImport,
    targetAccount: Account,
    context: ModelContext
) -> StatementDuplicateResult
```

Later fingerprint work can add:

```swift
func buildFingerprint(...)
func findDuplicateFingerprint(...)
func persistFingerprint(...)
func findFormatMemory(...)
func persistFormatMemory(...)
```

## Duplicate Check Placement

### Current Placement

The current snapshot duplicate check runs in `ReviewImportView`, which has access to:

- staged balances
- selected account type
- loaded accounts and snapshots
- the approve button state

This is why the current implementation is effective for visible review-time duplicate blocking.

### Recommended Near-Term Placement

Keep UI presentation in `ReviewImportView`, but move matching logic into `StatementImportMemoryService` or a small dedicated helper.

Benefits:

- easier to test
- easier to reuse in Quick Start or future import paths
- reduces review-screen business logic

### Recommended Later Placement

Run persisted fingerprint checks after parse success and before final save/routing proceeds.

Best insertion points:

- after `staged` is built in `StatementImportCoordinator`
- after routing is known for account-specific transaction duplicate checks
- after successful save for fingerprint persistence

## Minimal UI

Do not add a full review screen.

### Current UI To Keep

The existing inline warning in `ReviewImportView` is appropriate for the current duplicate guard.

### Recommended Phase 1 UI

Add a duplicate warning action row or confirmation dialog with:

- `Cancel`
- `Import Anyway`

Behavior:

- `Approve & Save` remains disabled until the user explicitly chooses `Import Anyway`.
- Once overridden, the warning should remain visible but indicate that the user chose to proceed.
- The override should apply only to the current staged import.

Do not add `Replace Existing` yet.

## Fingerprint Inputs

Build from data already available after parsing.

Inputs available today:

- `url.lastPathComponent`
- parsed headers
- parsed rows
- `staged.transactions`
- `staged.balances`
- `staged.holdings`
- `staged.sourceFileName`
- inferred institution
- inferred statement type
- `PDFTextExtractor.extractText(from:)` when available
- `ImportBatch.id` after save

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

- use existing hashing utilities if suitable
- otherwise add a small SHA-based helper in `Utils/Hashing.swift`

### Structure Hash

Source:

- headers
- account labels
- row count bucket
- balance count
- major section tokens
- inferred domains

Goal:

- tolerate parser or platform extraction differences

### Balance Signature

Source:

- account type
- account labels
- as-of date or statement period
- normalized ending/current balances

Goal:

- preserve current snapshot duplicate detection in durable form

### Format Signature

Source:

- file extension
- normalized headers
- normalized account labels
- section/header tokens
- parser identifier

Goal:

- match the same recurring monthly statement format without treating it as an exact duplicate

## Recommended Matching Rules

### Snapshot Duplicate Rule

Medium confidence when:

- same account type
- same as-of day
- same balance, with liability sign normalization

### Transaction Duplicate Rule

Medium confidence when:

- a routed target account is known
- most or all included staged transaction save keys already exist for that account
- the staged import has enough transaction rows to make the comparison meaningful

Low confidence when:

- only a small subset overlaps
- target account is unknown or ambiguous

### Fingerprint Duplicate Rule

High confidence when:

- exact content hash matches

Medium confidence when:

- structure hash matches
- institution matches
- period/date and balance signatures match or transaction counts are very close

Never warn when:

- only the format signature matches

### Format Memory Rule

Reuse when:

- exact format signature matches, or
- strong structure match plus matching institution/domain hints

Do not reuse when:

- the user explicitly selected a different document type
- the matched memory is weak
- the file appears to be an exact duplicate and the user has not confirmed import

## Persistence Timing

Persist memory only after a successful import has actually created data.

For the main review flow:

- `ImportViewModel.approveAndSave(context:)` creates the `ImportBatch` and records.
- Fingerprint persistence should happen after the save succeeds and only when content was saved.
- If persistence needs the created `ImportBatch.id`, expose it from the save path or return a save result.

For Quick Ingest:

- `QuickIngestor` creates its own `ImportBatch` and balance snapshot.
- Add fingerprint persistence after `context.save()` succeeds.

Avoid learning from failed, abandoned, or fully duplicate imports unless the user explicitly imports anyway.

## Logging

Keep this feature observable.

Add `Import` logs for:

- snapshot duplicate match found
- transaction duplicate match found
- duplicate warning shown
- duplicate override chosen
- fingerprint generated
- fingerprint persisted
- format-memory match found
- memory reused
- memory persisted

## Suggested File Changes

### Phase 1 Existing Files

- [ReviewImportView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ReviewImportView.swift:922)
- `DebtScope/Parsers/StatementImportMemoryService.swift` or a smaller duplicate evaluator helper

### Phase 2 Existing Files

- [ReviewImportView.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ReviewImportView.swift:1120)
- [ImportRoutingService.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/View/Import/ImportRoutingService.swift:63)
- [ImportViewModel.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Models/ImportViewModel.swift:1839)

### Phase 3 New Files

- `DebtScope/Models/StatementImportFingerprint.swift`
- `DebtScope/Parsers/StatementImportMemoryService.swift`

### Phase 4 New Files

- `DebtScope/Models/StatementFormatMemory.swift`

### Schema Files

- [DebtScopeSchema.swift](/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/DebtScope/Models/DebtScopeSchema.swift:1)

Add new SwiftData models only when phases 3 and 4 begin.

## Milestone Definitions

### Milestone 0

Complete when:

1. docs describe the current snapshot duplicate guard accurately
2. future work is split into duplicate detection and format memory
3. no code behavior changes are required

### Milestone 1

Complete when:

1. snapshot duplicate logic is testable outside the view
2. current duplicate behavior still works
3. user can explicitly choose `Import Anyway`
4. `Replace Existing` remains unavailable

### Milestone 2

Complete when:

1. transaction-only imports can warn when they appear fully duplicated
2. partial overlap does not block normal imports
3. the same override path handles balance and transaction duplicate warnings

### Milestone 3

Complete when:

1. each successful imported statement can store a fingerprint row
2. re-importing an exact same statement triggers a duplicate warning from fingerprint data
3. fingerprint rows link to `ImportBatch.id` when available
4. no full review screen is added

### Milestone 4

Complete when:

1. statement formats are remembered after successful import
2. a repeated monthly statement can reuse prior institution/type/routing data
3. reuse happens silently only when confidence is strong
4. logs make the reuse decision visible

## Recommendation

Start with Phase 1: extract and preserve the current snapshot duplicate guard, then add `Import Anyway`.

After that, add transaction-only duplicate warnings. Persisted fingerprints and format memory should come after the current duplicate UX is stable and tested.
