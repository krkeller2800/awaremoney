Continue purchase analytics rollout from `PurchAnalyticsImpPlan`.

Current state:
- Rollout steps 1 through 6 are complete.
- Steps 1 and 2 delivered the Cloudflare D1 schema, Worker ingestion/reporting endpoints, and private dashboard under `komakode.com`.
- Active deployed routes:
  - `https://komakode.com/api/debtscope/*`
  - `https://komakode.com/debtscope/purchase-analytics`
- Steps 3 and 4 delivered the iOS purchase analytics model/client/queue and wired purchase-funnel events behind the analytics setting.
- Step 5 is complete: DebtScope privacy policy, App Store Connect privacy disclosures, Settings disclosure/toggle, and disclosure docs are updated.
- Step 6 is complete: analytics defaults on for TestFlight only, stays off by default for production/debug/sandbox, and explicit user opt-out/opt-in overrides the default.
- User reported manual smoke testing complete, including dashboard/raw-row privacy spot checks.

Files changed in this working tree:
- `DebtScope/Utils/SettingsView.swift`
- `DebtScope/Docs/PurchaseAnalyticsPrivacyDisclosures.md`
- `DebtScope/Docs/PurchAnalyticsImpPlan.md`
- `DebtScope/Docs/CodexHandoff.md`
- `DebtScope/Models/PurchaseAnalytics.swift`
- `DebtScope/Models/PurchaseManager.swift`
- `DebtScope/Models/SettingsStore.swift`
- `DebtScope/Testing/PurchaseAnalyticsTests.swift`

Validation status:
- `XcodeRefreshCodeIssuesInFile` returned no issues for `PurchaseAnalytics.swift`, `PurchaseManager.swift`, `SettingsStore.swift`, and `PurchaseAnalyticsTests.swift` after step 6 changes.
- Full Xcode build succeeded.
- Focused `PurchaseAnalyticsTests` run passed: 8 passed, 0 failed.
- Manual smoke test is complete per user.

Important constraints:
- Do not send financial data, account names, payees, balances, imported document names, direct identity, or assistant prompts/responses.
- Keep analytics focused on purchase funnel and StoreKit reliability events only.
- Reporting endpoints must remain protected by `DASHBOARD_TOKEN` or stronger private auth.
- Ingestion remains public but strictly validated.
- Production analytics remains disabled by default unless intentionally changed after TestFlight validation.
- Local `.dev.vars`, `.wrangler/`, `node_modules/`, and `.DS_Store` are ignored and should not be committed.
- Wrangler commands for the Worker repo should be run from `/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope/debtscope-purchase-analytics` with `npx --no-install wrangler ...` because Wrangler is installed locally there.
- A pre-existing `wrangler dev` process was observed on port 8787; do not stop it unless requested.

Next suggested step:
- Commit rollout steps 5 and 6 together.
- After enough TestFlight data accumulates, review dashboard metrics before deciding whether to enable production analytics or revisit pricing.
