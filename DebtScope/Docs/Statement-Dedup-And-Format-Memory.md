# Statement Dedup And Format Memory

## Goal

DebtScope should reduce accidental duplicate imports and reuse proven import decisions without adding a heavy batch interrogation screen.

There are two related but separate capabilities:

1. Detect likely duplicate statement imports.
2. Recognize recurring statement formats and reuse prior classification or routing decisions.

The app already has a useful first duplicate guard. This document describes the current behavior, its limits, and the recommended path from the current design to broader statement fingerprinting and format memory.

## Current Implementation

### Snapshot Duplicate Guard

Current duplicate detection lives in `ReviewImportView`.

Behavior:

- It runs while the user is reviewing a staged import.
- It looks at included staged balances.
- It compares each staged balance to existing `BalanceSnapshot` rows through loaded accounts.
- It flags a duplicate when an existing account has:
  - the same account type as `vm.newAccountType`
  - the same statement/as-of calendar day
  - the same balance amount
- For loans and credit cards, it also considers sign-normalized balances so a positive parsed liability balance can match a saved negative liability snapshot.
- When a match is found, the review screen shows: "This statement appears to have already been imported. The same account type, statement date, and balance already exist."
- `Approve & Save` is disabled while this warning is present.

This is a pragmatic snapshot-level duplicate blocker. It is simple, local, and protects the common case of importing the same statement PDF twice.

### Existing Routing Memory

DebtScope also already has account-routing memory through `AccountImportMapping` and `ImportRoutingService`.

Behavior:

- Routing can remember institution + subaccount-label mappings.
- Later imports can reuse those mappings when resolving routing candidates.
- This is useful routing memory, but it is not statement-format memory.

Routing memory is keyed around account labels and institution. It does not know whether the current file has the same recurring statement layout as a prior file.

### Existing CSV Mapping Memory

DebtScope already stores `CSVColumnMapping` records and can auto-apply saved CSV mappings when incoming headers contain the mapped columns.

This is column-mapping memory, not full statement-format memory. It should be treated as a related helper, but it does not replace format signatures or statement-level memory.

## Current Limits

The current snapshot duplicate guard does not cover every duplicate scenario.

Known gaps:

- Transaction-only CSV/QFX/OFX/QIF imports may not have a balance snapshot to compare.
- PDFs without a parsed balance may not be detected as duplicates.
- Two different accounts with the same type, date, and balance can create a false duplicate warning.
- The duplicate UI blocks saving; it does not offer `Import Anyway`.
- `Replace Existing` is not implemented.
- No persisted statement fingerprint is stored after import.
- No content hash, structure hash, or format signature exists yet.
- Current routing memory can reuse an account mapping, but it is not scoped to a recurring statement format.

## Design Principles

- Keep the default path automatic.
- Preserve the current snapshot duplicate guard; it provides useful protection today.
- Separate duplicate detection from format memory.
- Warn only for medium/high duplicate confidence.
- Do not treat matching format alone as a duplicate.
- Reuse prior decisions only when the format match is strong.
- Do not implement destructive replacement until imported records are reliably linked to the prior statement or batch.

## Two Different Problems

### 1. Duplicate Statement Detection

Question:
Is this the same statement file or same statement period that was already imported?

Use this to warn or block the user before accidental duplicate data is saved.

Current answer:
DebtScope detects a common balance-snapshot duplicate during review and disables approval.

Recommended broader answer:
Add persisted statement fingerprints so duplicates can be detected from file content, parsed rows, statement period, account labels, balances, and linked import batches.

### 2. Statement Format Memory

Question:
Have we seen this kind of statement before, even if it is for a different month?

Use this to improve automation:

- reuse institution name
- reuse statement type
- reuse account type mapping
- reuse account routing hints
- reuse parser overrides or confidence boosts

This should not be used by itself to warn that a statement is a duplicate.

## Recommended Data Model

Add persisted models only when moving beyond the current snapshot duplicate guard.

### StatementImportFingerprint

Purpose:
Tracks a specific imported statement instance for duplicate detection and future replace/import-anyway workflows.

Suggested fields:

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

Notes:

- `normalizedContentHash` should be strict and good for exact duplicate detection.
- `normalizedStructureHash` should be looser and good for same data with slightly different extraction.
- `totalBalanceSignature` preserves the current snapshot-duplicate idea in persisted form.
- `formatSignature` links this import to reusable statement format memory.
- `fingerprintVersion` lets the app change algorithms later without ambiguous legacy comparisons.

### StatementFormatMemory

Purpose:
Tracks recurring statement layouts and the decisions that worked for them.

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
- `memoryVersion: Int`

Notes:

- `routingHintsData` can store prior account routing decisions in a versioned payload.
- `preferredAccountTypesData` can preserve outcomes like `checking`, `savings`, `loan`, or `creditCard`.
- Format memory should be updated only after a successful import.

## Signatures And Hashes

Use multiple signatures, not one.

### Exact Content Hash

Build from:

- normalized extracted PDF text when available
- normalized imported rows for structured formats
- lowercase text
- collapsed whitespace
- removed path-specific noise

Best use:

- exact or near-exact duplicate warning

### Structure Hash

Build from:

- headers
- account labels
- row count bucket
- balance count
- detected sections
- repeated domain labels
- key phrases such as `checking summary`, `savings summary`, `payment due`

Best use:

- resilient matching when extraction varies slightly across devices, OS versions, or parser paths

### Balance Signature

Build from:

- account type
- normalized account labels when available
- as-of date or statement end date
- normalized ending/current balances

Best use:

- persisted version of the current snapshot duplicate guard
- medium-confidence duplicate warning when no content hash is available

