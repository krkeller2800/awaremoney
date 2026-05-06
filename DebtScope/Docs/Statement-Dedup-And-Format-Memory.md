# Statement Dedup And Format Memory

## Goal

Add two lightweight capabilities to the existing import flow without introducing a heavy batch interrogation screen:

1. Detect likely duplicate statements and warn the user.
2. Recognize previously seen statement formats and reuse prior classification and routing decisions.

This preserves DebtScope's fast import UX while reducing misclassification and duplicate imports.

## Principles

- Keep the default path automatic.
- Intervene only when confidence is low or a likely duplicate is found.
- Separate exact-statement detection from recurring-format recognition.
- Reuse prior successful decisions when the format match is strong.

## Two Different Problems

### 1. Duplicate Statement Detection

Question:
Is this the same statement file or same statement period that was already imported?

Use this to warn the user:

- "This statement may already have been imported."
- Actions:
  - `Import Anyway`
  - `Replace Existing`
  - `Cancel`

### 2. Statement Format Memory

Question:
Have we seen this kind of statement before, even if it is for a different month?

Use this to improve automation:

- reuse institution name
- reuse statement type
- reuse account type mapping
- reuse account routing
- reuse parser overrides or confidence boosts

## Recommended Data Model

Add two persisted models.

### StatementImportFingerprint

Purpose:
Tracks a specific imported statement instance for duplicate detection.

Suggested fields:

- `id: UUID`
- `createdAt: Date`
- `sourceFileName: String?`
- `institutionName: String?`
- `statementTypeRaw: String?`
- `accountLabels: [String]`
- `statementStartDate: Date?`
- `statementEndDate: Date?`
- `asOfDate: Date?`
- `transactionCount: Int`
- `balanceCount: Int`
- `normalizedContentHash: String`
- `normalizedStructureHash: String`
- `totalBalanceSignature: String?`
- `formatSignature: String`
- `importBatchID: UUID?`

Notes:

- `normalizedContentHash` should be strict and good for exact-duplicate detection.
- `normalizedStructureHash` should be looser and good for "same data, slightly different text extraction."
- `formatSignature` links this import to a reusable statement format.

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
- `preferredAccountTypes: [String]`
- `preferredAccountLabels: [String]`
- `routingHints: Data?`
- `headerTokens: [String]`
- `domainHints: [String]`
- `sampleHeaderHash: String?`
- `successCount: Int`
- `lastImportFingerprintID: UUID?`

Notes:

- `routingHints` can store account mapping info or previously confirmed routing decisions.
- `preferredAccountTypes` can preserve outcomes like `checking`, `savings`, `loan`, `creditCard`.

## Signatures And Hashes

Use multiple signatures, not one.

### Exact Content Hash

Build from:

- normalized extracted PDF text or normalized imported rows
- lowercase
- collapse whitespace
- remove volatile file-path data

Best use:

- exact or near-exact duplicate warning

### Structure Hash

Build from:

- headers
- account labels
- row count bucket
- detected sections
- repeated domain labels
- key phrases such as `checking summary`, `savings summary`, `payment due`

Best use:

- resilient matching when extraction varies slightly across simulator/device or OS versions

### Format Signature

Build from:

- file type (`pdf`, `csv`, `ofx`, etc.)
- normalized headers
- normalized account labels
- detected institution domains
- section/header tokens
- parser family used

Best use:

- recurring layout recognition across monthly statements

## Matching Strategy

### Duplicate Detection

Consider a statement a likely duplicate when any of these are true:

1. `normalizedContentHash` matches exactly.
2. `normalizedStructureHash` matches and:
   - institution matches
   - statement date range overlaps exactly
   - transaction count or balances are very close
3. same institution + same account labels + same statement period + same end balances

Suggested duplicate confidence:

- High:
  exact content hash match
- Medium:
  same institution, same period, same labels, similar balances
- Low:
  same format only

Only warn for medium/high.

### Format Memory Matching

Look for a prior `StatementFormatMemory` row where:

- `formatSignature` matches exactly, or
- structure hash similarity is high, and
- institution/domain/header-token overlap is strong

If matched:

- prefill institution
- prefill statement type
- prefill account type mapping
- boost parser confidence
- reuse routing hints when safe

## Import Flow Integration

### Current Flow

Current DebtScope behavior is optimized for immediate import and routing.

### Proposed Flow

1. User selects file.
2. Run `StatementIntakeClassifier`.
3. Run parser/fallback extraction.
4. Build statement fingerprint and format signature.
5. Check duplicate memory.
6. Check format memory.
7. Decide:
   - if duplicate confidence is high: show duplicate warning
   - else if format memory match is strong: auto-apply remembered decisions
   - else continue with current flow
8. After successful import, persist:
   - statement fingerprint
   - updated format memory

## UI Recommendation

Do not add a permanent full-screen review step.

Instead add lightweight interventions.

### Duplicate Warning Sheet

Shown only when confidence is medium/high.

Suggested copy:

- "This statement looks like one you already imported."
- Show:
  - institution
  - period or as-of date
  - account labels
  - prior import date

Actions:

- `Import Anyway`
- `Replace Existing`
- `Cancel`

### Quiet Format Reuse

When a strong format match is found:

- auto-apply remembered classification
- optionally show subtle inline confirmation:
  - "Using saved import settings for this statement format"

No blocking UI needed.

## Replace Existing

If the user chooses `Replace Existing`, the app should:

1. locate the previously imported fingerprint
2. identify the associated imported records
3. remove or supersede those rows safely
4. import the new statement
5. preserve account identity and routing when possible

This requires careful linkage from imported records back to the fingerprint or batch.

## Safe First Version

A minimal first version should:

1. persist a statement fingerprint after import
2. check for exact duplicates on next import
3. show a warning sheet
4. persist format memory with:
   - institution
   - statement type
   - account labels
   - routing hints
5. reuse that data only when the format match is strong

This gets most of the value with limited scope.

## Suggested Matching Inputs From Current Code

The current codebase already exposes useful signals:

- `StatementIntakeClassifier`
- `ImportRoutingService`
- `StatementImportCoordinator`
- `PDFTextExtractor`
- `PDFSummaryParser`
- parsed headers
- parsed rows
- parsed `StagedBalance` account labels
- inferred institution
- inferred statement type

These are enough to build a first fingerprint system without adding OCR or a separate parser engine.

## Risks

- false duplicate warnings if the matching is too loose
- stale format memory if users correct imports manually and memory is not updated
- replacement complexity if imported records are not linked cleanly to a fingerprint or batch
- privacy concerns if too much raw statement text is retained

Mitigations:

- store hashes and structured summaries instead of raw full text
- version the fingerprint algorithm
- only auto-apply remembered decisions when match confidence is high
- prefer warnings over silent destructive replacement

## Recommendation

Implement in this order:

1. exact duplicate fingerprinting
2. duplicate warning sheet
3. format memory persistence
4. automatic reuse of saved classification/routing
5. optional replace-existing flow

That sequence improves reliability quickly while preserving DebtScope's fast import philosophy.
