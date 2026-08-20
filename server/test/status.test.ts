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

/**
 * The operator bypass.
 *
 * It exists so a batch of lessons can be generated for reading and judging
 * without a device's daily limit getting in the way. It is also the only way to
 * make the proxy spend money without limit, so what it does NOT skip matters
 * more than what it does.
 */
describe("operator bypass", () => {
  const lessonBody = (topic: string, window = "three", format = "oneThing") => ({
    window,
    format,
    topic,
    request: modelRequest(),
  });

  async function callAsOperator(options: {
    device: string;
    body: Record<string, unknown>;
    fetcher: typeof fetch;
    token?: string;
    env?: ReturnType<typeof testEnv>;
  }): Promise<Response> {
    const ctx = createExecutionContext();
    const request = new Request("https://proxy.spare.app/v1/lesson", {
      method: "POST",
      headers: {
        "x-spare-device": options.device,
        "content-type": "application/json",
        "x-spare-admin": options.token ?? TOKEN,
      },
      body: JSON.stringify(options.body),
    });
    const response = await worker.fetch(
      request,
      options.env ?? testEnv({ ADMIN_TOKEN: TOKEN }),
      ctx,
      { fetcher: options.fetcher, now: () => NOW },
    );
    const buffered = await response.arrayBuffer();
    await waitOnExecutionContext(ctx);
    return new Response(buffered, { status: response.status, headers: response.headers });
  }

  it("generates past the daily limit", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Batch lesson."))]);
    const device = "operator-batch";

    for (let n = 0; n < 4; n += 1) {
      const response = await callAsOperator({
        device, fetcher, body: lessonBody(`Batch topic ${n}`),
      });
      expect(response.status).toBe(200);
      await response.text();
    }
  });

  it("generates a locked window without a subscription", async () => {
    // A batch has to be able to produce 30-minute courses, which no free device
    // can ask for.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Course."))]);
    const response = await callAsOperator({
      device: "operator-course",
      fetcher,
      body: lessonBody("A course", "thirty", "miniCourse"),
    });
    expect(response.status).toBe(200);
  });

  it("never serves the batch from cache", async () => {
    // A batch exists to produce fresh lessons to judge. Replaying old ones would
    // quietly make it measure nothing.
    const fetcher = fixtureFetch([
      anthropicStreaming(sseLesson("Seeded.")),
      anthropicStreaming(sseLesson("Fresh.")),
    ]);
    await (await call({ fetcher, device: "operator-cache-seed" })).text();

    const response = await callAsOperator({
      device: "operator-cache-reader",
      fetcher,
      body: { window: "three", format: "oneThing", topic: "Why bridges hum", request: modelRequest() },
    });
    expect(response.headers.get("x-spare-cache")).toBeNull();
  });

  it("still obeys the spend ceiling", async () => {
    // The bypass must not be a way to spend without limit. This is the one that
    // decides whether a leaked token is an inconvenience or a bill.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Should not happen."))]);
    const response = await callAsOperator({
      device: "operator-ceiling",
      fetcher,
      body: lessonBody("Past the ceiling"),
      env: testEnv({ ADMIN_TOKEN: TOKEN, MONTHLY_SPEND_CEILING_USD: "0" }),
    });

    expect(response.status).toBe(429);
    expect(await response.json()).toMatchObject({ error: { code: "spendCeilingReached" } });
    expect((fetcher as any).calls).toHaveLength(0);
  });

  it("still obeys the request policy", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Should not happen."))]);
    const response = await callAsOperator({
      device: "operator-policy",
      fetcher,
      body: {
        window: "three",
        format: "oneThing",
        topic: "Cheap model",
        request: modelRequest({ model: "some-other-model" }),
      },
    });
    expect(response.status).toBe(400);
    expect((fetcher as any).calls).toHaveLength(0);
  });

  it("is not granted by a wrong token", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("First."))]);
    const device = "operator-wrong-token";

    const first = await callAsOperator({
      device, fetcher, body: lessonBody("One"), token: "not-the-token",
    });
    expect(first.status).toBe(200);
    await first.text();

    // Metered like any ordinary device, because the token was not accepted.
    const second = await callAsOperator({
      device, fetcher, body: lessonBody("Two"), token: "not-the-token",
    });
    expect(second.status).toBe(402);
    expect(await second.json()).toMatchObject({ error: { code: "dailyLimitReached" } });
  });

  it("is not granted when no token is configured", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("First."))]);
    const device = "operator-unconfigured";
    const env = testEnv({ ADMIN_TOKEN: undefined });

    const first = await callAsOperator({ device, fetcher, body: lessonBody("One"), env });
    expect(first.status).toBe(200);
    await first.text();

    const second = await callAsOperator({ device, fetcher, body: lessonBody("Two"), env });
    expect(second.status).toBe(402);
  });
});
