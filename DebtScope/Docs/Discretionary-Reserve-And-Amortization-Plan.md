# Discretionary Reserve And Amortization Plan

## Purpose

Add a plan-aware discretionary reserve and amortization schedule to DebtScope. The feature should let users see how much cash remains available under each payoff strategy while preserving the existing global payoff-plan behavior.

The schedule must be based on the global payoff plan, not independent per-card calculations, because snowball and avalanche payments depend on all active debts, available budget, reinvestment behavior, and payoff order.

## Core Terms

### Available Cash

Cash available before the selected debt payoff strategy is applied.

This comes from the existing income and bills schedule, including recurring net, non-monthly income spreads, bill reserve effects, and fixed-budget settings where applicable.

### Discretionary Reserve

User-entered monthly amount to keep available instead of committing to debt payoff.

This is an input. It should not be called discretionary income because it is not income. It is cash held back from the debt payoff budget.

Recommended UI label: `Discretionary Reserve`.

### Available For Debt

Amount passed into the payoff plan after respecting the discretionary reserve.

Formula:

```text
Available For Debt = max(0, Available Cash - Discretionary Reserve)
```

If this amount is below required minimum payments, the plan should report the same kind of feasibility problem it already reports for insufficient budget.

### Planned Debt Payment

Actual total debt payment assigned by the payoff plan for a month.

This is the sum of that month's account-level payments in `DebtPlanResult.months[].payments`.

### Discretionary Remaining

Calculated leftover after the selected plan's actual debt payment for the month.

Formula:

```text
Discretionary Remaining = Available Cash - Planned Debt Payment
```

This is a result, not a direct user input. It changes depending on strategy, budget source, non-monthly spreads, payoff order, and reinvestment rate.

## Recommended UX

Use two separate concepts in the UI:

- `Discretionary Reserve`: user input, the amount to protect each month.
- `Discretionary Remaining`: calculated result, the amount actually left after the selected plan's debt payment.

Avoid a single editable field named `Discretionary Income`; it creates ambiguity because users cannot tell whether they are editing cash-flow income, a reserve target, or a calculated leftover.

## Conversation Breakdown

This feature should be implemented across 3 focused conversations.

## Conversation 1: Add Discretionary Reserve To Plan Inputs

Goal: add the user-controlled reserve amount and make the app language clear.

### Scope

- Add persistent storage for the reserve, likely `@AppStorage("debtDiscretionaryReserveAmount")`.
- Add an input inside `Plan Settings > Payoff Plan` in `DebtSummaryView.swift`.
- Treat empty, invalid, or zero input as no reserve.
- Keep labels explicit:
  - Input: `Discretionary Reserve`
  - Output/result: `Discretionary Remaining`

### Primary File

- `DebtScope/DebtScope/Debt/DebtSummaryView.swift`

### Expected UI Placement

Inside the existing Payoff Plan section, near the monthly/fixed budget input and reinvestment slider.

Suggested row label:

```text
Discretionary Reserve
```

Suggested helper language:

```text
Amount to keep available before extra debt payoff.
```

### Deliverable

User can enter a monthly reserve target. Feasibility rows can display the reserve, even if all plan calculations are not yet fully wired across the app.

## Conversation 2: Apply Discretionary Reserve Across Plan Math

Goal: make every payoff plan calculation use the same budget rules.

### Rules

```text
Available Cash = income/bills schedule output
Available For Debt = max(0, Available Cash - Discretionary Reserve)
Planned Debt Payment = sum of DebtPlanResult month payments
Discretionary Remaining = Available Cash - Planned Debt Payment
```

### Files Likely Touched

- `DebtScope/DebtScope/Debt/DebtSummaryView.swift`
- `DebtScope/DebtScope/Debt/PayoffPlanProvider.swift`
- `DebtScope/DebtScope/Debt/DebtPayoffView.swift`
- `DebtScope/DebtScope/Debt/DebtDashboardView.swift`
- `DebtScope/DebtScope/Debt/DebtProjectionChartView.swift`
- `DebtScope/DebtScope/Debt/PlanBudgetDisplay.swift`, if display helpers need to expose both gross available cash and net available-for-debt values.

