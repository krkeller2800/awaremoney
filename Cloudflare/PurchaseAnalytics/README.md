# DebtScope Purchase Analytics Worker

This Worker receives the production purchase analytics events sent by the iOS app to:

`https://komakode.com/api/debtscope/purchase-events`

It stores only the privacy-reviewed purchase funnel fields in Cloudflare D1. The app-generated install ID is hashed with a server-side pepper before storage.

## Setup

1. Install dependencies:

   ```sh
   npm install
   ```

2. Create the D1 database:

   ```sh
   npx wrangler d1 create debtscope_purchase_analytics
   ```

3. Copy the returned database ID into `wrangler.toml`.

4. Set Worker secrets:

   ```sh
   npx wrangler secret put INSTALL_ID_PEPPER
   npx wrangler secret put DASHBOARD_TOKEN
   ```

5. Apply the D1 migration:

   ```sh
   npm run d1:migrate:remote
   ```

6. Deploy:

   ```sh
   npm run deploy
   ```

## Endpoints

- `POST /api/debtscope/purchase-events`
  - Public ingestion endpoint used by the iOS app.
  - Validates against strict allowlists and caps request size.
  - Returns `{ "ok": true, "stored": true }` when an event is stored.

- `GET /api/debtscope/purchase-summary?days=30`
  - Private JSON reporting endpoint.
  - Requires `Authorization: Bearer <DASHBOARD_TOKEN>`, `X-DebtScope-Dashboard-Token`, or `?token=`.

- `GET /debtscope/purchase-analytics?token=<DASHBOARD_TOKEN>`
  - Minimal private dashboard for purchase funnel totals.

## Production Gate

Before deploying with production app traffic:

- Confirm the privacy policy and App Store Connect privacy answers are published.
- Confirm `DASHBOARD_TOKEN` and `INSTALL_ID_PEPPER` are stored as Cloudflare secrets.
- Confirm `ANALYTICS_DISABLED` is set to `"false"` only when collection is intentionally enabled.
- Run a TestFlight smoke check and verify rows appear in D1 before relying on production data.
