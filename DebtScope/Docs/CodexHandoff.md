Continue from the sample-data / first-look preparation work.

Current state:
- Sample data now lives in a separate sample SwiftData store and can be switched from Settings.
- Sample data mode shows the `Viewing Sample Data` banner with `Use My Data`.
- `Try Sample Data` / sample mode loads bundled sample statements directly into the app instead of sending the user through review.
- Bundled sample PDFs are under `DebtScope/Resources/SampleData`.
- The sample data version key in `QuickStartView.swift` is used to force a one-time sample reload after bundled sample/default changes.
- The first-look implementation plan is still pending. Next substantive feature work should start with `DebtScope/Docs/FirstLookImpPlan.md`.

Recent sample PDF/import fixes:
- `006-creditCard.pdf` was corrected so PDF text extracts `Minimum Payment Due $51.65`.
- `FakeStatementPDFRenderer.swift` now renders credit-card summaries with `Minimum Payment Due`.
- `ImportViewModel.extractCardSummaryFromPDF` now accepts cent-accurate minimum payments like `$51.65` instead of requiring whole-dollar minimums.
- Sample liability repair now preserves statement-provided payment amounts instead of silently replacing them with an amortizing floor.

Sample payoff UI work:
- `DebtSummaryView.swift` copy changed from `Hold Back Cash` / `Debt Budget` to:
  - `Cash Available This Month`
  - `Keep for Spending`
  - `Debt Payoff Budget`
- A read-only `Debt Payoff Budget` / `Minimum Debt Payment` row was added in the Payoff Plan editor directly below `Keep for Spending` and above `Reinvest paid-off payments`.
- In Minimums mode, the desired conceptual layout is:
  - `Cash Available This Month`: full available cash
  - `Keep for Spending`: cash available minus minimum payments
  - `Minimum Debt Payment`: total required minimums
- Sample defaults seed `Keep for Spending` to `$500` through `debtDiscretionaryReserveAmount`.

Known unresolved issue:
- The `Keep for Spending` strategy-switch behavior is still wrong.
- Desired behavior:
  - On first sample compare-strategies load, Minimums should show calculated `Keep for Spending` and `Minimum Debt Payment`.
  - When switching from Minimums to Snowball/Avalanche, a calculated Minimums `Keep for Spending` value should clear to `$0`.
  - If the user manually edits `Keep for Spending`, preserve that value across Snowball/Avalanche.
  - Returning to Minimums may temporarily show the calculated Minimums leftover, but it must not cause the next Snowball/Avalanche switch to treat that calculated value as user-entered.
- Current implementation tried local flags (`keepForSpendingWasUserEdited`, `keepForSpendingWasEverUserEdited`, `programmaticKeepForSpendingValue`) in `DebtSummaryView.swift`, but the behavior is still incorrect. Revisit with a cleaner state model.

Validation status:
- Last full Xcode build succeeded after the latest `DebtSummaryView.swift` edits.
- No final verification was completed for the unresolved `Keep for Spending` strategy-switch behavior.

Recommended next step:
- Either fix the unresolved `Keep for Spending` strategy-switch state with a cleaner model, or pause it and begin `FirstLookImpPlan.md`.
- For first-look work, start by reading `DebtScope/Docs/FirstLookImpPlan.md` and align the sample-data entry point with that plan.
