# Codex Handoff

## Current Focus
- Debt Summary plan settings terminology was simplified around cash available, debt budget, holdback, and cash left after debt.
- A payoff impact preview was added near the reinvestment slider to estimate cash freed after the next payoff.

## Completed Changes
- `DebtScope/Debt/DebtSummaryView.swift`
  - Renamed user-facing plan labels from `Adj Budget`/`Discretionary Reserve`/`Net for Debt` toward `Debt Budget`, `Hold Back Cash`, `Cash Left After Debt`, and `Recurring Cash After Bills`.
  - Reworked plan setting rows to avoid label truncation and dim only non-editable value fields.
  - Added payoff impact preview text near the reinvestment slider in both embedded and sheet plan editors.
  - Updated payoff impact preview to use the prior recurring payment before payoff, falling back to configured minimum/payment for first-month payoffs, instead of using the final payoff-month lump.
- `DebtScope/Debt/DebtPayoffEngine.swift`
  - Updated released-budget reduction in both planner paths to use prior recurring payment, falling back to minimum payment, instead of the payoff-month lump.
- `DebtScope/Debt/PayoffPlanProvider.swift`, `DebtScope/Debt/DebtDashboardView.swift`, `DebtScope/Debt/DebtAmortizationScheduleView.swift`, and `DebtScope/Debt/Income & Bills/IncomeBillsSummarySections.swift`
  - Updated related user-facing budget/holdback labels for consistency.

## Validation
- Live diagnostics were clean for the edited debt summary-related files before the payoff impact calculation fix.
- After the latest payoff impact calculation fix, run live diagnostics for `DebtSummaryView.swift` and `DebtPayoffEngine.swift`, then run a full Xcode build.

## Recommended Next Step
- Validate the latest calculation fix.
- If clean, commit the debt plan terminology and payoff impact work.
