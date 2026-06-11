# Codex Handoff

## Current Focus
- Internal DebtScope Assistant is still preparing for TestFlight validation under the read-only rollout scope from `DebtScope/DebtScope/Docs/addAIAssistant.md`.
- Assistant remains feature-flagged and privacy-first: `assistantEnabled`, `assistantIncludeTransactions`, and `assistantRetainConversationHistory` default to `false`.
- Recent work focused on correcting the Assistant UI entry point, stabilizing deterministic answers, and hardening read-only behavior after a suspected debt-budget mutation.

## Completed This Checkpoint
- Made **Data > Assistant** open the real `DebtScopeAssistantView` instead of the availability-only screen.
- Removed the duplicate **Utility > Assistant** shortcut.
- Fixed the nested-navigation crash by allowing `DebtScopeAssistantView(embeddedInNavigation: true)` inside QuickStart navigation.
- Added keyboard dismissal after Assistant responses complete.
- Updated stale availability copy so it no longer says chat/tool access is a future milestone.
- Improved avalanche-vs-snowball prompts:
  - added regression coverage for `How much interest will I save by using avalanche over snowball`.
  - direct comparison failures now return concrete payoff setup details instead of generic failure text.
  - infeasible budget details include current payoff budget and required minimum-payment total when available.
- Added a hard read-only guard around Assistant responses:
  - snapshots protected payoff/budget `UserDefaults` before response generation.
  - restores them afterward to prevent indirect mutation of debt budget settings.
  - protected keys include `debtBudgetOverrideAmount`, `useFixedDebtBudget`, `baselineBudgetSourceRaw`, start mode/date, reinvestment rate, discretionary reserve, fixed-budget memory, and spread settings.
- Added regression coverage proving the read-only defaults snapshot restores a `$4,000` debt budget after a simulated mutation to `$100`.

## Latest Validation
- Xcode live diagnostics found no issues in edited Assistant files and assistant tests.
- Focused Assistant tests passed after the read-only guard: `6 tests: 6 passed, 0 failed, 0 skipped, 0 expected failures, 0 not run`.
- Full Xcode project build succeeded after the read-only guard.
- Earlier in this checkpoint, full active `DebtScope` test plan passed: `31 tests: 31 passed, 0 failed, 0 skipped, 0 expected failures, 0 not run`.

## Known Constraints / Risks
- Root cause of the observed `$100` debt payment budget persistence is not proven. Code search did not find an intentional Assistant write to `debtBudgetOverrideAmount`; the new snapshot/restore guard prevents the Assistant path from persisting protected payoff-setting mutations.
- Manual retest is still required on device:
  1. Set debt payment budget to `$4,000`.
  2. Open Assistant.
  3. Ask `Can I afford to add $100 to monthly debt payments?`.
  4. Return to the debt planner and confirm the budget is still `$4,000`.
  5. Repeat with avalanche/snowball prompts.
  6. Force quit and relaunch, then confirm the budget is still `$4,000`.
- Live iPhone data smoke validation must be performed manually in the app UI. Codex `ExecuteSnippet` runs in an Xcode Preview Simulator container, not the foreground iPhone app container.
- Keep future transaction work aggregated by default and gated by `assistantIncludeTransactions` plus an explicit user request.
- Do not add write-capable AI tools until there is a confirmed app UI workflow and audit trail.

## Recommended Next Step
- Commit the Assistant UI/read-only stabilization work before another TestFlight build.
- Suggested commit message: `Stabilize assistant UI and read-only behavior`
- After committing, run the manual budget-preservation smoke pass above, then continue TestFlight packaging if it holds.
