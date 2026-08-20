/**
 * The status endpoint.
 *
 * It reads the one number the whole design exists to protect, so the tests here
 * are mostly about who is allowed to see it.
 */

import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker from "../src/index";
import { anthropicStreaming, fixtureFetch, sseLesson } from "./fixtures";
import { NOW, call, modelRequest, testEnv } from "./harness";

const TOKEN = "admin-token-for-tests";

async function status(options: {
  token?: string | null;
  device?: string;
  method?: string;
  adminToken?: string | undefined;
} = {}): Promise<Response> {
  const ctx = createExecutionContext();
  const query = options.device ? `?device=${encodeURIComponent(options.device)}` : "";
  const headers: Record<string, string> = {};
  if (options.token !== null && options.token !== undefined) {
    headers["x-spare-admin"] = options.token;
  }
  const response = await worker.fetch(
    new Request(`https://proxy.spare.app/v1/status${query}`, {
      method: options.method ?? "GET",
      headers,
    }),
    testEnv({ ADMIN_TOKEN: "adminToken" in options ? options.adminToken : TOKEN }),
    ctx,
    { fetcher: fixtureFetch([]), now: () => NOW },
  );
  const body = await response.arrayBuffer();
  await waitOnExecutionContext(ctx);
  return new Response(body, { status: response.status, headers: response.headers });
}

describe("status endpoint", () => {
  it("does not exist when no admin token is configured", async () => {
    // 404, not 401. Answering "unauthorized" would confirm the endpoint is
    // there, which is a free hint to anyone scanning.
    const response = await status({ adminToken: undefined, token: TOKEN });
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: { code: "unknownEndpoint" } });
  });

  it("refuses a missing token", async () => {
    const response = await status({ token: null });
    expect(response.status).toBe(401);
  });

  it("refuses a wrong token", async () => {
    expect((await status({ token: "not-the-token" })).status).toBe(401);
  });

  it("refuses a token that is a prefix of the real one", async () => {
    // The comparison must not stop at the first mismatch or at a length
    // difference, and a prefix is the cheapest way to catch a `startsWith`.
    expect((await status({ token: TOKEN.slice(0, 5) })).status).toBe(401);
    expect((await status({ token: TOKEN + "x" })).status).toBe(401);
  });

  it("refuses a write method even with the right token", async () => {
    // Read-only on purpose: a token pasted into a terminal must not be able to
    // reset a counter or unlock free generation.
    expect((await status({ token: TOKEN, method: "POST" })).status).toBe(405);
    expect((await status({ token: TOKEN, method: "DELETE" })).status).toBe(405);
  });

  it("reports the ceiling and a fresh ledger", async () => {
    const response = await status({ token: TOKEN });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      month: "2026-08",
      spentUSD: 0,
      ceilingUSD: 50,
      withinCeiling: true,
      freeGenerationPaused: false,
    });
  });

  it("reports spend after a real generation", async () => {
    // The number has to actually move, or the endpoint is decoration.
    await (await call({
      fetcher: fixtureFetch([anthropicStreaming(sseLesson("Costly lesson."))]),
      device: "status-spender",
      body: { window: "three", format: "oneThing", topic: "Spending", request: modelRequest() },
    })).text();

    const body = (await (await status({ token: TOKEN })).json()) as { spentUSD: number };
    expect(body.spentUSD).toBeGreaterThan(0);
  });

  it("reports one device's counters on request", async () => {
    const device = "status-device-counters";
    await (await call({
      fetcher: fixtureFetch([anthropicStreaming(sseLesson("Counted."))]),
      device,
      body: { window: "three", format: "oneThing", topic: "Counting", request: modelRequest() },
    })).text();

    const body = (await (await status({ token: TOKEN, device })).json()) as {
      device: { id: string; usage: { lessonsToday: number; day: string } };
    };
    expect(body.device.id).toBe(device);
    expect(body.device.usage.lessonsToday).toBe(1);
    expect(body.device.usage.day).toBe("2026-08-17");
  });

  it("says free generation is paused once the ceiling is reached", async () => {
    const ctx = createExecutionContext();
    const response = await worker.fetch(
      new Request("https://proxy.spare.app/v1/status", {
        headers: { "x-spare-admin": TOKEN },
      }),
      testEnv({ ADMIN_TOKEN: TOKEN, MONTHLY_SPEND_CEILING_USD: "0" }),
      ctx,
      { fetcher: fixtureFetch([]), now: () => NOW },
    );
    const body = (await response.json()) as { withinCeiling: boolean; freeGenerationPaused: boolean };
    await waitOnExecutionContext(ctx);

    // Zero spend against a zero ceiling is already over: `spent < ceiling` is
    // false. That is what makes setting the ceiling to 0 a usable way to test
    // the block without spending anything.
    expect(body.withinCeiling).toBe(false);
    expect(body.freeGenerationPaused).toBe(true);
  });

  it("never echoes the token back", async () => {
    const response = await status({ token: TOKEN });
    expect(await response.text()).not.toContain(TOKEN);
  });
});
