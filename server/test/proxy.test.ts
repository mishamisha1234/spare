import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker from "../src/index";
import {
  anthropicJSON,
  anthropicStreaming,
  appleProduction,
  appleSandbox,
  fixtureFetch,
  jsonMessage,
  sseLesson,
  subscriptionStatus,
} from "./fixtures";
import { NOW, call, modelRequest, premiumReceipt, testEnv } from "./harness";

function premiumRoutes(sse: string) {
  return [
    appleProduction(
      subscriptionStatus({
        productId: "app.spare.premium.yearly",
        status: 1,
        expiresDate: NOW + 30 * 86_400_000,
      }),
    ),
    anthropicStreaming(sse),
  ];
}

describe("the key never leaves the server", () => {
  it("sends the key upstream and never back to the client", async () => {
    let sentKey: string | null = null;
    const fetcher = fixtureFetch([
      {
        match: (url) => url.includes("api.anthropic.com"),
        respond: (_url, init) => {
          sentKey = new Headers(init?.headers).get("x-api-key");
          return new Response(sseLesson("Body."), { headers: { "content-type": "text/event-stream" } });
        },
      },
    ]);

    const response = await call({ fetcher });
    const text = await response.text();

    expect(sentKey).toBe("sk-ant-fixture-key");
    expect(text).not.toContain("sk-ant");
    expect([...response.headers.keys()].join()).not.toContain("api-key");
  });

  it("does not leak an upstream error body to the client", async () => {
    // Anthropic errors can name the account, the model, or the key's shape.
    const fetcher = fixtureFetch([
      anthropicJSON(JSON.stringify({ error: { message: "invalid x-api-key sk-ant-abc123" } }), 401),
    ]);
    const response = await call({ fetcher });
    const text = await response.text();

    expect(response.status).toBe(502);
    expect(text).not.toContain("sk-ant");
    expect(text).not.toContain("invalid x-api-key");
  });
});

describe("streaming passes through intact", () => {
  it("delivers the SSE body byte-for-byte", async () => {
    // The whole reason the proxy exists in this shape: RevisionGate's
    // invariants are defined over the event sequence, so re-framing here
    // would break the reader's append-only guarantee.
    const sse = sseLesson("On June 10, 2000 the bridge swayed. Then it closed.");
    const fetcher = fixtureFetch([anthropicStreaming(sse)]);

    const response = await call({ fetcher });
    expect(await response.text()).toBe(sse);
  });

  it("keeps the event order", async () => {
    const sse = sseLesson("Ordered.");
    const fetcher = fixtureFetch([anthropicStreaming(sse)]);
    const body = await (await call({ fetcher })).text();

    const events = [...body.matchAll(/event: (\w+)/g)].map((match) => match[1]);
    expect(events[0]).toBe("message_start");
    expect(events.at(-1)).toBe("message_stop");
    expect(events.filter((name) => name === "content_block_delta").length).toBeGreaterThan(1);
  });

  it("does not buffer the stream into one chunk", async () => {
    const sse = sseLesson("a".repeat(4000));
    const fetcher = fixtureFetch([anthropicStreaming(sse)]);
    const response = await call({ fetcher });

    const reader = response.body!.getReader();
    let chunks = 0;
    while (true) {
      const { done } = await reader.read();
      if (done) break;
      chunks += 1;
    }
    expect(chunks).toBeGreaterThan(1);
  });
});

describe("free tier is enforced server-side", () => {
  it("allows the first lesson and refuses the second the same day", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("First."))]);
    const device = "free-device-1";

    const first = await call({ fetcher, device });
    expect(first.status).toBe(200);
    await first.text();

    // A different topic, so the cache can't be what refuses it.
    const second = await call({
      fetcher,
      device,
      body: { window: "three", format: "oneThing", topic: "Something else entirely", request: modelRequest() },
    });
    expect(second.status).toBe(402);
    expect(await second.json()).toMatchObject({ error: { code: "dailyLimitReached" } });
  });

  it("refuses a locked window before spending anything", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Should not be reached."))]);
    const response = await call({
      fetcher,
      device: "free-device-2",
      body: { window: "thirty", format: "miniCourse", topic: "A course", request: modelRequest() },
    });

    expect(response.status).toBe(402);
    expect(await response.json()).toMatchObject({ error: { code: "lockedWindow" } });
    expect((fetcher as any).calls).toHaveLength(0);
  });

  it("resets the next day", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Daily."))]);
    const device = "free-device-3";

    await (await call({ fetcher, device })).text();
    const tomorrow = await call({
      fetcher,
      device,
      now: NOW + 86_400_000,
      body: { window: "three", format: "oneThing", topic: "Another topic", request: modelRequest() },
    });
    expect(tomorrow.status).toBe(200);
  });

  /**
   * The reason counters are Durable Objects and not KV. On KV both requests
   * read 0, both pass, and the limit silently leaks.
   */
  it("holds the limit under concurrent requests", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Race."))]);
    const device = "free-device-race";

    const results = await Promise.all(
      [1, 2, 3, 4].map((n) =>
        call({
          fetcher,
          device,
          body: { window: "three", format: "oneThing", topic: `Distinct topic ${n}`, request: modelRequest() },
        }),
      ),
    );
    const allowed = results.filter((response) => response.status === 200);
    expect(allowed).toHaveLength(1);
  });
});

