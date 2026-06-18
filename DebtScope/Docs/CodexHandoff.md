Continue purchase analytics rollout from PurchAnalyticsImpPlan.

Current committed state:
- Last commit: 618eeb4 Add Cloudflare purchase analytics worker.
- Working tree was clean after the commit.
- Cloudflare Worker project lives at `debtscope-purchase-analytics/` in the repo.
- Cloudflare D1 database `debtscope_purchase_analytics` exists with binding `DB`.
- D1 migration `0001_create_purchase_events.sql` creates the append-only `purchase_events` table and indexes.
- Worker endpoints implemented:
  - `POST /api/debtscope/purchase-events`
  - `GET /api/debtscope/purchase-summary?days=30`
- Worker deployed at `https://debtscope-purchase-analytics.karl-003.workers.dev`.
- Remote validation completed:
  - Summary endpoint returned HTTP 200 with zero counts before insert.
  - Remote `paywall_impression` insert returned `{"ok":true}`.
  - Summary endpoint then returned `paywallImpressions: 1` and `bySource` contained `settings` impressions.
- `DASHBOARD_TOKEN` was rotated after being pasted during testing.
- Local `.dev.vars`, `.wrangler/`, `node_modules/`, and `.DS_Store` are ignored and were not committed.

Important context:
- Rollout step 1 from PurchAnalyticsImpPlan is complete: Build Cloudflare D1 schema and Worker endpoints.
- Production iOS app analytics are not wired yet.
- Do not send financial data, account names, payees, balances, imported document names, direct identity, or assistant prompts/responses.
- Keep analytics focused on purchase funnel and StoreKit reliability events only.
- Protect reporting endpoints with the dashboard token or stronger private auth; ingestion remains public but strictly validated.
- The current Worker is available on workers.dev. komakode.com routing/dashboard work is not done yet.

Next suggested step:
- Start rollout step 2: deploy private JSON reporting and a minimal HTML dashboard under `komakode.com`, or first configure the Worker route under `komakode.com/api/debtscope/*` and decide whether to disable the workers.dev route/preview URLs.
