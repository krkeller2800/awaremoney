import {
	env,
	createExecutionContext,
	waitOnExecutionContext,
	SELF,
} from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src/index";

const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;

describe("DebtScope purchase analytics worker", () => {
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
