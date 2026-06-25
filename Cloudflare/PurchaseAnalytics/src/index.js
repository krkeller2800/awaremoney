const EVENT_NAMES = new Set([
  "paywall_impression",
  "purchase_button_tap",
  "purchase_result",
  "product_load_result",
  "restore_tap",
  "restore_result"
]);

const PAYWALL_SOURCES = new Set([
  "fifthImport",
  "externalImport",
  "settings",
  "about",
  "backupRestore",
  "payoffResult",
  "assistant",
  "unknown"
]);

const PURCHASE_RESULTS = new Set([
  "success",
  "cancelled",
  "pending",
  "unverified",
  "failed",
  "restored",
  "none_found"
]);

const PRODUCT_LOAD_RESULTS = new Set(["loaded", "empty", "failed"]);
const PRODUCT_LOAD_STATES = new Set(["idle", "loading", "loaded", "empty", "failed"]);
const CHANNELS = new Set(["production", "testflight", "debug", "sandbox"]);
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 4096;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return json({ ok: true });
    }

    if (url.pathname === "/api/debtscope/purchase-events") {
      return handlePurchaseEvent(request, env);
    }

    if (url.pathname === "/api/debtscope/purchase-summary") {
      return handlePurchaseSummary(request, env, url);
    }

    if (url.pathname === "/debtscope/purchase-analytics") {
      return handleDashboard(request, env, url);
    }

    return json({ ok: false, error: "not_found" }, 404);
  }
};