describe("premium", () => {
  it("is granted only after Apple confirms the subscription", async () => {
    const fetcher = fixtureFetch(premiumRoutes(sseLesson("Course chapter.")));
    const response = await call({
      fetcher,
      device: "premium-device-1",
      body: {
        window: "thirty",
        format: "miniCourse",
        topic: "How planes got safe",
        receipt: premiumReceipt,
        request: modelRequest(),
      },
    });

    expect(response.status).toBe(200);
    expect((fetcher as any).calls.some((url: string) => url.includes("storekit"))).toBe(true);
  });

  it("is refused when Apple reports the subscription expired", async () => {
    const fetcher = fixtureFetch([
      appleProduction(
        subscriptionStatus({
          productId: "app.spare.premium.yearly",
          status: 2,
          expiresDate: NOW - 86_400_000,
        }),
      ),
      anthropicStreaming(sseLesson("Should not be reached.")),
    ]);

    const response = await call({
      fetcher,
      device: "premium-device-2",
      body: { window: "thirty", format: "miniCourse", topic: "A course", receipt: premiumReceipt, request: modelRequest() },
    });
    expect(response.status).toBe(402);
    expect(await response.json()).toMatchObject({ error: { code: "lockedWindow" } });
  });

  it("falls back to the sandbox host for a TestFlight purchase", async () => {
    // Without this, every internal build reads as unsubscribed — which looks
    // like a verification bug and is not one.
    const fetcher = fixtureFetch([
      appleProduction(JSON.stringify({ errorCode: 4040010 }), 404),
      appleSandbox(
        subscriptionStatus({
          productId: "app.spare.premium.monthly",
          status: 1,
          expiresDate: NOW + 86_400_000,
        }),
      ),
      anthropicStreaming(sseLesson("Sandbox course.")),
    ]);

    const response = await call({
      fetcher,
      device: "premium-device-3",
      body: { window: "thirty", format: "miniCourse", topic: "Sandbox topic", receipt: premiumReceipt, request: modelRequest() },
    });
    expect(response.status).toBe(200);
  });

  /** An outage must not hand out paid content, and must not silently downgrade. */
  it("fails closed and retryable when verification is unavailable", async () => {
    const fetcher = fixtureFetch([
      appleProduction(JSON.stringify({ errorCode: 5000000 }), 500),
      anthropicStreaming(sseLesson("Should not be reached.")),
    ]);

    const response = await call({
      fetcher,
      device: "premium-device-4",
      body: { window: "thirty", format: "miniCourse", topic: "Outage", receipt: premiumReceipt, request: modelRequest() },
    });

    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ error: { code: "verificationUnavailable" } });
  });

  it("caps courses per month", async () => {
    const fetcher = fixtureFetch(premiumRoutes(sseLesson("Course.")));
    const device = "premium-device-cap";

    for (let n = 0; n < 12; n += 1) {
      const response = await call({
        fetcher,
        device,
        body: {
          window: "thirty",
          format: "miniCourse",
          topic: `Course number ${n}`,
          receipt: premiumReceipt,
          request: modelRequest(),
        },
      });
      expect(response.status).toBe(200);
      await response.text();
    }

    const thirteenth = await call({
      fetcher,
      device,
      body: { window: "thirty", format: "miniCourse", topic: "One too many", receipt: premiumReceipt, request: modelRequest() },
    });
    expect(thirteenth.status).toBe(402);
    expect(await thirteenth.json()).toMatchObject({ error: { code: "courseCapReached" } });
  });

  it("does not meter premium against the free daily limit", async () => {
    const fetcher = fixtureFetch(premiumRoutes(sseLesson("Unlimited.")));
    const device = "premium-device-daily";

    for (let n = 0; n < 3; n += 1) {
      const response = await call({
        fetcher,
        device,
        body: { window: "ten", format: "explainer", topic: `Topic ${n}`, receipt: premiumReceipt, request: modelRequest() },
      });
      expect(response.status).toBe(200);
      await response.text();
    }
  });
});

