Current state:
- Compare Strategies portrait payoff rows were tightened to reduce wrapping: smaller row padding, smaller rank badge, tighter internal spacing.
- Portrait payoff rows now show account type beside the account name (`Loan`, `Card`, or `Debt`) while leaving the APR/payment/payoff details on the lower line.
- Sample data import now renames bundled sample accounts to shorter institution-style names without type words: `Summit`, `Harborview`, `Crescent`, `Northstar`, and `Pinecrest`.
- Sample data version was bumped to `2026-06-25.short-sample-account-names` so existing sample mode reloads and replaces the old long institution names.

Files changed:
- `DebtScope/Debt/DebtSummaryView.swift`
- `DebtScope/View/QuickStartView.swift`
- `DebtScope/Docs/CodexHandoff.md`

Validation status:
- Live Xcode diagnostics were clean for `DebtSummaryView.swift` after the latest payoff-row change.
- Live Xcode diagnostics were clean for `QuickStartView.swift` after the sample-data rename/version changes.
- Full project build was not run to conserve the remaining usage limit.

Recommended next step:
- Reopen/sample-reload the Compare Strategies screen and visually verify portrait rows keep APR/payment/payoff on one line and landscape account names no longer truncate.
- If the UI looks good, run a full Xcode build when usage/time allows, then commit the changes.