async function handlePurchaseEvent(request, env) {
  if (request.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  if (env.ANALYTICS_DISABLED === "true") {
    return json({ ok: true, stored: false });
  }

  const contentType = request.headers.get("content-type") || "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return json({ ok: false, error: "unsupported_media_type" }, 415);
  }

  const contentLength = Number(request.headers.get("content-length") || "0");
  if (contentLength > MAX_BODY_BYTES) {
    return json({ ok: false, error: "payload_too_large" }, 413);
  }

  let payload;
  try {
    const body = await request.text();
    if (new TextEncoder().encode(body).length > MAX_BODY_BYTES) {
      return json({ ok: false, error: "payload_too_large" }, 413);
    }
    payload = JSON.parse(body);
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }

  const event = validateEvent(payload);
  if (!event.ok) {
    return json({ ok: false, error: event.error }, 400);
  }

  const pepper = env.INSTALL_ID_PEPPER;
  if (!pepper) {
    return json({ ok: false, error: "server_not_configured" }, 503);
  }

  await cleanupOldEvents(env);

  const installIdHash = await hashInstallID(event.value.installId, pepper);
  await env.PURCHASE_ANALYTICS_DB.prepare(
    `INSERT INTO purchase_events (
      id,
      install_id_hash,
      session_id,
      event_name,
      paywall_source,
      purchase_result,
      product_load_result,
      product_load_state,
      storefront_country,
      app_version,
      build_number,
      platform,
      os_version,
      channel
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    crypto.randomUUID(),
    installIdHash,
    event.value.sessionId,
    event.value.eventName,
    event.value.paywallSource,
    event.value.purchaseResult,
    event.value.productLoadResult,
    event.value.productLoadState,
    event.value.storefrontCountry,
    event.value.appVersion,
    event.value.buildNumber,
    event.value.platform,
    event.value.osVersion,
    event.value.channel
  ).run();

  return json({ ok: true, stored: true });
}

async function handlePurchaseSummary(request, env, url) {
  if (request.method !== "GET") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  if (!isAuthorized(request, env, url)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const days = clampInteger(url.searchParams.get("days"), 30, 1, 180);
  const sinceModifier = `-${days} days`;

  const totals = await env.PURCHASE_ANALYTICS_DB.prepare(
    `SELECT
      SUM(CASE WHEN event_name = 'paywall_impression' THEN 1 ELSE 0 END) AS paywallImpressions,
      SUM(CASE WHEN event_name = 'purchase_button_tap' THEN 1 ELSE 0 END) AS purchaseButtonTaps,
      SUM(CASE WHEN event_name = 'purchase_result' AND purchase_result = 'success' THEN 1 ELSE 0 END) AS successfulPurchases,
      SUM(CASE WHEN event_name = 'purchase_result' AND purchase_result = 'cancelled' THEN 1 ELSE 0 END) AS cancelledPurchases,
      SUM(CASE WHEN event_name = 'product_load_result' AND product_load_result IN ('empty', 'failed') THEN 1 ELSE 0 END) AS productLoadFailures,
      COUNT(*) AS totalEvents
    FROM purchase_events
    WHERE received_at >= datetime('now', ?)`
  ).bind(sinceModifier).first();

  const bySource = await env.PURCHASE_ANALYTICS_DB.prepare(
    `SELECT
      COALESCE(paywall_source, 'unknown') AS source,
      SUM(CASE WHEN event_name = 'paywall_impression' THEN 1 ELSE 0 END) AS impressions,
      SUM(CASE WHEN event_name = 'purchase_button_tap' THEN 1 ELSE 0 END) AS purchaseButtonTaps,
      SUM(CASE WHEN event_name = 'purchase_result' AND purchase_result = 'success' THEN 1 ELSE 0 END) AS successfulPurchases
    FROM purchase_events
    WHERE received_at >= datetime('now', ?)
    GROUP BY COALESCE(paywall_source, 'unknown')
    ORDER BY impressions DESC, purchaseButtonTaps DESC`
  ).bind(sinceModifier).all();

  const byChannel = await env.PURCHASE_ANALYTICS_DB.prepare(
    `SELECT
      channel,
      COUNT(*) AS totalEvents
    FROM purchase_events
    WHERE received_at >= datetime('now', ?)
    GROUP BY channel
    ORDER BY totalEvents DESC`
  ).bind(sinceModifier).all();

  return json({
    days,
    paywallImpressions: numberValue(totals?.paywallImpressions),
    purchaseButtonTaps: numberValue(totals?.purchaseButtonTaps),
    successfulPurchases: numberValue(totals?.successfulPurchases),
    cancelledPurchases: numberValue(totals?.cancelledPurchases),
    productLoadFailures: numberValue(totals?.productLoadFailures),
    totalEvents: numberValue(totals?.totalEvents),
    bySource: (bySource.results || []).map(row => ({
      source: row.source,
      impressions: numberValue(row.impressions),
      purchaseButtonTaps: numberValue(row.purchaseButtonTaps),
      successfulPurchases: numberValue(row.successfulPurchases)
    })),
    byChannel: byChannel.results || []
  });
}

function handleDashboard(request, env, url) {
  if (request.method !== "GET") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  if (!isAuthorized(request, env, url)) {
    return new Response("Unauthorized", {
      status: 401,
      headers: { "www-authenticate": "Bearer" }
    });
  }

  const token = url.searchParams.get("token") || "";
  return new Response(dashboardHTML(token), {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  });
}

function validateEvent(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return { ok: false, error: "invalid_payload" };
  }

  const installId = stringField(payload.installId, 36);
  if (!installId || !UUID_PATTERN.test(installId)) {
    return { ok: false, error: "invalid_install_id" };
  }

  const eventName = enumField(payload.eventName, EVENT_NAMES);
  if (!eventName) {
    return { ok: false, error: "invalid_event_name" };
  }

  const event = {
    installId,
    sessionId: optionalStringField(payload.sessionId, 64),
    eventName,
    paywallSource: optionalEnumField(payload.paywallSource, PAYWALL_SOURCES),
    purchaseResult: optionalEnumField(payload.purchaseResult, PURCHASE_RESULTS),
    productLoadResult: optionalEnumField(payload.productLoadResult, PRODUCT_LOAD_RESULTS),
    productLoadState: optionalEnumField(payload.productLoadState, PRODUCT_LOAD_STATES),
    storefrontCountry: optionalCountryField(payload.storefrontCountry),
    appVersion: optionalStringField(payload.appVersion, 32),
    buildNumber: optionalStringField(payload.buildNumber, 32),
    platform: optionalStringField(payload.platform, 16) || "iOS",
    osVersion: optionalStringField(payload.osVersion, 32),
    channel: optionalEnumField(payload.channel, CHANNELS) || "production"
  };

  if (payload.paywallSource != null && event.paywallSource == null) {
    return { ok: false, error: "invalid_paywall_source" };
  }
  if (payload.purchaseResult != null && event.purchaseResult == null) {
    return { ok: false, error: "invalid_purchase_result" };
  }
  if (payload.productLoadResult != null && event.productLoadResult == null) {
    return { ok: false, error: "invalid_product_load_result" };
  }
  if (payload.productLoadState != null && event.productLoadState == null) {
    return { ok: false, error: "invalid_product_load_state" };
  }
  if (payload.channel != null && event.channel == null) {
    return { ok: false, error: "invalid_channel" };
  }

  return { ok: true, value: event };
}

function stringField(value, maxLength) {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maxLength) {
    return null;
  }
  return trimmed;
}

function optionalStringField(value, maxLength) {
  if (value == null) {
    return null;
  }
  return stringField(value, maxLength);
}

function enumField(value, allowedValues) {
  if (typeof value !== "string" || !allowedValues.has(value)) {
    return null;
  }
  return value;
}

function optionalEnumField(value, allowedValues) {
  if (value == null) {
    return null;
  }
  return enumField(value, allowedValues);
}

function optionalCountryField(value) {
  if (value == null) {
    return null;
  }
  if (typeof value !== "string" || !/^[A-Z]{2}$/.test(value)) {
    return null;
  }
  return value;
}

async function hashInstallID(installId, pepper) {
  const encoded = new TextEncoder().encode(`${pepper}:${installId}`);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return [...new Uint8Array(digest)]
    .map(byte => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function cleanupOldEvents(env) {
  const days = clampInteger(env.MAX_EVENT_AGE_DAYS, 180, 1, 365);
  await env.PURCHASE_ANALYTICS_DB.prepare(
    "DELETE FROM purchase_events WHERE received_at < datetime('now', ?)"
  ).bind(`-${days} days`).run();
}

function isAuthorized(request, env, url) {
  const expected = env.DASHBOARD_TOKEN;
  if (!expected) {
    return false;
  }

  const auth = request.headers.get("authorization") || "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
  const headerToken = request.headers.get("x-debtscope-dashboard-token") || "";
  const queryToken = url.searchParams.get("token") || "";
  return bearer === expected || headerToken === expected || queryToken === expected;
}

function clampInteger(rawValue, defaultValue, min, max) {
  const parsed = Number.parseInt(rawValue, 10);
  if (!Number.isFinite(parsed)) {
    return defaultValue;
  }
  return Math.max(min, Math.min(max, parsed));
}

function numberValue(value) {
  return Number(value || 0);
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  });
}

function dashboardHTML(token) {
  const tokenJSON = JSON.stringify(token);
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>DebtScope Purchase Analytics</title>
  <style>
    :root {
      color-scheme: light dark;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.4;
    }
    body {
      margin: 0;
      padding: 32px;
      background: Canvas;
      color: CanvasText;
    }
    main {
      max-width: 980px;
      margin: 0 auto;
    }
    h1 {
      margin: 0 0 20px;
      font-size: 28px;
    }
    .toolbar {
      display: flex;
      gap: 12px;
      align-items: center;
      margin-bottom: 20px;
    }
    input, button {
      font: inherit;
      padding: 8px 10px;
    }
    .metrics {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
      gap: 12px;
      margin-bottom: 24px;
    }
    .metric, table {
      border: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
      border-radius: 8px;
      background: color-mix(in srgb, Canvas 92%, CanvasText 8%);
    }
    .metric {
      padding: 14px;
    }
    .metric strong {
      display: block;
      font-size: 24px;
      margin-bottom: 2px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      overflow: hidden;
    }
    th, td {
      padding: 10px 12px;
      border-bottom: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
      text-align: left;
    }
    th {
      font-size: 13px;
    }
    .status {
      color: color-mix(in srgb, CanvasText 72%, transparent);
      min-height: 20px;
    }
  </style>
</head>
<body>
  <main>
    <h1>DebtScope Purchase Analytics</h1>
    <div class="toolbar">
      <label>Days <input id="days" type="number" min="1" max="180" value="30"></label>
      <button id="refresh">Refresh</button>
      <span id="status" class="status"></span>
    </div>
    <section id="metrics" class="metrics"></section>
    <table>
      <thead>
        <tr>
          <th>Source</th>
          <th>Impressions</th>
          <th>Purchase Taps</th>
          <th>Purchases</th>
        </tr>
      </thead>
      <tbody id="sources"></tbody>
    </table>
  </main>
  <script>
    const token = ${tokenJSON};
    const metrics = document.getElementById("metrics");
    const sources = document.getElementById("sources");
    const status = document.getElementById("status");
    const days = document.getElementById("days");

    document.getElementById("refresh").addEventListener("click", load);
    load();

    async function load() {
      status.textContent = "Loading...";
      const response = await fetch(\`/api/debtscope/purchase-summary?days=\${encodeURIComponent(days.value)}&token=\${encodeURIComponent(token)}\`, {
        cache: "no-store"
      });
      if (!response.ok) {
        status.textContent = \`Failed: \${response.status}\`;
        return;
      }
      const data = await response.json();
      metrics.innerHTML = [
        ["Paywall Impressions", data.paywallImpressions],
        ["Purchase Taps", data.purchaseButtonTaps],
        ["Successful Purchases", data.successfulPurchases],
        ["Cancelled Purchases", data.cancelledPurchases],
        ["Product Load Failures", data.productLoadFailures],
        ["Total Events", data.totalEvents]
      ].map(([label, value]) => \`<div class="metric"><strong>\${value}</strong><span>\${label}</span></div>\`).join("");
      sources.innerHTML = data.bySource.map(row => \`
        <tr>
          <td>\${escapeHTML(row.source)}</td>
          <td>\${row.impressions}</td>
          <td>\${row.purchaseButtonTaps}</td>
          <td>\${row.successfulPurchases}</td>
        </tr>
      \`).join("");
      status.textContent = \`Showing last \${data.days} days\`;
    }

    function escapeHTML(value) {
      return String(value).replace(/[&<>"']/g, character => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;"
      }[character]));
    }
  </script>
</body>
</html>`;
}
