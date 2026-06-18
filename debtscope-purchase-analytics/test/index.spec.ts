import {
	env,
	createExecutionContext,
	waitOnExecutionContext,
	SELF,
} from "cloudflare:test";
import { beforeEach, describe, it, expect } from "vitest";
import worker from "../src/index";

const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;

describe("DebtScope purchase analytics worker", () => {
	beforeEach(async () => {
		await env.DB.prepare(
			`CREATE TABLE IF NOT EXISTS purchase_events (
				id TEXT PRIMARY KEY,
				received_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
				install_id_hash TEXT NOT NULL,
				session_id TEXT,
				event_name TEXT NOT NULL,
				paywall_source TEXT,
				purchase_result TEXT,
				product_load_result TEXT,
				product_load_state TEXT,
				storefront_country TEXT,
				app_version TEXT,
				build_number TEXT,
				platform TEXT,
				os_version TEXT,
				channel TEXT NOT NULL DEFAULT 'production'
			)`
		).run();
		await env.DB.prepare("DELETE FROM purchase_events").run();
	});

	it("returns not_found for unknown routes", async () => {
		const request = new IncomingRequest("http://example.com");
		const ctx = createExecutionContext();
		const response = await worker.fetch(request, env, ctx);
		await waitOnExecutionContext(ctx);

		expect(response.status).toBe(404);
		await expect(response.json()).resolves.toEqual({
			ok: false,
			error: "not_found",
		});
	});

	it("protects the purchase summary endpoint", async () => {
		const request = new IncomingRequest("http://example.com/api/debtscope/purchase-summary");
		const ctx = createExecutionContext();
		const response = await worker.fetch(request, env, ctx);
		await waitOnExecutionContext(ctx);

		expect(response.status).toBe(401);
		await expect(response.json()).resolves.toEqual({
			ok: false,
			error: "unauthorized",
		});
	});

	it("serves the purchase analytics dashboard", async () => {
		const request = new IncomingRequest("http://example.com/debtscope/purchase-analytics");
		const ctx = createExecutionContext();
		const response = await worker.fetch(request, env, ctx);
		await waitOnExecutionContext(ctx);

		expect(response.status).toBe(200);
		expect(response.headers.get("content-type")).toContain("text/html");
		await expect(response.text()).resolves.toContain("DebtScope Purchase Analytics");
	});

	it("returns the expanded purchase summary with dashboard tables", async () => {
		await SELF.fetch("https://example.com/api/debtscope/purchase-events", {
			method: "POST",
			headers: {
				"content-type": "application/json",
			},
			body: JSON.stringify({
				installId: "summary-install-id",
				eventName: "paywall_impression",
				paywallSource: "settings",
				channel: "debug",
			}),
		});

		const response = await SELF.fetch("https://example.com/api/debtscope/purchase-summary", {
			headers: {
				authorization: `Bearer ${env.DASHBOARD_TOKEN}`,
			},
		});

		expect(response.status).toBe(200);
		const body = await response.json();
		expect(body).toMatchObject({
			days: 30,
			paywallImpressions: 1,
			purchaseButtonTaps: 0,
			successfulPurchases: 0,
			cancelledPurchases: 0,
			productLoadFailures: 0,
		});
		expect(body.bySource).toEqual([
			{
				source: "settings",
				impressions: 1,
				purchaseButtonTaps: 0,
				successfulPurchases: 0,
			},
		]);
		expect(body.daily).toEqual([
			expect.objectContaining({
				paywallImpressions: 1,
				productLoadFailures: 0,
			}),
		]);
		expect(body.purchaseResults).toEqual([]);
		expect(body.productLoadByCountry).toEqual([]);
		expect(body.restoreResults).toEqual([]);
	});

	it("rejects invalid purchase event payloads before writing to D1", async () => {
		const request = new IncomingRequest("http://example.com/api/debtscope/purchase-events", {
			method: "POST",
			headers: {
				"content-type": "application/json",
			},
			body: JSON.stringify({
				installId: "test-install-id",
				eventName: "unknown_event",
			}),
		});
		const ctx = createExecutionContext();
		const response = await worker.fetch(request, env, ctx);
		await waitOnExecutionContext(ctx);

		expect(response.status).toBe(400);
		await expect(response.json()).resolves.toEqual({
			ok: false,
			error: "invalid_payload",
		});
	});

	it("returns not_found for unknown routes in integration style", async () => {
		const response = await SELF.fetch("https://example.com");
		expect(response.status).toBe(404);
		await expect(response.json()).resolves.toEqual({
			ok: false,
			error: "not_found",
		});
	});
});