describe("the lesson cache", () => {
  it("serves a free user a cached lesson without spending their allowance", async () => {
    const sse = sseLesson("Cached body.");
    const fetcher = fixtureFetch([anthropicStreaming(sse)]);

    // First device generates and populates the cache.
    await (await call({ fetcher, device: "cache-seed-device" })).text();

    // A second device, same topic: served from cache, no upstream call, and
    // its own daily allowance is still intact afterwards.
    const callsBefore = (fetcher as any).calls.length;
    const cached = await call({ fetcher, device: "cache-reader-device" });
    expect(cached.headers.get("x-spare-cache")).toBe("hit");
    expect((fetcher as any).calls.length).toBe(callsBefore);

    const stillAllowed = await call({
      fetcher,
      device: "cache-reader-device",
      body: { window: "three", format: "oneThing", topic: "A completely different subject", request: modelRequest() },
    });
    expect(stillAllowed.status).toBe(200);
  });

  it("collides on topics that differ only by wording", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Shared."))]);
    await (await call({ fetcher, device: "wording-a" })).text();

    const callsBefore = (fetcher as any).calls.length;
    const restated = await call({
      fetcher,
      device: "wording-b",
      body: { window: "three", format: "oneThing", topic: "How do bridges hum?", request: modelRequest() },
    });
    expect(restated.headers.get("x-spare-cache")).toBe("hit");
    expect((fetcher as any).calls.length).toBe(callsBefore);
  });

  it("never serves a cached lesson to premium", async () => {
    const fetcher = fixtureFetch(premiumRoutes(sseLesson("Fresh for premium.")));
    await (await call({ fetcher, device: "cache-premium-seed" })).text();

    const callsBefore = (fetcher as any).calls.length;
    const premium = await call({
      fetcher,
      device: "cache-premium-reader",
      body: { window: "three", format: "oneThing", topic: "Why bridges hum", receipt: premiumReceipt, request: modelRequest() },
    });
    expect(premium.headers.get("x-spare-cache")).toBeNull();
    expect((fetcher as any).calls.length).toBeGreaterThan(callsBefore);
  });

  it("does not cache a truncated stream", async () => {
    // Caching a truncation would serve it to everyone who asks next.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Cut off", { complete: false }))]);
    await (await call({ fetcher, device: "truncated-device" })).text();

    const callsBefore = (fetcher as any).calls.length;
    await (await call({ fetcher, device: "truncated-reader" })).text();
    expect((fetcher as any).calls.length).toBeGreaterThan(callsBefore);
  });
});

describe("the spend ceiling", () => {
  it("throttles free generation once the ceiling is reached", async () => {
    const tinyCeiling = testEnv({ MONTHLY_SPEND_CEILING_USD: "0" });
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Should not generate."))]);

    const response = await call({
      fetcher,
      env: tinyCeiling,
      device: "ceiling-device",
      body: { window: "three", format: "oneThing", topic: "Uncached topic", request: modelRequest() },
    });

    expect(response.status).toBe(429);
    expect(await response.json()).toMatchObject({ error: { code: "spendCeilingReached" } });
  });

  it("keeps serving premium past the ceiling", async () => {
    // Those requests are verified and paid for; cutting them off would punish
    // the people funding the thing.
    const tinyCeiling = testEnv({ MONTHLY_SPEND_CEILING_USD: "0" });
    const fetcher = fixtureFetch(premiumRoutes(sseLesson("Premium still works.")));

    const response = await call({
      fetcher,
      env: tinyCeiling,
      device: "ceiling-premium",
      body: { window: "ten", format: "explainer", topic: "Paid topic", receipt: premiumReceipt, request: modelRequest() },
    });
    expect(response.status).toBe(200);
  });
});

describe("request hygiene", () => {
  it("requires a device identifier", async () => {
    const fetcher = fixtureFetch([]);
    const ctx = createExecutionContext();
    const response = await worker.fetch(
      new Request("https://proxy.spare.app/v1/lesson", { method: "POST", body: "{}" }),
      testEnv(),
      ctx,
      { fetcher, now: () => NOW },
    );
    await waitOnExecutionContext(ctx);
    expect(response.status).toBe(400);
  });

  it("rejects a GET", async () => {
    const fetcher = fixtureFetch([]);
    const ctx = createExecutionContext();
    const response = await worker.fetch(
      new Request("https://proxy.spare.app/v1/lesson"),
      testEnv(),
      ctx,
      { fetcher, now: () => NOW },
    );
    await waitOnExecutionContext(ctx);
    expect(response.status).toBe(405);
  });

  it("refuses go-deeper without a subscription", async () => {
    const fetcher = fixtureFetch([anthropicJSON(jsonMessage({ title: "x" }))]);
    const response = await call({
      fetcher,
      path: "/v1/go-deeper",
      device: "free-deeper",
      body: { request: modelRequest() },
    });
    expect(response.status).toBe(402);
    expect((fetcher as any).calls).toHaveLength(0);
  });

  it("does not meter suggestions against the daily lesson limit", async () => {
    // Shuffling suggestions without committing hasn't consumed anything.
    const fetcher = fixtureFetch([anthropicJSON(jsonMessage({ suggestions: [] }))]);
    const device = "suggest-device";

    for (let n = 0; n < 3; n += 1) {
      const response = await call({ fetcher, path: "/v1/suggestions", device, body: { request: modelRequest() } });
      expect(response.status).toBe(200);
    }

    const lesson = await call({ fetcher: fixtureFetch([anthropicStreaming(sseLesson("Still allowed."))]), device });
    expect(lesson.status).toBe(200);
  });
});
