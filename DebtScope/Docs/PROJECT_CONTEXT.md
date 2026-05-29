# DebtScope Project Context

## App Purpose

DebtScope is a SwiftUI + SwiftData iOS app based on the Aware Money
concept, but narrowed toward fast debt insight and quick wins.

The app imports financial statements or transaction files, identifies
the institution and account type when possible, parses the data, routes
it to the correct account, and helps the user answer questions like:

-   When can I pay off this account?
-   What payment gets me debt-free faster?
-   What changed since the last statement?
-   What is my current debt, net worth, and cash flow picture?

The intended import flow is simplified: the user taps Import, selects a
file, and the app tries to determine the institution, statement type,
account type, and routing automatically. The user reviews/corrects
before saving.

------------------------------------------------------------------------

## Core Architecture

DebtScope is organized around four main user areas:

RootView ├── Quick View ├── Debt Payoff ├── Net Worth └── Cash Flow

Primary concerns: - SwiftUI state - SwiftData persistence - Import
pipeline - Routing - Debt payoff projections

------------------------------------------------------------------------

## Data Model Summary

### Account

final class Account { enum AccountType: String, Codable, CaseIterable {
case checking, savings, creditCard, loan, cash, brokerage, property,
other }

    @Attribute(.unique) var id: UUID = UUID()
    var name: String
    var typeRaw: String
    var institutionName: String?
    var currencyCode: String
    var last4: String?
    var createdAt: Date

    var loanTermsJSON: Data?
    var creditCardPaymentModeRaw: String?

}

Rules: - ID is the source of truth - Prefer UUID over object references

------------------------------------------------------------------------

## Debt Payoff View Model

final class DebtPayoffViewModel: ObservableObject { @Published var
account: Account @Published private(set) var projection:
\[DebtProjectionPoint\] = \[\] @Published private(set) var payoffDate:
Date? = nil @Published private(set) var confidence: Double = 1.0
@Published private(set) var varianceMessage: String? = nil }

------------------------------------------------------------------------

## Import Pipeline

Supported types: PDF, CSV, TSV, TXT, XLSX, XLS, ZIP, QFX, OFX, QBO, QIF

Flow: 1. Select file 2. Detect institution/type 3. Parse 4. Route 5.
Review 6. Save

Key objects: - ImportViewModel - Routing service - Parsers

Rule: Use selectedAccountID (UUID), not Account references.

### Current Import Intake Flow

All primary statement intake paths should route through
`StatementIntakeResolver` before deciding where the import goes. This was
introduced to prevent document-open imports and the blue Import button from
drifting into different behavior.

Entry points:

-   Files/document tap: `RootView` stages the URL and sends a
    `QuickStartPendingImport` without pre-classifying the PDF.
-   Blue Import button: `QuickStartView.queueImport` calls
    `StatementIntakeResolver.resolve(...)`.
-   Cash Flow local import: `CashFlowDetailView.handleImport` also calls
    `StatementIntakeResolver.resolve(...)`.

`StatementIntakeResolver` is responsible for staging, running
`StatementIntakeClassifier`, running fallback parser-based inference, choosing
the final `StatementType`, and logging the final decision.

Important resolver policy:

-   Detection is advisory.
-   A weak `.creditCard` classifier result can be overridden to `.bank` only
    when fallback parsing finds strong deposit/bank evidence such as checking,
    savings, deposit account, or certificate account signals.
-   The fallback parser must not be forced into credit-card mode when the
    classifier guessed credit card; otherwise bank PDFs containing credit-card
    payment descriptions can be routed incorrectly.

Key resolver log:

`StatementIntakeResolver resolved source=... classifier=... fallback=... final=...`

### PDF Bank Import Review

Bank PDFs use a two-stage review:

1.  `DetectionReviewSheet` shows the Import Ready screen and always uses the
    top-right `Continue` action.
2.  `ReviewImportView` shows the full Review Import screen. Its bottom action
    is `Approve & Save`.

If a user reports seeing "Save", they are usually already on
`ReviewImportView`, not the initial Import Ready screen. The important question
is whether `vm.staged.transactions` survived into Review Import.

`StatementImportCoordinator` merges `PDFSummaryParser` balances with
`PDFBankTransactionsParser` transactions. For Cash Flow, after Continue,
`CashFlowDetailView.applyDetectedAccountSelections(...)` filters staged data by
the detected account selections. It now has a defensive guard: if parsed
transactions exist but selection-label filtering would drop all of them, the
transactions are preserved and a log is emitted.

Key Cash Flow filter logs:

-   `CashFlow detected-account filter — selected=... parserLabels=... kept=... balances x->y transactions x->y`
-   `CashFlow detected-account filter preserved transactions after label mismatch — selected=... rawTransactionLabels=...`

------------------------------------------------------------------------

## State Ownership

Key areas: - QAccountListView - DebtPayoffView - ImportViewModel -
ReviewImportView

Debug flow: UI → selectedAccountID → routing → review → save → SwiftData

------------------------------------------------------------------------

## Known Problem Areas

-   Statement identification
-   Parsing inconsistencies
-   Module size / compiler issues

------------------------------------------------------------------------

## Naming Conventions

-   Model = data class
-   Debt = debt logic
-   NetWorth = net worth logic
-   Import = import pipeline
-   Parser = file parsing

------------------------------------------------------------------------

## Debugging Priorities

-   State ownership
-   SwiftData identity
-   Import reliability
-   Architecture clarity

------------------------------------------------------------------------

## Rules

1.  Use UUID for identity
2.  Always review before save
3.  Detection is advisory
4.  Views should not own critical state

------------------------------------------------------------------------

## Prompting ChatGPT

Use PROJECT_CONTEXT.md as context.

For bugs: Trace: user action → state → routing → review → save →
mutation

Identify stale references and fix minimally.

------------------------------------------------------------------------

## High-Risk Pattern

New account created → reused incorrectly on next import

Fix: Refetch Account by ID before saving. Reset state after save.

------------------------------------------------------------------------

## Current Focus

-   Clean architecture
-   Simplified import
-   Debuggability