### Integration Notes

The reserve should reduce the budget before calling `DebtPayoffEngine.plan(...)`.

For monthly budget schedules, apply the reserve to each month before sending the schedule to the engine:

```text
adjustedBudgetByMonth[month] = max(0, availableCashByMonth[month] - discretionaryReserve)
```

For fixed monthly budget mode, clarify semantics before implementation:

- Preferred: fixed amount represents the debt payoff budget, and discretionary reserve is displayed against available cash for feasibility.
- Alternative: fixed amount represents available cash before reserve, and reserve reduces it before payoff.

Recommendation: preserve existing fixed-budget behavior by treating fixed budget as the intended debt payoff budget. Use discretionary reserve primarily with recurring-net/available-cash planning, and show warnings when fixed debt budget plus reserve exceeds available cash.

### Feasibility UI Additions

Add or update rows in the current plan math:

- `Available Cash This Month`
- `Discretionary Reserve`
- `Available For Debt`
- `Minimums Due This Month`
- `Shortfall`, if applicable

### Plan By Month Additions

Add month-level display values:

- `Available Cash`
- `Planned Debt Payment`
- `Discretionary Remaining`

### Deliverable

Debt Summary, Dashboard, Chart, and account payoff screens all compute plans from the same reserve-adjusted budget rules.

## Conversation 3: Add Amortization Schedule UI

Goal: add a global amortization schedule using the finalized plan math.

### New UI

Add a `Schedule` toolbar button next to the existing `Chart` button in `DebtSummaryView.swift`.

Present a sheet titled:

```text
Amortization Schedule
```

### New File

Recommended:

```text
DebtScope/DebtScope/Debt/DebtAmortizationScheduleView.swift
```

### Default View: All Debts

Show one row per month with plan-level totals:

- Month
- Available Cash
- Discretionary Reserve
- Available For Debt
- Total Debt Payment
- Interest
- Ending Debt Balance
- Discretionary Remaining

Each month row can expand to account-level details:

- Account
- Payment
- Interest
- Ending balance
- Payoff marker, when applicable

### Drilldown View: By Account

Include an account picker or filter. Show the selected account's monthly rows:

- Month
- Starting balance
- Payment
- Interest
- Ending balance
- Payoff marker

### Source Of Truth

Use `DebtPlanResult.months` from `DebtPayoffEngine`.

Do not create separate independent amortization calculations for each card when displaying snowball or avalanche plans.

### Starting Balance Reconstruction

`DebtPlanResult` stores ending balances, payments, and interest. It does not directly store starting balances.

Use the same approach already present in `DebtPayoffView.swift`:

- For the first visible month:

```text
startingBalance = endingBalance + payment - interest
```

- For later months:

```text
startingBalance = previousMonthEndingBalance
```

This logic should be centralized in a helper or row model so the amortization schedule and account payoff view do not drift.

### Deliverable

A plan-level amortization schedule that shows debt payoff progress and discretionary impact month by month.

## Validation Checklist

After implementation checkpoints, verify:

- Minimums-only, snowball, and avalanche still build plans.
- Reserve set to zero preserves current behavior.
- Reserve larger than available cash produces an understandable feasibility problem.
- Reserve reducing available cash below minimum payments produces a shortfall.
- Recurring-net mode shows changing discretionary remaining when monthly budgets vary.
- Fixed-budget behavior remains intentional and clearly labeled.
- Account payoff detail and Debt Summary agree on first-month payment and payoff date.
- Amortization schedule totals match `DebtPlanResult.totalInterest` and per-month payment sums.

## Handoff Prompt For Future Conversations

Use this prompt to continue work in a future conversation:

```text
Read DebtScope/DebtScope/Docs/Discretionary-Reserve-And-Amortization-Plan.md and continue with Conversation 1.
```

For later phases, replace `Conversation 1` with `Conversation 2` or `Conversation 3`.

## Commit Guidance

After each implemented conversation or stable checkpoint, make a git commit so the plan and implementation state travel together.
