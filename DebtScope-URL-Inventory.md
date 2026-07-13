# DebtScope URL Inventory

Updated: 2026-07-13

Scope: DebtScope app source, first-party project/config/docs, and the purchase analytics Worker directories in this repository. Dependency trees and generated artifacts are excluded unless they directly configure a DebtScope endpoint.

## Initial Repository State

- Repository root confirmed: `/Volumes/XcodeSSD/Users/karldev/Documents/DebtScope`
- Current branch confirmed before editing: `main`
- Initial working tree already contained unrelated changes:
  - `AGENTS.md`
  - `DebtScope.xcodeproj/project.pbxproj`
  - `DebtScope/Debt/DebtSummaryView.swift`
  - `DebtScope/Utils/SettingsView.swift`
  - `DebtScope/Docs/CompareStrategyMockups/account-type-icons-landscape.svg`
  - `DebtScope-URL-Inventory.md`

## Permanent App Compatibility Contracts

These DebtScope dependencies must remain reachable for released or cached app versions:

- `https://komakode.com/videos/DebtScope-help-videos.json`
- Every active media URL published by that manifest while any released or cached app version may reference it
- `https://komakode.com/api/debtscope/purchase-events`
- `mailto:support@komakode.com?subject=Debt%20Scope%20support`
- `https://komakode.com/Privacy%20Policy`
- StoreKit product ID `com.komakode.awaremoney.lifetime`

Normal website redesigns must preserve these routes or intentionally redirect them after verifying app behavior. A normal website deployment must leave the purchase analytics Worker/API route untouched.

## Help-Video Manifest

Exact endpoint:

- `https://komakode.com/videos/DebtScope-help-videos.json`

Where referenced:

- `DebtScope/View/HelpVideosView.swift`
  - `HelpVideosViewModel.feedURL` hard-codes the manifest URL.
  - `HelpVideosViewModel.loadVideos()` fetches it with `URLSession.shared.data(from:)`.
  - `HelpVideo.init(from:)` decodes each manifest item.
  - `HelpVideo.urlForCurrentDevice` chooses the device-specific or fallback media URL.
  - `HelpVideosViewModel.loadAssetDuration(from:)` uses `AVURLAsset` against media URLs when duration is not supplied.
  - `HelpVideosView.preparePlayer(for:)` streams the selected media URL with `AVPlayer`.

Feature:

- Help videos in the app.

Current response type/schema:

- `application/json`
- Top-level JSON array.
- Each item currently uses:
  - `id`
  - `title`
  - `subtitle`
  - `urls`
  - `urls.iphone`
  - `urls.ipad`
- The app decoder also tolerates `duration`, `durationSeconds`, `seconds`, legacy `url`, and explicit `iphoneURL` / `ipadURL`.

Current live manifest media URLs verified on 2026-07-13:

- `https://media.komakode.com/Import-DebtScope.mp4`
- `https://media.komakode.com/Import-DebtScope-3rd-iPad.mp4`
- `https://media.komakode.com/Import-DebtScope-files-iPhone.mp4`
- `https://media.komakode.com/DebtScope-Import- files-iPad.mp4`
- `https://media.komakode.com/DebtScope-Strategy-iPhone.mp4`
- `https://media.komakode.com/DebtScope-Strategy-iPad.mp4`
- `https://media.komakode.com/Net-Worth-iPhone.mp4`
- `https://media.komakode.com/Net-Worth-iPad.mp4`
- `https://media.komakode.com/DebtScope-AI-iPhone.mp4`
- `https://media.komakode.com/DebtScope-AI-iPad.mp4`

Known literal-space media URL:

- The manifest currently contains `https://media.komakode.com/DebtScope-Import- files-iPad.mp4`.
- Swift `URL` decoding/handling percent-encodes the literal space when making requests, reaching `https://media.komakode.com/DebtScope-Import-%20files-iPad.mp4`.
- Do not "clean up" this URL in the manifest or app without first deploying and verifying the replacement media and preserving compatibility for released/cached app versions.

Website maintenance requirements:

- Keep `/videos/DebtScope-help-videos.json` available.
- Keep the manifest as a top-level array.
- Keep `id`, `title`, `subtitle`, `urls.iphone`, and `urls.ipad` compatible.
- Deploy and verify media files before changing manifest URLs.
- Active media URLs must remain reachable while released or cached app versions may still reference them.
- Adding optional fields is safe; removing or renaming existing fields is not safe without an app migration.

Safe testing:

- Use `GET https://komakode.com/videos/DebtScope-help-videos.json` and verify a `200` JSON array.
- Validate every `urls.iphone` and `urls.ipad` value with a safe `HEAD` or byte-range `GET`.
- For the literal-space URL, verify both the manifest string and the percent-encoded request target remain reachable.
- In the app, open Help Videos on iPhone and iPad layouts and confirm the list loads and videos play.

Older released app versions:

- Yes. Older builds may continue fetching the same manifest and may retain cached media URLs.

## Purchase Analytics Ingestion

Production endpoint:

- `https://komakode.com/api/debtscope/purchase-events`

Where referenced in app source:

- `DebtScope/Models/PurchaseAnalytics.swift`
  - Defines event enums and `PurchaseAnalyticsEvent`.
  - Defines install ID and analytics preference keys.
  - Defines `PurchaseAnalyticsClient.defaultEndpointURL`.
  - Builds and sends `URLRequest` instances.
  - Encodes the JSON request body.
  - Queues and retries unsent events in memory.
- `DebtScope/Models/PurchaseManager.swift`
  - Creates purchase analytics events for paywall impressions, purchase taps/results, restore taps/results, and product-load results.
  - Supplies the random install ID, per-session ID, paywall source, result values, storefront country, app/build/platform/OS/channel defaults.
- `DebtScope/Models/SettingsStore.swift`
  - Persists the opt-out preference with `analytics_enabled`.
- `DebtScope/Utils/SettingsView.swift`
  - Shows the `Share purchase analytics` toggle and reset-default behavior.
- `DebtScope/Testing/PurchaseAnalyticsTests.swift`
  - Tests encoding, preference defaults, suppression, queue behavior, and POST construction with a stub endpoint.

Feature:

- Privacy-preserving purchase and StoreKit reliability analytics.

Compatibility classification:

- Protected app-facing compatibility endpoint.
- This route must not be removed, redirected, shadowed, replaced by a website page, or claimed by a static site deployment without verifying the authoritative Cloudflare Worker and released-app behavior.

Current app request behavior from Swift source:

- Method: `POST`.
- URL: `https://komakode.com/api/debtscope/purchase-events`.
- Timeout: request timeout set to `5` seconds; default ephemeral session has request timeout `5` seconds and resource timeout `10` seconds.
- Headers:
  - `Content-Type: application/json`
- Authentication/key behavior:
  - The app does not add an Authorization header, dashboard token, review key, admin key, or API key to the purchase-event POST.
  - No production POST should be sent as part of documentation maintenance.
- Body encoding:
  - `JSONEncoder().encode(event)`.
  - Field names are the Swift property names listed below.
- Response decoding:
  - The app does not decode the response body.
  - Any HTTP status outside `200...299` is treated as `URLError(.badServerResponse)`.
- Retry/error behavior:
  - `track(_:)` returns immediately if analytics is disabled or suppressed.
  - Enabled events are enqueued in an in-memory `PurchaseAnalyticsQueue`.
  - `flush()` sends pending events in order.
  - On the first send failure, that event and all remaining pending events stay queued.
  - The queue keeps at most 50 events and purges events older than 3 days.
  - Analytics is suppressed for Xcode previews and when XCTest is present.

Current app request-body fields:

- `installId`
- `sessionId`
- `eventName`
- `paywallSource`
- `purchaseResult`
- `productLoadResult`
- `productLoadState`
- `storefrontCountry`
- `appVersion`
- `buildNumber`
- `platform`
- `osVersion`
- `channel`

Current app values/allowlists:

- `eventName`: `paywall_impression`, `purchase_button_tap`, `purchase_result`, `product_load_result`, `restore_tap`, `restore_result`
- `purchaseResult`: `success`, `cancelled`, `pending`, `unverified`, `failed`, `restored`, `none_found`
- `productLoadResult`: `loaded`, `empty`, `failed`
- `productLoadState`: `idle`, `loading`, `loaded`, `empty`, `failed`
- `channel`: `production`, `testflight`, `debug`, `sandbox`
- `paywallSource`: defined by `PaywallSource`; Worker allowlists include `fifthImport`, `externalImport`, `settings`, `about`, `backupRestore`, `payoffResult`, `assistant`, `unknown`.

Analytics preference and install ID:

- `PurchaseAnalyticsInstallID` stores a random UUID in `UserDefaults` under `purchase_analytics_install_id`.
- `PurchaseAnalyticsAppInfo.analyticsEnabledKey` is `analytics_enabled`.
- Distributed TestFlight and production defaults are enabled; debug and sandbox defaults are disabled.
- `SettingsStore.analyticsEnabled` persists the opt-out setting.
- `SettingsView` lets the user turn `Share purchase analytics` on or off.
- Resetting app data sets analytics back to `PurchaseAnalyticsAppInfo.defaultAnalyticsEnabled`.

Review/admin key behavior:

- No review/admin key entry, storage, prefill, or transmission was found in the DebtScope iOS app source for purchase-event POSTs.
- Worker-side dashboard/reporting access uses `DASHBOARD_TOKEN` as a Cloudflare Worker secret/configuration role, not as an app-stored secret.
- `Cloudflare/PurchaseAnalytics/src/index.js` accepts dashboard/reporting authorization via `Authorization: Bearer`, `X-DebtScope-Dashboard-Token`, or `?token=`.
- `Cloudflare/PurchaseAnalytics/README.md` says to set `INSTALL_ID_PEPPER` and `DASHBOARD_TOKEN` with Wrangler secrets.
- The alternate `debtscope-purchase-analytics/src/index.ts` summary route accepts `Authorization: Bearer <DASHBOARD_TOKEN>`.
- No secret value is documented here.

Worker/backend references in repository:

- `Cloudflare/PurchaseAnalytics/wrangler.toml`
  - `komakode.com/api/debtscope/purchase-events`
  - `komakode.com/api/debtscope/purchase-summary`
  - `komakode.com/debtscope/purchase-analytics`
- `Cloudflare/PurchaseAnalytics/src/index.js`
  - Routes `/api/debtscope/purchase-events`, `/api/debtscope/purchase-summary`, and `/debtscope/purchase-analytics`.
  - Validates JSON content type, request size, install ID, enums, optional country/app/build/platform/OS/channel fields.
  - Hashes `installId` with `INSTALL_ID_PEPPER`.
  - Stores events in Cloudflare D1 binding `PURCHASE_ANALYTICS_DB`.
  - Returns JSON such as `{ "ok": true, "stored": true }` when stored.
- `debtscope-purchase-analytics/wrangler.jsonc`
  - Routes `komakode.com/api/debtscope/*` and `komakode.com/debtscope/purchase-analytics`.
- `debtscope-purchase-analytics/src/index.ts`
  - Alternate TypeScript Worker implementation for the same route family.
  - Uses D1 binding `DB` and `DASHBOARD_TOKEN`.

Website maintenance requirements:

- Do not remove, redirect, shadow, or replace `/api/debtscope/purchase-events` without verifying released app behavior and the authoritative Worker.
- A normal website deployment must not claim `komakode.com/api/debtscope/*`.
- Keep accepting the current JSON field names and enum values.
- Backend changes should ignore unknown fields where possible and continue accepting currently shipped fields.
- Keep the endpoint tolerant of app versions that do not decode the body and only require a `2xx` status for success.

Safe testing:

- Do not send a production POST for documentation-only work.
- Use unit tests with a stub `PurchaseAnalyticsHTTPSession` or a non-production endpoint.
- For production routing, use non-mutating route checks only, such as verifying Worker route ownership and allowed methods.
- If Worker-side validation must be tested, use a staging Worker/D1 database or an explicit TestFlight smoke check approved for analytics validation.

Older released app versions:

- Yes. Released apps may continue POSTing the current payload shape to this exact endpoint.

Unresolved Worker-side questions:

- This repository contains two overlapping Worker implementations/configurations: `Cloudflare/PurchaseAnalytics` and `debtscope-purchase-analytics`.
- The authoritative production Worker, active route precedence, deployed code version, D1 binding, and exact live validation behavior require Worker-side verification before any backend or website routing change.

## Privacy, Support, And Terms

Support URL:

- `mailto:support@komakode.com?subject=Debt%20Scope%20support`
- Referenced in `DebtScope/View/AboutView.swift` as `supportURL`.
- Feature: About screen Support button.
- Expected behavior: opens the user's mail client with the Debt Scope support subject.
- Permanent compatibility contract: yes, because released apps expose this link.
- Must remain stable: mailbox must continue accepting or forwarding support mail.
- Safe testing: open from a local app build or verify the `mailto:` URL without sending mail.
- Older released app versions may depend on it: yes.

Privacy policy URL:

- `https://komakode.com/Privacy%20Policy`
- Referenced in `DebtScope/View/AboutView.swift` as `privacyPolicyURL`.
- Feature: About screen Privacy Policy button.
- Expected response: human-readable privacy policy page.
- Permanent compatibility contract: yes, because released apps expose this exact path.
- Must remain stable: the path must remain reachable or redirect to the canonical privacy policy without changing app-visible behavior.
- Safe testing: `GET` in a browser and verify the legal page loads.
- Older released app versions may depend on it: yes.
- Do not edit legal wording as part of endpoint maintenance.

Terms URL:

- `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`
- Referenced in `DebtScope/View/AboutView.swift` as `termsOfUseURL`.
- This is an Apple-hosted URL, not KomoKode-controlled, but it is visible in the app.

## StoreKit Product ID

- `com.komakode.awaremoney.lifetime`
- Referenced in `DebtScope/Models/PurchaseManager.swift` as the lifetime product ID.
- Feature: StoreKit non-consumable lifetime premium purchase.
- This is not a website URL, but it is a permanent commerce compatibility identifier.
- Do not rename without a StoreKit migration/release strategy.

## Documentation-Only KomoKode References

These are not current app runtime dependencies, but they should remain aligned with the actual implementation:

- `DebtScope/Docs/PurchAnalyticsImpPlan.md`
  - Mentions `komakode.com`, `/api/debtscope/purchase-events`, `analytics.komakode.com`, and `https://komakode.com/debtscope/purchase-analytics`.
- `DebtScope/Docs/PurchaseAnalyticsPrivacyDisclosures.md`
  - Documents privacy policy and App Store disclosure decisions for purchase analytics at `komakode.com`.
- `Cloudflare/PurchaseAnalytics/README.md`
  - Documents the production purchase analytics Worker route and dashboard token roles.

## Search Notes

Repository searches were run for:

- `komakode.com`
- `media.komakode.com`
- `purchase-events`
- `purchase analytics`
- `help-videos`
- `URL(string:`
- `URLRequest`
- API/review/admin key terms, including dashboard token and Worker secret names

No ScoreKeep-specific app endpoint references were found in the reviewed DebtScope source.