### Format Signature

Build from:

- file type (`pdf`, `csv`, `ofx`, etc.)
- normalized headers
- normalized account labels
- detected institution or domain hints
- section/header tokens
- parser family used

Best use:

- recurring layout recognition across monthly statements

## Matching Strategy

### Current Snapshot Duplicate Detection

Today, consider a statement duplicate when:

- there is an included staged balance
- an existing account of the same selected/import account type has a balance snapshot on the same day
- the saved balance matches the staged balance, with sign normalization for liabilities

This is intentionally conservative for balance-bearing statements, but it is not statement-wide fingerprinting.

### Recommended Duplicate Detection

Consider a statement a likely duplicate when any of these are true:

1. `normalizedContentHash` matches exactly.
2. `normalizedStructureHash` matches and:
   - institution matches
   - statement date range overlaps exactly
   - transaction count or balances are very close
3. same institution + same account labels + same statement period + same end balances
4. current snapshot duplicate guard matches

Suggested duplicate confidence:

- High: exact content hash match
- Medium: same institution, same period, same labels, and similar balances
- Medium: current snapshot duplicate guard match
- Low: same format only

Only warn or block for medium/high. Never warn merely because the format signature matches.

### Format Memory Matching

Look for a prior `StatementFormatMemory` row where:

- `formatSignature` matches exactly, or
- structure hash similarity is high and institution/domain/header-token overlap is strong

If matched, safe reuse candidates are:

- prefill institution
- prefill statement type
- prefill account type mapping
- boost parser confidence
- reuse routing hints when safe

Do not silently override user-selected hints.

## Import Flow Integration

### Current Flow

1. User selects file.
2. The coordinator parses or stages the file.
3. `ReviewImportView` displays staged transactions, balances, and holdings.
4. `ReviewImportView` computes the current snapshot duplicate warning.
5. `Approve & Save` is disabled if the snapshot duplicate warning is present.
6. On approval, `ImportViewModel.approveAndSave` saves an `ImportBatch` and records.
7. `ImportRoutingService` persists account-routing mappings after successful save.

### Recommended Next Flow

1. Keep the current review-screen snapshot duplicate guard.
2. Add a small duplicate service that can evaluate staged imports against existing data.
3. Move the duplicate rule into that service so the logic is testable outside `ReviewImportView`.
4. Add transaction-only duplicate detection using existing transaction hash keys.
5. Add an `Import Anyway` override before adding any destructive replacement flow.
6. Later, persist `StatementImportFingerprint` rows after successful imports.
7. Later still, add `StatementFormatMemory` after duplicate matching is stable.

## UI Recommendation

Do not add a permanent full-screen review step.

### Current UI

The current inline warning is acceptable for the first version:

- it appears in the existing review screen
- it explains why the statement appears duplicated
- it disables `Approve & Save`

### Recommended Improvement

Before adding `Replace Existing`, support a non-destructive duplicate choice:

- `Cancel`
- `Import Anyway`

Recommended behavior:

- Default to blocking accidental duplicates.
- Let advanced users intentionally import anyway after an explicit confirmation.
- Log when the user overrides a duplicate warning.

### Replace Existing

Implement `Replace Existing` only after fingerprint rows and import batches can reliably identify the prior imported records.

If the user chooses `Replace Existing`, the app should:

1. locate the previously imported fingerprint
2. identify the associated imported records
3. remove or supersede those rows safely
4. import the new statement
5. preserve account identity and routing when possible

This is intentionally later work.

## Recommended Improvement Path

### Phase 0: Document And Stabilize Current Behavior

- Document the current snapshot duplicate guard.
- Extract duplicate evaluation from `ReviewImportView` into a small service if edits are being made nearby.
- Add focused tests for same-day/same-balance matching and liability sign normalization.

### Phase 1: Broaden Duplicate Coverage Without New Models

- Add transaction-only duplicate detection using existing saved transaction hash keys.
- Add a duplicate override state so `Import Anyway` is possible.
- Keep `Replace Existing` out of scope.

### Phase 2: Persist Statement Fingerprints

- Add `StatementImportFingerprint`.
- Persist one fingerprint row after each successful import that creates data.
- Link fingerprint rows to `ImportBatch` where possible.
- Use content/structure/balance signatures for duplicate checks.

### Phase 3: Add Format Memory

- Add `StatementFormatMemory`.
- Store successful classification and routing hints.
- Auto-apply only on strong format matches.
- Keep routing confirmation when confidence is low or the user provided conflicting hints.

### Phase 4: Replace Existing

- Add replacement only after fingerprints and batch linkage are reliable.
- Prefer a clearly confirmed flow because replacement is destructive.

## Risks

- false duplicate warnings if the matching is too loose
- false duplicate blocking when two accounts share type/date/balance
- stale format memory if users correct imports manually and memory is not updated
- replacement complexity if imported records are not linked cleanly to a fingerprint or batch
- privacy concerns if too much raw statement text is retained

Mitigations:

- store hashes and structured summaries instead of raw full text
- version fingerprint and memory algorithms
- only auto-apply remembered decisions when match confidence is high
- prefer warnings over silent destructive replacement
- require explicit user confirmation for import-anyway or replacement actions

## Recommendation

Use the current snapshot duplicate guard as the baseline and improve in this order:

1. document and test the current duplicate rule
2. add transaction-only duplicate detection
3. add `Import Anyway`
4. persist statement fingerprints
5. add format memory persistence and reuse
6. add optional replace-existing flow

That sequence keeps the app protected today while moving toward the broader design without coupling duplicate detection, routing memory, and destructive replacement into one large change.
