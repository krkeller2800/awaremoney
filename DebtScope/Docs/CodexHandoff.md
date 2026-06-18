Continue purchase analytics rollout from `PurchAnalyticsImpPlan`.

Current state:
- Rollout step 1 is complete: Cloudflare D1 schema and Worker ingestion/reporting endpoints.
- Rollout step 2 is committed, implemented, deployed, and validated: private JSON reporting plus minimal HTML dashboard under `komakode.com`.
- Worker deploy succeeded with version `0cdef386-a3e8-4176-8e94-f98e0a35d0ba`.
- Active deployed routes:
  - `https://komakode.com/api/debtscope/*`
  - `https://komakode.com/debtscope/purchase-analytics`
- Live Worker/dashboard validation completed:
  - Dashboard route returned `200 text/html; charset=utf-8`.
  - Unauthenticated summary route returned `401 application/json`.
  - User validated authenticated summary using `.dev.vars` after the latest `DASHBOARD_TOKEN` rotation.
- `npm test` passes in `debtscope-purchase-analytics` with 6 tests.
- Rollout step 3 is committed, implemented, and smoke tested in the iOS app: event model, disabled-by-default client, local install ID, and capped retry queue.
- Rollout step 4 is implemented and smoke tested in the iOS app: purchase-funnel events are wired behind the existing disabled-by-default analytics setting.

Step 4 touched:
- `DebtScope/Models/PurchaseManager.swift`
- `DebtScope/Models/PaywallView.swift`
- `DebtScope/Models/SettingsStore.swift`
- `DebtScope/Utils/SettingsView.swift`
- `DebtScope/Docs/CodexHandoff.md`

Step 4 validation completed:
- Full Xcode build succeeded.
- Targeted tests passed: 11/11 `PurchaseAnalyticsTests` and `PurchaseConversionDiagnosticsTests`.
- User completed DEBUG smoke testing.
- Smoke boundary: there is still no visible production analytics toggle/disclosure in Settings, so normal app use is not expected to produce Cloudflare dashboard activity.

Important constraints:
- Do not send financial data, account names, payees, balances, imported document names, direct identity, or assistant prompts/responses.
- Keep analytics focused on purchase funnel and StoreKit reliability events only.
- Reporting endpoints must remain protected by `DASHBOARD_TOKEN` or stronger private auth.
- Ingestion remains public but strictly validated.
- Production analytics remains disabled by default.
- Before enabling production analytics, complete privacy policy/App Store disclosure work and add a user-facing Settings disclosure/toggle or an explicit TestFlight-only enable path.
- Local `.dev.vars`, `.wrangler/`, `node_modules/`, and `.DS_Store` are ignored and should not be committed.
- Wrangler may emit sandbox log-write warnings for `/Users/karlkeller/Library/Preferences/.wrangler/logs`, but deploy/test still completed.
- A pre-existing `wrangler dev` process was observed on port 8787; do not stop it unless requested.

Next suggested step:
- Commit rollout step 4.
- Then start rollout step 5: update privacy policy and App Store privacy disclosures before any user-facing analytics enablement.
