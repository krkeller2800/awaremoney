Continue purchase analytics rollout from `PurchAnalyticsImpPlan`.

Current state:
- Rollout step 1 is complete: Cloudflare D1 schema and Worker ingestion/reporting endpoints.
- Rollout step 2 has been reviewed, committed, implemented, and deployed: private JSON reporting plus minimal HTML dashboard under `komakode.com`.
- Worker deploy succeeded with version `0cdef386-a3e8-4176-8e94-f98e0a35d0ba`.
- Active deployed routes:
  - `https://komakode.com/api/debtscope/*`
  - `https://komakode.com/debtscope/purchase-analytics`
- Live Worker/dashboard validation completed:
  - Dashboard route returned `200 text/html; charset=utf-8`.
  - Unauthenticated summary route returned `401 application/json`.
  - User validated authenticated summary using `.dev.vars` after the latest `DASHBOARD_TOKEN` rotation.
- `npm test` passes in `debtscope-purchase-analytics` with 6 tests.
- Rollout step 3 is implemented and smoke tested in the iOS app: event model, disabled-by-default client, local install ID, and capped retry queue.
- Step 3 touched:
  - `DebtScope/Models/PurchaseAnalytics.swift`
  - `DebtScope/Models/SettingsStore.swift`
  - `DebtScope/Utils/SettingsView.swift`
  - `DebtScope/Testing/PurchaseAnalyticsTests.swift`
  - `DebtScope.xcodeproj/project.pbxproj`
- Step 3 validation completed:
  - `DebtScopeTests/PurchaseAnalyticsTests`: 6 passed.
  - Full Xcode build succeeded.
  - User completed smoke testing.

Important constraints:
- Do not send financial data, account names, payees, balances, imported document names, direct identity, or assistant prompts/responses.
- Keep analytics focused on purchase funnel and StoreKit reliability events only.
- Reporting endpoints must remain protected by `DASHBOARD_TOKEN` or stronger private auth.
- Ingestion remains public but strictly validated.
- Local `.dev.vars`, `.wrangler/`, `node_modules/`, and `.DS_Store` are ignored and should not be committed.
- Wrangler may emit sandbox log-write warnings for `/Users/karlkeller/Library/Preferences/.wrangler/logs`, but deploy/test still completed.
- A pre-existing `wrangler dev` process was observed on port 8787; do not stop it unless requested.

Step 3 smoke-test boundary:
- The iOS app does not currently send purchase analytics to Cloudflare.
- There is no visible analytics toggle, analytics status screen, or app-local network send log yet.
- Manual app smoke testing cannot directly prove analytics traffic was or was not emitted.
- The best available verification for step 3 is build + `PurchaseAnalyticsTests` + code inspection that `PurchaseAnalyticsClient` is not referenced by `PurchaseManager` or `PaywallView`.
- Do not expect Cloudflare dashboard data to change from normal app use in step 3.

Next suggested step:
- Commit the step 3 iOS analytics foundation if not already committed.
- Then start rollout step 4 only when ready: wire purchase-funnel events behind the analytics setting.
- Before enabling production analytics, complete privacy copy/App Store disclosure work and add a user-facing Settings toggle/disclosure for analytics.
