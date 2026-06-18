Continue purchase analytics rollout from PurchAnalyticsImpPlan.

Current state:
- Last committed purchase analytics commit: 618eeb4 Add Cloudflare purchase analytics worker.
- Uncommitted step 2 changes are ready to commit in:
  - `debtscope-purchase-analytics/src/index.ts`
  - `debtscope-purchase-analytics/test/index.spec.ts`
  - `debtscope-purchase-analytics/wrangler.jsonc`
- Rollout step 1 is complete: Cloudflare D1 schema and Worker ingestion/reporting endpoints.
- Rollout step 2 is implemented and deployed: private JSON reporting plus a minimal HTML dashboard under `komakode.com`.
- Worker deploy succeeded with version `0cdef386-a3e8-4176-8e94-f98e0a35d0ba`.
- Active deployed routes:
  - `https://komakode.com/api/debtscope/*`
  - `https://komakode.com/debtscope/purchase-analytics`
- Live validation completed:
  - Dashboard route returned `200 text/html; charset=utf-8`.
  - Unauthenticated summary route returned `401 application/json`.
  - User successfully validated authenticated summary using `.dev.vars` after the latest `DASHBOARD_TOKEN` rotation.
- `npm test` passes in `debtscope-purchase-analytics` with 6 tests.
- Wrangler may emit sandbox log-write warnings for `/Users/karlkeller/Library/Preferences/.wrangler/logs`, but deploy/test still completed.
- A pre-existing `wrangler dev` process was observed on port 8787; do not stop it unless requested.

Important constraints:
- Do not send financial data, account names, payees, balances, imported document names, direct identity, or assistant prompts/responses.
- Keep analytics focused on purchase funnel and StoreKit reliability events only.
- Reporting endpoints must remain protected by `DASHBOARD_TOKEN` or stronger private auth.
- Ingestion remains public but strictly validated.
- Local `.dev.vars`, `.wrangler/`, `node_modules/`, and `.DS_Store` are ignored and should not be committed.

Next suggested step:
- Review and commit the step 2 Worker/dashboard changes.
- After that, start rollout step 3: add the iOS purchase analytics event model and disabled-by-default client only. Do not wire production purchase-funnel events until privacy copy/App Store disclosure work is ready.
