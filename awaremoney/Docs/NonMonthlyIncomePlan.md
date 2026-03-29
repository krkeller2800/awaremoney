// Non‑Monthly Income: Budget Planning Rules

/*
This document captures how non‑monthly income (yearly, semiannual, quarterly, and one‑time windfalls) should be incorporated into the debt payoff budget. It exists to preserve context across conversations and guide implementation.

Overview:
- Goal: Model non‑monthly income realistically so the payoff budget never overstates before money arrives, and remains predictable afterward.
- Approach: Baseline + temporary overlay
  - Baseline budget = Recurring net each month (or a fixed amount if the user chooses)
  - Overlay = Even spread of non‑monthly income for N months after the pay date

Spread Rules:
- Yearly income → spread evenly over the next N months after the pay date (default N = 12; can be overridden)
- Semiannual income → next N months after the pay date (default N = 6; can be overridden)
- Quarterly income → next N months after the pay date (default N = 3; can be overridden)
- One‑time windfall → user‑configurable spread length N (3/6/12), defaulting to the global picker when no per‑item override exists
- Start month: the month after the pay date (avoid partial‑month proration)
- Rounding: round to cents; add any remainder to the last month of the spread
- Overlaps: if multiple spreads overlap, add them together
- Plan start mid‑spread: include only remaining spread months that fall within the horizon
- No backfill at horizon start: if the horizon begins exactly on what would have been the last spread month of a previous occurrence, we do not include that previous occurrence’s remainder

Baseline Budget (After Windfalls End):
Two modes:
1) Recurring Net (recommended default)
   - recurring income (monthly/semimonthly/biweekly/weekly/socialSecurity) as monthly equivalents
   - minus monthly‑equivalent bills
   - minus reserve seeding for that month
2) Fixed Amount (user‑chosen)

The plan uses the baseline for all months, then adds the overlay in months where spreads apply. After spreads end, the budget reverts to baseline automatically.

Engine Integration:
- Preferred: per‑month budget schedule
  - Pass `budgetByMonth[month] = baseline[month] + spread[month]` to the payoff engine.
- Incremental alternative: constant base + extra payments
  - Keep a constant `baseBudget` and inject per‑month "extra payments" equal to `spread[month]`.
  - This yields the same math without changing the engine API.

Data Model and Dependencies:
- CashFlowItem fields used:
  - `kind` (income vs bill)
  - `frequency` (see `PaymentFrequency`)
  - `firstPaymentDate`, `dayOfMonth`, `createdAt` for scheduling
  - `amount`
- PaymentFrequency helpers:
  - `monthsPerCycle` for yearly/semiannual/quarterly
  - monthly equivalent factors for recurring net
- Reserve processing:
  - Use existing reserve seeding helpers per month when computing the baseline.

Algorithm (High‑Level):
1) Build baseline per month:
   - For each month in horizon: `baseline[month] = max(0, recurringIncome[month] − recurringBills[month] − reserveSeed[month])`
   - Recurring income/bills use monthly equivalents; reserve seed is computed per month.

2) Build spread schedule for non‑monthly income:
   - Determine pay date for each item (prefer `firstPaymentDate`; fallback to `dayOfMonth` anchored to the plan start; else `createdAt`).
   - Resolve spread length N per item:
     - If the item has a per‑item override (`oneTimeSpreadMonthsOverride`), use it.
     - Otherwise use the global default picker value (3/6/12) from the plan sheet.
     - If neither applies, fall back to the period default (yearly=12, semiannual=6, quarterly=3; one‑time=12).
   - Compute `even = roundToCents(amount / N)` and apply it to months 1..N‑1 after the pay date month; put the rounding remainder in month N.
   - For recurring non‑monthly incomes, iterate occurrences across the horizon starting from the occurrence at or before the horizon start; do not backfill the previous occurrence’s tail when the horizon starts exactly on an occurrence month.

Pseudocode Sketch (spreads only):

for income in nonMonthlyIncomes {
  let payDate = resolvePayDate(income, planStart)
  let N = income.perItemOverride ?? globalDefaultN ?? periodDefaultN(for: income.frequency)
  let even = roundToCents(income.amount / N)
  var remainder = income.amount - even * (N - 1)
  for i in 1..<(N) { month = monthAfter(payDate, i); add(month, even) }
  add(monthAfter(payDate, N), remainder)
  // For recurring types, repeat for each occurrence across horizon starting from the occurrence at or before the horizon start (no backfill)
}

3) Compose final schedule:
   - `budgetByMonth[month] = baseline[month] + spread[month]`

4) Feed the payoff planner:
   - Preferred: pass `budgetByMonth` to the engine.
   - Alternative: use `baseBudget = average(baseline)` (or the chosen fixed amount) and pass per‑month extras equal to `spread[month]`.

UI and Settings:
- Strategy sheet additions:
  - Default spread length for non‑monthly income: 3/6/12 (global default used when an item has no per‑item override)
  - Toggle: "Include non‑monthly income as spread after pay date"
  - Budget source: Recurring Net (default) or Fixed Amount
- Income editor:
  - Optional per‑item override (`oneTimeSpreadMonthsOverride`) for spread length N (3/6/12). Despite the legacy name, this override applies to all non‑monthly income types.
- Settings persisted:
  - Include‑spread toggle
  - Global default spread length (3/6/12)
  - Baseline source (Recurring Net vs Fixed)

Edge Cases and Guardrails:
- Missing pay date:
  - Prompt user to set `firstPaymentDate`; otherwise fallback to `dayOfMonth` or `createdAt` and mark as estimated.
- Plan starts mid‑spread: include only remaining months of the spread.
- No backfill when the horizon starts exactly on a previous occurrence’s last spread month — we do not include that previous remainder.
- Negative baseline:
  - Clamp baseline to 0 before adding spreads to avoid overcommitting.
- Overlapping spreads:
  - Sum them; consider visual indicators for large spikes in the timeline.
- Rounding:
  - Always round to 2 decimals; put any remainder into the final spread month.
- Time zones:
  - Normalize to month starts and clamp day of month to valid ranges (use existing helpers).

Tests:
- Unit tests for scheduler/spreading:
  - Yearly/semiannual/quarterly/one‑time spreads
  - Rounding remainder goes to the last month
  - Overlapping spreads add correctly
  - Mid‑spread plan start only includes remaining months
  - Cross‑year behavior
  - Missing pay date fallback behavior
- No backfill at horizon start: when the horizon begins on what would have been the previous occurrence’s last spread month, that remainder is not included.
- Integration tests for planning:
  - Budget timeline equals baseline + spreads
  - Payoff dates adjust when spreads are enabled

Consistency with Visualization:
- DebtProjectionChartView should use the same `budgetByMonth` schedule used by the planner.
- Reserve seeding must be subtracted per month in the same way for both planning and charting.

Context Header Template (for new conversations):

Context: Implement non‑monthly income spreading for the debt payoff budget.
- Spread length N per item: per‑item override (3/6/12) if set; else global default (3/6/12); else period defaults (Yearly=12, Semiannual=6, Quarterly=3, One‑time=12)
- No backfill at horizon start; spreads begin the month after the pay month and include only remaining months within the horizon.
- Spreads start the month after the pay date; remainder goes to last month
- Baseline budget = Recurring Net (or Fixed amount if selected)
- Engine: Prefer per‑month budget; fallback to base + extra payments

Decision Log (append entries below):
- YYYY‑MM‑DD: Initial rules captured in docs/NonMonthlyIncomePlan.md.

Next Steps Checklist:
- [ ] Implement IncomeScheduler helper (occurrence + spread computation)
- [ ] Add settings and optional per‑item override for one‑time spread months
- [ ] Update Strategy sheet to build `budgetByMonth` and feed the planner
- [ ] Align DebtProjectionChartView to use the same schedule
- [ ] Add unit and integration tests as specified above
*/

