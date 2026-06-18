/**
 * Welcome to Cloudflare Workers! This is your first worker.
 *
 * - Run `npm run dev` in your terminal to start a development server
 * - Open a browser tab at http://localhost:8787/ to see your worker in action
 * - Run `npm run deploy` to publish your worker
 *
 * Bind resources to your worker in `wrangler.jsonc`. After adding bindings, a type definition for the
 * `Env` object can be regenerated with `npm run cf-typegen`.
 *
 * Learn more at https://developers.cloudflare.com/workers/
 */

export interface Env {
  DB: D1Database;
  INSTALL_ID_PEPPER: string;
  DASHBOARD_TOKEN: string;
}

const eventNames = new Set([
  "paywall_impression",
  "purchase_button_tap",
  "purchase_result",
  "product_load_result",
  "restore_tap",
  "restore_result",
]);

const paywallSources = new Set([
  "fifthImport",
  "externalImport",
  "settings",
  "about",
  "backupRestore",
  "payoffResult",
  "assistant",
  "unknown",
]);

const purchaseResults = new Set([
  "success",
  "cancelled",
  "pending",
  "unverified",
  "failed",
  "restored",
  "none_found",
]);

const productLoadResults = new Set(["loaded", "empty", "failed"]);
const productLoadStates = new Set(["idle", "loading", "loaded", "empty", "failed"]);
const channels = new Set(["production", "testflight", "debug", "sandbox"]);

type Payload = Record<string, unknown>;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/debtscope/purchase-events") {
      return handlePurchaseEvent(request, env);
    }

    if (url.pathname === "/api/debtscope/purchase-summary") {
      return handlePurchaseSummary(request, env);
    }

    return json({ ok: false, error: "not_found" }, 404);
  },
};

async function handlePurchaseEvent(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return json({ ok: false, error: "invalid_content_type" }, 415);
  }

  const body = await request.text();
  if (body.length > 8192) {
    return json({ ok: false, error: "payload_too_large" }, 413);
  }

  let payload: Payload;
  try {
    payload = JSON.parse(body);
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const installId = requiredString(payload.installId, 128);
  const eventName = requiredString(payload.eventName, 64);
  if (!installId || !eventName || !eventNames.has(eventName)) {
    return json({ ok: false, error: "invalid_payload" }, 400);
  }

  const paywallSource = optionalAllowedString(payload.paywallSource, paywallSources, 64);
  const purchaseResult = optionalAllowedString(payload.purchaseResult, purchaseResults, 64);
  const productLoadResult = optionalAllowedString(payload.productLoadResult, productLoadResults, 64);
  const productLoadState = optionalAllowedString(payload.productLoadState, productLoadStates, 64);
  const channel = optionalAllowedString(payload.channel, channels, 32) ?? "production";

  const id = crypto.randomUUID();
  const installIdHash = await sha256Hex(`${env.INSTALL_ID_PEPPER}:${installId}`);

  await env.DB.prepare(
    `INSERT INTO purchase_events (
      id, install_id_hash, session_id, event_name, paywall_source,
      purchase_result, product_load_result, product_load_state,
      storefront_country, app_version, build_number, platform, os_version, channel
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(
      id,
      installIdHash,
      optionalString(payload.sessionId, 128),
      eventName,
      paywallSource,
      purchaseResult,
      productLoadResult,
      productLoadState,
      optionalString(payload.storefrontCountry, 8),
      optionalString(payload.appVersion, 32),
      optionalString(payload.buildNumber, 32),
      optionalString(payload.platform, 32),
      optionalString(payload.osVersion, 32),
      channel
    )
    .run();

  return json({ ok: true });
}

async function handlePurchaseSummary(request: Request, env: Env): Promise<Response> {
  if (request.method !== "GET") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  const auth = request.headers.get("authorization") ?? "";
  if (auth !== `Bearer ${env.DASHBOARD_TOKEN}`) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const url = new URL(request.url);
  const days = clamp(Number(url.searchParams.get("days") ?? "30"), 1, 180);

  const totals = await env.DB.prepare(
    `SELECT
      SUM(CASE WHEN event_name = 'paywall_impression' THEN 1 ELSE 0 END) AS paywallImpressions,
      SUM(CASE WHEN event_name = 'purchase_button_tap' THEN 1 ELSE 0 END) AS purchaseButtonTaps,
      SUM(CASE WHEN event_name = 'purchase_result' AND purchase_result = 'success' THEN 1 ELSE 0 END) AS successfulPurchases,
      SUM(CASE WHEN event_name = 'purchase_result' AND purchase_result = 'cancelled' THEN 1 ELSE 0 END) AS cancelledPurchases,
      SUM(CASE WHEN event_name = 'product_load_result' AND product_load_result = 'failed' THEN 1 ELSE 0 END) AS productLoadFailures
    FROM purchase_events
    WHERE received_at >= datetime('now', ?)`
  )
    .bind(`-${days} days`)
    .first<Record<string, number | null>>();

  const bySource = await env.DB.prepare(
    `SELECT
      COALESCE(paywall_source, 'unknown') AS source,
      SUM(CASE WHEN event_name = 'paywall_impression' THEN 1 ELSE 0 END) AS impressions,
      SUM(CASE WHEN event_name = 'purchase_button_tap' THEN 1 ELSE 0 END) AS purchaseButtonTaps,
      SUM(CASE WHEN event_name = 'purchase_result' AND purchase_result = 'success' THEN 1 ELSE 0 END) AS successfulPurchases
    FROM purchase_events
    WHERE received_at >= datetime('now', ?)
    GROUP BY COALESCE(paywall_source, 'unknown')
    ORDER BY impressions DESC`
  )
    .bind(`-${days} days`)
    .all();

  return json({
    days,
    paywallImpressions: totals?.paywallImpressions ?? 0,
    purchaseButtonTaps: totals?.purchaseButtonTaps ?? 0,
    successfulPurchases: totals?.successfulPurchases ?? 0,
    cancelledPurchases: totals?.cancelledPurchases ?? 0,
    productLoadFailures: totals?.productLoadFailures ?? 0,
    bySource: bySource.results,
  });
}

function requiredString(value: unknown, maxLength: number): string | null {
  const string = optionalString(value, maxLength);
  return string && string.length > 0 ? string : null;
}

function optionalString(value: unknown, maxLength: number): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length <= maxLength ? trimmed : null;
}

function optionalAllowedString(value: unknown, allowed: Set<string>, maxLength: number): string | null {
  const string = optionalString(value, maxLength);
  return string && allowed.has(string) ? string : null;
}

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min;
  return Math.min(Math.max(Math.trunc(value), min), max);
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
    },
  });
}