# Assistant Future Enhancements Implementation Plan

## Purpose

This plan covers assistant work that should happen only after the read-only internal assistant is stable, manually validated, and committed. The goal is to expand usefulness without weakening the privacy-first, read-only rollout posture described in `addAIAssistant.md`.

The current assistant must remain a thin natural-language layer over existing DebtScope services and calculations. Future enhancements should reuse canonical app logic, return compact summaries, and avoid write-capable AI tools until DebtScope has a confirmed app UI workflow and audit trail.

## Prerequisites

Before starting this plan:

- The read-only assistant is enabled only through the intended feature flag path.
- Manual TestFlight smoke validation confirms assistant prompts do not mutate payoff or budget settings.
- Service-layer tests for current assistant summaries pass.
- Full project build succeeds.
- The current assistant stabilization work has been committed.

## Phase 1: Strategy Comparison Tooling

### Scope

Add deterministic summaries for comparing avalanche, snowball, and minimum-payment strategies.

### Implementation

- Extend `DebtScopeAssistantService` with a strategy comparison method that calls `PayoffPlanProvider` or `DebtPayoffEngine`; do not duplicate payoff math.
- Return a compact summary containing strategy name, total interest, payoff completion date, payment feasibility, and missing input notes.
- Add or extend a Foundation Models tool for strategy comparisons.
- Update assistant instructions so comparison answers must use tool output and must disclose missing APR, balance, minimum payment, or budget data.
- Keep the existing read-only defaults snapshot/restore guard around response generation.

### Tests

- Empty or incomplete debt data returns a missing-data summary.
- Avalanche and snowball outputs match canonical payoff engine results.
- Infeasible budget cases report required minimum total and current configured budget.
- Assistant regression prompts produce deterministic fallback details when direct comparison cannot be calculated.

## Phase 2: Extra Payment What-If Simulations

### Scope

Answer questions such as "What happens if I add $100 per month?" without changing app settings.

### Implementation

- Add a service method that accepts an extra monthly payment amount and optional start date.
- Clamp payment amounts and reject negative or unrealistic values with a clear validation result.
- Run simulations against temporary inputs only; never persist the simulated budget.
- Return baseline versus scenario summaries with payoff date delta, interest delta, and first affected account when available.
- Add prompt-intent detection or tool input schema support for common extra-payment wording.

### Tests

- Simulations do not write `debtBudgetOverrideAmount`, fixed-budget settings, reserve settings, or payoff start settings.
- Zero extra payment matches baseline.
- Positive extra payment improves or equals payoff timing when the plan is feasible.
- Invalid values produce a validation response instead of invoking payoff calculations.

## Phase 3: Import Review Explanations

### Scope

Explain recent imports, statement classifier decisions, conflicts, duplicates, and account mapping needs.

### Implementation

- Add import review summary contracts for `ImportBatch`, classifier results, detection confidence, duplicate counts, skipped rows, and unresolved mappings.
- Build service methods that summarize recent import activity without exposing raw file contents, hashes, or full memo text.
- Add a tool for import review questions such as "What changed after my latest import?" and "What needs review?"
- Use existing statement intake, duplicate detection, and account mapping logic where possible.
- Include clear source notes such as import date, detected institution when safe, and count-based outcomes.

### Tests

- No imports returns an empty state summary.
- Duplicate and conflict summaries match existing import-review screens.
- Account mapping issues are counted and described without exposing raw identifiers.
- Transaction-level detail remains unavailable unless `assistantIncludeTransactions` is enabled and the user explicitly asks.

## Phase 4: Suggested Cleanup Actions

### Scope

Let the assistant suggest actions that users can take in the app, without executing them.

### Implementation

- Define read-only cleanup recommendation summaries for duplicate imports, missing account mappings, missing APRs, missing minimum payments, and uncategorized bill or income items.
- Each recommendation should include a destination screen or review workflow, expected benefit, and required user confirmation.
- Assistant responses may link or route to existing screens only if the route is a normal app navigation action, not a data mutation.
- Do not add tools that delete, merge, edit, categorize, or move records.

### Tests

- Recommendations are generated from current app state only.
- Recommendations do not mutate SwiftData or `UserDefaults`.
- Recommendations for sensitive transaction issues are suppressed unless transaction access is enabled.

## Phase 5: App Intents and Indexing

### Scope

Consider narrow system integrations after the in-app assistant behavior is stable.

### App Intents

Candidate read-only intents:

- Show debt summary.
- Open upcoming bills.
- Open assistant.
- Open debt payoff plan.

Implementation notes:

- Keep intents narrow and navigation-focused.
- Avoid exposing detailed balances or transaction data in system surfaces unless a separate privacy review approves it.
- Prefer opening DebtScope screens over returning sensitive content directly to Siri or Shortcuts.

### Spotlight and App Entity Indexing

Candidate non-sensitive entities:

- App sections.
- Saved account display names only if user expectations and privacy review support it.
- Help or review destinations.

Avoid indexing:

- Balances.
- Transaction payees or memos.
- Import file names.
- Debt payoff amounts or dates.

## Cross-Cutting Guardrails

- Read-only by default.
- No raw database, backup JSON, raw store files, or full transaction feeds in model prompts.
- Compact Codable summary contracts only.
- Clamp every tool input.
- Log failures without sensitive financial details.
- Keep `assistantIncludeTransactions` disabled by default.
- Keep persistent assistant history disabled by default.
- Require a separate confirmed UI and audit trail before any future write-capable AI workflow.

## Validation Checklist

For each phase:

- Xcode live diagnostics pass for edited files.
- Focused service and assistant tests pass.
- Full project build succeeds before TestFlight packaging.
- Manual smoke validation confirms assistant prompts do not mutate payoff settings, budget settings, reserve settings, imports, accounts, or transactions.
- Manual privacy validation confirms disabled transaction access prevents transaction-level answers.
- Responses identify missing source data instead of inventing balances, dates, APRs, payments, or import outcomes.

## Recommended Order

1. Strategy comparison.
2. Extra payment what-if simulations.
3. Import review explanations.
4. Suggested cleanup recommendations.
5. App Intents and indexing.

The first two phases are closest to existing payoff logic and should be completed before expanding into import review or system integrations.
