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

    if (url.pathname === "/debtscope/purchase-analytics") {
      return handlePurchaseDashboard(request);
    }

    if (url.pathname === "/api/debtscope/purchase-events") {
      return handlePurchaseEvent(request, env);
    }

    if (url.pathname === "/api/debtscope/purchase-summary") {
      return handlePurchaseSummary(request, env);
    }

    return json({ ok: false, error: "not_found" }, 404);
  },
};

function handlePurchaseDashboard(request: Request): Response {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  return new Response(request.method === "HEAD" ? null : dashboardHtml, {
    headers: {
      "cache-control": "no-store",
      "content-type": "text/html; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}

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

  const daily = await env.DB.prepare(
    `SELECT
      date(received_at) AS day,
      SUM(CASE WHEN event_name = 'paywall_impression' THEN 1 ELSE 0 END) AS paywallImpressions,
      SUM(CASE WHEN event_name = 'product_load_result' AND product_load_result = 'failed' THEN 1 ELSE 0 END) AS productLoadFailures
    FROM purchase_events
    WHERE received_at >= datetime('now', ?)
    GROUP BY date(received_at)
    ORDER BY day DESC`
  )
    .bind(`-${days} days`)
    .all();

  const purchaseResults = await env.DB.prepare(
    `SELECT
      COALESCE(purchase_result, 'unknown') AS result,
      COUNT(*) AS count
    FROM purchase_events
    WHERE received_at >= datetime('now', ?)
      AND event_name = 'purchase_result'
    GROUP BY COALESCE(purchase_result, 'unknown')
    ORDER BY count DESC`
  )
    .bind(`-${days} days`)
    .all();

  const productLoadByCountry = await env.DB.prepare(
    `SELECT
      COALESCE(storefront_country, 'unknown') AS storefrontCountry,
      SUM(CASE WHEN product_load_result = 'empty' THEN 1 ELSE 0 END) AS emptyResponses,
      SUM(CASE WHEN product_load_result = 'failed' THEN 1 ELSE 0 END) AS failures
    FROM purchase_events
    WHERE received_at >= datetime('now', ?)
      AND event_name = 'product_load_result'
    GROUP BY COALESCE(storefront_country, 'unknown')
    ORDER BY emptyResponses DESC, failures DESC`
  )
    .bind(`-${days} days`)
    .all();

  const restoreResults = await env.DB.prepare(
    `SELECT
      COALESCE(purchase_result, 'tap') AS result,
      COUNT(*) AS count
    FROM purchase_events
    WHERE received_at >= datetime('now', ?)
      AND event_name IN ('restore_tap', 'restore_result')
    GROUP BY COALESCE(purchase_result, 'tap')
    ORDER BY count DESC`
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
    daily: daily.results,
    purchaseResults: purchaseResults.results,
    productLoadByCountry: productLoadByCountry.results,
    restoreResults: restoreResults.results,
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

const dashboardHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>DebtScope Purchase Analytics</title>
  <style>
    :root {
      color-scheme: light dark;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.45;
      background: #f7f8fa;
      color: #1f2933;
    }

    body {
      margin: 0;
      min-width: 320px;
    }

    main {
      max-width: 1120px;
      margin: 0 auto;
      padding: 32px 20px 48px;
    }

    header {
      display: flex;
      align-items: end;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 24px;
    }

    h1, h2 {
      margin: 0;
      letter-spacing: 0;
    }

    h1 {
      font-size: 28px;
      font-weight: 720;
    }

    h2 {
      font-size: 16px;
      font-weight: 680;
    }

    .controls {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
    }

    input, select, button {
      font: inherit;
      border: 1px solid #c8d0d9;
      border-radius: 6px;
      padding: 8px 10px;
      background: #ffffff;
      color: #1f2933;
    }

    input {
      width: min(360px, 100%);
    }

    button {
      cursor: pointer;
      background: #176b87;
      border-color: #176b87;
      color: #ffffff;
      font-weight: 650;
    }

    .status {
      min-height: 22px;
      margin-bottom: 18px;
      color: #52606d;
    }

    .metrics {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
      gap: 12px;
      margin-bottom: 18px;
    }

    .metric, section {
      background: #ffffff;
      border: 1px solid #d9e2ec;
      border-radius: 8px;
    }

    .metric {
      padding: 14px;
    }

    .metric span {
      display: block;
      color: #52606d;
      font-size: 13px;
    }

    .metric strong {
      display: block;
      margin-top: 6px;
      font-size: 28px;
    }

    .sections {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 14px;
    }

    section {
      overflow: hidden;
    }

    section h2 {
      padding: 14px 14px 10px;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 14px;
    }

    th, td {
      padding: 9px 14px;
      border-top: 1px solid #e6edf3;
      text-align: right;
      white-space: nowrap;
    }

    th:first-child, td:first-child {
      text-align: left;
      white-space: normal;
    }

    th {
      color: #52606d;
      font-size: 12px;
      font-weight: 700;
      text-transform: uppercase;
    }

    @media (prefers-color-scheme: dark) {
      :root {
        background: #101820;
        color: #f5f7fa;
      }

      input, select, .metric, section {
        background: #1d2730;
        border-color: #344552;
        color: #f5f7fa;
      }

      th, td {
        border-top-color: #344552;
      }

      .status, .metric span, th {
        color: #b8c4cf;
      }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>DebtScope Purchase Analytics</h1>
      </div>
      <div class="controls">
        <input id="token" type="password" autocomplete="current-password" placeholder="Dashboard token">
        <select id="days" aria-label="Days">
          <option value="7">7 days</option>
          <option value="30" selected>30 days</option>
          <option value="90">90 days</option>
          <option value="180">180 days</option>
        </select>
        <button id="refresh" type="button">Refresh</button>
      </div>
    </header>

    <div id="status" class="status"></div>
    <div id="metrics" class="metrics"></div>
    <div id="sections" class="sections"></div>
  </main>

  <script>
    const tokenInput = document.querySelector("#token");
    const daysInput = document.querySelector("#days");
    const refreshButton = document.querySelector("#refresh");
    const statusElement = document.querySelector("#status");
    const metricsElement = document.querySelector("#metrics");
    const sectionsElement = document.querySelector("#sections");

    tokenInput.value = localStorage.getItem("debtscopeDashboardToken") || "";

    refreshButton.addEventListener("click", loadSummary);
    tokenInput.addEventListener("change", () => {
      localStorage.setItem("debtscopeDashboardToken", tokenInput.value);
    });

    async function loadSummary() {
      const token = tokenInput.value.trim();
      localStorage.setItem("debtscopeDashboardToken", token);

      if (!token) {
        setStatus("Enter the dashboard token.");
        return;
      }

      setStatus("Loading...");
      const response = await fetch("/api/debtscope/purchase-summary?days=" + encodeURIComponent(daysInput.value), {
        headers: { "authorization": "Bearer " + token },
      });

      if (!response.ok) {
        setStatus(response.status === 401 ? "Unauthorized." : "Request failed: " + response.status);
        return;
      }

      const summary = await response.json();
      renderSummary(summary);
      setStatus("Updated for the last " + summary.days + " days.");
    }

    function renderSummary(summary) {
      metricsElement.innerHTML = [
        metric("Paywall impressions", summary.paywallImpressions),
        metric("Purchase taps", summary.purchaseButtonTaps),
        metric("Successful purchases", summary.successfulPurchases),
        metric("Cancelled purchases", summary.cancelledPurchases),
        metric("Product load failures", summary.productLoadFailures),
      ].join("");

      sectionsElement.innerHTML = [
        tableSection("Daily activity", ["Day", "Impressions", "Load failures"], summary.daily, ["day", "paywallImpressions", "productLoadFailures"]),
        tableSection("Paywall sources", ["Source", "Impressions", "Taps", "Purchases"], summary.bySource, ["source", "impressions", "purchaseButtonTaps", "successfulPurchases"]),
        tableSection("Purchase results", ["Result", "Count"], summary.purchaseResults, ["result", "count"]),
        tableSection("Product load by country", ["Country", "Empty", "Failures"], summary.productLoadByCountry, ["storefrontCountry", "emptyResponses", "failures"]),
        tableSection("Restore outcomes", ["Result", "Count"], summary.restoreResults, ["result", "count"]),
      ].join("");
    }

    function metric(label, value) {
      return "<div class=\\"metric\\"><span>" + escapeHtml(label) + "</span><strong>" + number(value) + "</strong></div>";
    }

    function tableSection(title, headings, rows, keys) {
      const safeRows = Array.isArray(rows) ? rows : [];
      const body = safeRows.length
        ? safeRows.map((row) => "<tr>" + keys.map((key) => "<td>" + escapeHtml(formatValue(row[key])) + "</td>").join("") + "</tr>").join("")
        : "<tr><td colspan=\\"" + headings.length + "\\">No data</td></tr>";

      return "<section><h2>" + escapeHtml(title) + "</h2><table><thead><tr>" +
        headings.map((heading) => "<th>" + escapeHtml(heading) + "</th>").join("") +
        "</tr></thead><tbody>" + body + "</tbody></table></section>";
    }

    function formatValue(value) {
      return typeof value === "number" ? number(value) : value ?? "";
    }

    function number(value) {
      return new Intl.NumberFormat().format(value || 0);
    }

    function setStatus(message) {
      statusElement.textContent = message;
    }

    function escapeHtml(value) {
      return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll("\\"", "&quot;")
        .replaceAll("'", "&#039;");
    }
  </script>
</body>
</html>`;
