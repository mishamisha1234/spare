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
  anthropicSequence,
  lessonBody,
  sseLesson,
  subscriptionStatus,
} from "./fixtures";
import { MAX_REQUESTS_PER_LESSON, PREMIUM_COURSES_PER_MONTH } from "../src/limits";
import { recordingAnthropic } from "./harness";
import { NOW, call, callRaw, modelRequest, premiumReceipt, testEnv } from "./harness";

/** Reads a device's counters straight out of its Durable Object. */
async function peekUsage(device: string): Promise<{
  lessonsToday: number;
  coursesThisMonth: number;
}> {
  const environment = testEnv();
  const stub = environment.USAGE.get(environment.USAGE.idFromName(device));
  const response = await stub.fetch(`https://usage/peek?now=${NOW}`);
  return (await response.json()) as { lessonsToday: number; coursesThisMonth: number };
}

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

  it("does name the class of upstream failure, which is a fixed enum", async () => {
    // Withholding this cost two investigations. Six identical "rejected
    // upstream" lines in a batch log could have been a malformed request, an
    // expired key, or an exhausted balance, and nothing in the log chose
    // between them.
    const fetcher = fixtureFetch([
      anthropicJSON(
        JSON.stringify({
          error: { type: "invalid_request_error", message: "credit balance too low for org 1234" },
        }),
        400,
      ),
    ]);
    const response = await call({ fetcher, device: "upstream-type-device" });
    const text = await response.text();

    expect(response.status).toBe(502);
    expect(text).toContain("invalid_request_error");
    expect(text).not.toContain("credit balance");
    expect(text).not.toContain("1234");
  });

  it("reports a type it does not recognise as unrecognised rather than echoing it", async () => {
    const fetcher = fixtureFetch([
      anthropicJSON(JSON.stringify({ error: { type: "account_id_9f2a_suspended" } }), 400),
    ]);
    const response = await call({ fetcher, device: "upstream-unknown-device" });
    const text = await response.text();

    expect(text).toContain("unrecognised");
    expect(text).not.toContain("9f2a");
  });

  it("separates Anthropic being down from Anthropic refusing what we sent", async () => {
    // 503 is worth retrying and 502 is not, so they cannot share a status.
    const down = fixtureFetch([
      anthropicJSON(JSON.stringify({ error: { type: "overloaded_error" } }), 529),
    ]);
    const outage = await call({ fetcher: down, device: "upstream-down-device" });
    expect(outage.status).toBe(503);
    expect(await outage.text()).toContain("overloaded_error");

    const refused = fixtureFetch([
      anthropicJSON(JSON.stringify({ error: { type: "not_found_error" } }), 404),
    ]);
    const rejected = await call({ fetcher: refused, device: "upstream-refused-device" });
    expect(rejected.status).toBe(502);
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
    // Long enough to split: `sseLesson` cuts text into 20-character deltas, and
    // the assertion below counts on there being more than one of them. The first
    // version passed "Ordered." — eight characters, one delta — so the last
    // assertion could never hold no matter how correct the server was.
    const sse = sseLesson(
      "Order matters here, because RevisionGate reads the sequence and not the bytes."
    );
    const fetcher = fixtureFetch([anthropicStreaming(sse)]);
    const body = await (await call({ fetcher })).text();

    const events = [...body.matchAll(/event: (\w+)/g)].map((match) => match[1]);
    expect(events[0]).toBe("message_start");
    expect(events.at(-1)).toBe("message_stop");
    expect(events.filter((name) => name === "content_block_delta").length).toBeGreaterThan(1);
  });

  it("does not buffer the stream into one chunk", async () => {
    // Reads the live stream rather than a buffered copy: the assertion is about
    // chunk boundaries, and `call` would have flattened them by design.
    const sse = sseLesson("a".repeat(4000));
    const fetcher = fixtureFetch([anthropicStreaming(sse)]);
    const { response, ctx } = await callRaw({ fetcher });

    const reader = response.body!.getReader();
    let chunks = 0;
    while (true) {
      const { done } = await reader.read();
      if (done) break;
      chunks += 1;
    }
    await waitOnExecutionContext(ctx);

    expect(chunks).toBeGreaterThan(1);
  });
});

describe("one lesson is one charge, however many requests it takes", () => {
  // A lesson is a draft and a revision. A course is an outline plus four
  // chapters, twice over. Counting requests instead of lessons meant a free
  // user's whole daily allowance went on the draft and the revision came back
  // 402 — the free tier could not finish a single lesson through the proxy —
  // and one course counted nine against a cap of twelve a month.
  //
  // `ProxyProviderTests` asserted this contract from the client side, in as
  // many words, from the day the endpoints were written. Nothing asserted it
  // here, and the client cannot see what the meter does.
  it("does not charge the revision pass of a lesson it already charged", async () => {
    const fetcher = fixtureFetch([
      anthropicStreaming(sseLesson("Draft.")),
      anthropicStreaming(sseLesson("Revised.")),
    ]);
    const device = "two-pass-device";
    const body = {
      window: "three",
      format: "oneThing",
      topic: "A lesson in two passes",
      request: modelRequest(),
    };

    const draft = await call({ fetcher, device, body });
    expect(draft.status).toBe(200);

    const revision = await call({ fetcher, device, body });
    expect(revision.status, "the revision pass of a charged lesson must not be refused").toBe(200);
  });

  it("still refuses a different lesson the same day", async () => {
    const fetcher = fixtureFetch([
      anthropicStreaming(sseLesson("First.")),
      anthropicStreaming(sseLesson("First again.")),
    ]);
    const device = "two-pass-device-2";
    const first = { window: "three", format: "oneThing", topic: "The charged one", request: modelRequest() };

    expect((await call({ fetcher, device, body: first })).status).toBe(200);
    expect((await call({ fetcher, device, body: first })).status).toBe(200);

    const other = await call({
      fetcher,
      device,
      body: { ...first, topic: "A different subject entirely" },
    });
    expect(other.status).toBe(402);
    expect(await other.json()).toMatchObject({ error: { code: "dailyLimitReached" } });
  });

  it("stops a device repeating one charged lesson forever", async () => {
    // The bound on the fix above. Once a lesson is paid for its later requests
    // are free, so without a ceiling a free device could send the same topic
    // all day and generate every time — cheaper abuse than clearing the device
    // id, which at least costs a reinstall.
    const routes = [];
    // Derived, not 20. The loop has to be able to reach the bound: when
    // MAX_REQUESTS_PER_LESSON was raised for the word-floor retry, a hardcoded
    // 20 meant the refusal never happened and the test reported "never
    // refused" as `refusedAt === 0`.
    const attempts = MAX_REQUESTS_PER_LESSON + 4;
    for (let index = 0; index < attempts; index += 1) {
      routes.push(anthropicStreaming(sseLesson(`Pass ${index}.`)));
    }
    const fetcher = fixtureFetch(routes);
    const device = "repeat-forever-device";
    const body = {
      window: "three",
      format: "oneThing",
      topic: "The same lesson over and over",
      request: modelRequest(),
    };

    let refusedAt = 0;
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      const response = await call({ fetcher, device, body });
      if (response.status !== 200) {
        expect(await response.json()).toMatchObject({ error: { code: "dailyLimitReached" } });
        refusedAt = attempt;
        break;
      }
    }

    // Generous enough that no honest client reaches it — a course is nine
    // requests and the client retries three times — and finite.
    expect(refusedAt, "a charged lesson must not be repeatable without limit").toBe(
      MAX_REQUESTS_PER_LESSON + 1,
    );
  });

  it("counts a whole course as one course, not one per chapter call", async () => {
    const outline = anthropicJSON(jsonMessage({ title: "A course" }));
    const routes = [
      appleProduction(
        subscriptionStatus({
          productId: "app.spare.premium.yearly",
          status: 1,
          expiresDate: NOW + 30 * 86_400_000,
        }),
      ),
      outline,
    ];
    for (let index = 0; index < 8; index += 1) {
      routes.push(anthropicStreaming(sseLesson(`Chapter ${index}.`)));
    }
    const fetcher = fixtureFetch(routes);
    const device = "course-cap-device";
    const course = {
      window: "thirty",
      format: "miniCourse",
      topic: "One course, nine calls",
      receipt: premiumReceipt,
      request: modelRequest({ max_tokens: 4_000 }),
    };

    expect((await call({ fetcher, device, path: "/v1/outline", body: course })).status).toBe(200);
    for (let index = 0; index < 8; index += 1) {
      const chapter = await call({ fetcher, device, path: "/v1/chapter", body: course });
      expect(chapter.status, `chapter call ${index} was refused`).toBe(200);
    }

    const usage = await peekUsage(device);
    expect(usage.coursesThisMonth, "nine requests, one course").toBe(1);
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

  it("fails closed and retryable when the App Store secrets are not set", async () => {
    // The legitimate first deploy sets only ANTHROPIC_API_KEY, so the free tier
    // works before an App Store Connect key exists. A premium request then must
    // not reach WebCrypto with an undefined key and 500; it should read as a
    // verification outage, which is retryable and does not grant premium.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Should not be reached."))]);
    const response = await call({
      fetcher,
      device: "unconfigured-premium",
      env: testEnv({
        APPSTORE_PRIVATE_KEY: "",
        APPSTORE_KEY_ID: "",
        APPSTORE_ISSUER_ID: "",
      }),
      body: {
        window: "thirty",
        format: "miniCourse",
        topic: "Course before the key exists",
        receipt: premiumReceipt,
        request: modelRequest(),
      },
    });

    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ error: { code: "verificationUnavailable" } });
    // Nothing was generated, and Apple was never asked.
    expect((fetcher as any).calls).toHaveLength(0);
  });

  it("caps courses per month", async () => {
    const fetcher = fixtureFetch(premiumRoutes(sseLesson("Course.")));
    const device = "premium-device-cap";

    // Driven by the constant, not by 12. The cap moved to 8 and this test was
    // right about the number it was written against -- which is exactly why it
    // should never have been the one place the number was written twice.
    for (let n = 0; n < PREMIUM_COURSES_PER_MONTH; n += 1) {
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

    const oneTooMany = await call({
      fetcher,
      device,
      body: { window: "thirty", format: "miniCourse", topic: "One too many", receipt: premiumReceipt, request: modelRequest() },
    });
    expect(oneTooMany.status).toBe(402);
    expect(await oneTooMany.json()).toMatchObject({ error: { code: "courseCapReached" } });
  });

  it("does not meter premium against the free daily limit", async () => {
    const fetcher = fixtureFetch(premiumRoutes(sseLesson("Unlimited.")));
    const device = "premium-device-daily";

    for (let n = 0; n < 3; n += 1) {
      const response = await call({
        fetcher,
        device,
        body: { window: "seven", format: "explainer", topic: `Topic ${n}`, receipt: premiumReceipt, request: modelRequest() },
      });
      expect(response.status).toBe(200);
      await response.text();
    }
  });
});

describe("the lesson cache", () => {
  it("serves a free user a cached lesson without calling Anthropic", async () => {
    const sse = sseLesson(lessonBody(520));
    const fetcher = fixtureFetch([anthropicStreaming(sse)]);

    // First device generates and populates the cache.
    await (await call({ fetcher, device: "cache-seed-device" })).text();

    // A second device, same topic: served from cache, no upstream call.
    const callsBefore = (fetcher as any).calls.length;
    const cached = await call({ fetcher, device: "cache-reader-device" });
    expect(cached.headers.get("x-spare-cache")).toBe("hit");
    expect((fetcher as any).calls.length).toBe(callsBefore);
  });

  it("counts a cached lesson against the daily limit", async () => {
    // The rule is one lesson a day whatever its source. A reader cannot tell a
    // cached lesson from a generated one, so an allowance that only counted
    // generations would make the free tier behave unpredictably from their side
    // and be impossible to describe honestly on the paywall.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson(lessonBody(520)))]);
    await (await call({ fetcher, device: "cache-meter-seed" })).text();

    const reader = "cache-meter-reader";
    const cached = await call({ fetcher, device: reader });
    expect(cached.headers.get("x-spare-cache")).toBe("hit");
    await cached.text();

    // Same device, a topic the cache cannot answer: the allowance is gone.
    const second = await call({
      fetcher,
      device: reader,
      body: { window: "three", format: "oneThing", topic: "A completely different subject", request: modelRequest() },
    });
    expect(second.status).toBe(402);
    expect(await second.json()).toMatchObject({ error: { code: "dailyLimitReached" } });
  });

  it("does not spend the allowance when the cached lesson is refused", async () => {
    // Metering happens after deciding what to serve, so a request that ends in
    // a refusal never costs the reader their lesson for the day. Here the
    // device has already read the only cached entry, so it falls through to
    // generation, which is what should be metered.
    const fetcher = fixtureFetch([
      anthropicStreaming(sseLesson("First.")),
      anthropicStreaming(sseLesson("Second.")),
    ]);
    const device = "cache-refusal-device";

    // Generates, which also records the lesson as read by this device.
    await (await call({ fetcher, device })).text();

    // Tomorrow, same topic: the cache holds it but this device has read it, so
    // it generates instead — and that generation is what consumes the day.
    const tomorrow = await call({ fetcher, device, now: NOW + 86_400_000 });
    expect(tomorrow.status).toBe(200);
    expect(tomorrow.headers.get("x-spare-cache")).toBeNull();
  });

  it("collides on topics that differ only by wording", async () => {
    // Both topics are stated explicitly: this test is about the exact pair of
    // wordings, so inheriting a test-scoped default topic would test nothing.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson(lessonBody(520)))]);
    await (await call({
      fetcher,
      device: "wording-a",
      body: { window: "three", format: "oneThing", topic: "Why bridges hum", request: modelRequest() },
    })).text();

    const callsBefore = (fetcher as any).calls.length;
    const restated = await call({
      fetcher,
      device: "wording-b",
      body: { window: "three", format: "oneThing", topic: "How do bridges hum?", request: modelRequest() },
    });
    expect(restated.headers.get("x-spare-cache")).toBe("hit");
    expect((fetcher as any).calls.length).toBe(callsBefore);
  });

  it("never serves a free-pool lesson to premium", async () => {
    // Premium reads the cache now — it has to, or a 30-minute course read by
    // two hundred people is written two hundred times. What it must never do
    // is read the *free* pool: that one is written by Sonnet and carries no
    // attached test, and serving it to a paying reader would hand them the
    // thing they paid not to get.
    const fetcher = fixtureFetch(premiumRoutes(sseLesson(lessonBody(520))));
    await (await call({
      fetcher,
      device: "cache-premium-seed",
      body: { window: "three", format: "oneThing", topic: "Why bridges hum", request: modelRequest() },
    })).text();

    const callsBefore = (fetcher as any).calls.length;
    const premium = await call({
      fetcher,
      device: "cache-premium-reader",
      body: { window: "three", format: "oneThing", topic: "Why bridges hum", receipt: premiumReceipt, request: modelRequest() },
    });
    expect(premium.headers.get("x-spare-cache")).toBeNull();
    expect((fetcher as any).calls.length).toBeGreaterThan(callsBefore);
  });

  it("serves premium from the premium pool", async () => {
    // The other half: two premium readers on the same subject share an entry.
    const seed = fixtureFetch(premiumRoutes(sseLesson(lessonBody(520))));
    const body = {
      window: "three", format: "oneThing", topic: "Why bridges hum",
      receipt: premiumReceipt, request: modelRequest(),
    };
    await (await call({ fetcher: seed, device: "premium-writer", body })).text();

    const reader = fixtureFetch(premiumRoutes(sseLesson(lessonBody(520))));
    const callsBefore = (reader as any).calls.length;
    const second = await call({ fetcher: reader, device: "premium-reader", body });
    expect(second.headers.get("x-spare-cache")).toBe("hit");
    // The Apple check still happens; what must not happen is a generation.
    expect((reader as any).calls.filter((u: string) => u.includes("anthropic")).length)
      .toBe(callsBefore);
  });

  it("does not cache a draft pass", async () => {
    // Pass 1 is never shown to the reader who produced it, so an entry holding
    // one would serve unrevised prose to everyone who asked next — for thirty
    // days, with nothing about reading it saying so.
    const fetcher = fixtureFetch([
      anthropicStreaming(sseLesson(lessonBody(520))),
      anthropicStreaming(sseLesson(lessonBody(520))),
    ]);
    const body = {
      window: "three", format: "oneThing", topic: "Draft only",
      pass: "draft", request: modelRequest(),
    };
    await (await call({ fetcher, device: "draft-writer", body })).text();

    const callsBefore = (fetcher as any).calls.length;
    const next = await call({
      fetcher,
      device: "draft-reader",
      body: { ...body, pass: "final" },
    });
    expect(next.headers.get("x-spare-cache")).toBeNull();
    expect((fetcher as any).calls.length).toBeGreaterThan(callsBefore);
  });

  it("does not serve a device a lesson it has already read", async () => {
    // Otherwise a reader who asks about bridges twice gets the same words back,
    // which reads as the app being broken rather than as a cache working.
    const topic = "Why bridges hum";
    const body = { window: "three", format: "oneThing", topic, request: modelRequest() };
    const device = "repeat-reader";

    // Someone else generates it, so the entry exists and this device has not
    // read it. Their own generation would mark it read for them.
    const seedFetcher = fixtureFetch([anthropicStreaming(sseLesson(lessonBody(520)))]);
    await (await call({ fetcher: seedFetcher, device: "repeat-seed", body })).text();

    const first = await call({ fetcher: fixtureFetch([]), device, body });
    expect(first.headers.get("x-spare-cache")).toBe("hit");
    await first.text();
    // That hit consumed the day, so the next ask has to be tomorrow.

    // Second ask, next day so the daily limit is not what refuses it. The cache
    // declines, so it generates instead — which means an upstream call.
    const secondFetcher = fixtureFetch([anthropicStreaming(sseLesson("Fresh instead."))]);
    const second = await call({
      fetcher: secondFetcher,
      device,
      body,
      now: NOW + 86_400_000,
    });
    expect(second.status).toBe(200);
    expect(second.headers.get("x-spare-cache")).toBeNull();
    expect((secondFetcher as any).calls.length).toBeGreaterThan(0);
  });

  it("does not serve a reader their own lesson back the next day", async () => {
    // Generating populates the cache, so without recording the generator as
    // having read it, tomorrow's identical request would be a cache hit on
    // their own words.
    const topic = "Why bridges hum";
    const body = { window: "three", format: "oneThing", topic, request: modelRequest() };
    const device = "own-lesson-reader";

    const first = fixtureFetch([anthropicStreaming(sseLesson(lessonBody(520)))]);
    await (await call({ fetcher: first, device, body })).text();

    const next = fixtureFetch([anthropicStreaming(sseLesson("Something new."))]);
    const tomorrow = await call({ fetcher: next, device, body, now: NOW + 86_400_000 });
    expect(tomorrow.headers.get("x-spare-cache")).toBeNull();
    expect((next as any).calls.length).toBeGreaterThan(0);
  });

  it("refuses a cached lesson older than thirty days", async () => {
    const topic = "Ageing entry";
    const body = { window: "three", format: "oneThing", topic, request: modelRequest() };

    const seed = fixtureFetch([anthropicStreaming(sseLesson(lessonBody(520)))]);
    await (await call({ fetcher: seed, device: "age-seed", body })).text();

    // A day inside the window: still served.
    const inside = fixtureFetch([]);
    const fresh = await call({
      fetcher: inside,
      device: "age-reader-inside",
      body,
      now: NOW + 29 * 86_400_000,
    });
    expect(fresh.headers.get("x-spare-cache")).toBe("hit");
    await fresh.text();

    // A day outside it: regenerated rather than served stale.
    const outside = fixtureFetch([anthropicStreaming(sseLesson("Written again."))]);
    const stale = await call({
      fetcher: outside,
      device: "age-reader-outside",
      body,
      now: NOW + 31 * 86_400_000,
    });
    expect(stale.status).toBe(200);
    expect(stale.headers.get("x-spare-cache")).toBeNull();
    expect((outside as any).calls.length).toBeGreaterThan(0);
  });

  it("does not cache a lesson that came back under the word floor", async () => {
    // The same rule as the truncated stream below, for the same reason. A
    // lesson that is 60% of the length it was sold as is not a lesson with a
    // flaw in it; it is eight minutes of reading sold as fifteen. Shown to the
    // reader who generated it that is one bad lesson — the app has its own
    // check and retries — but written into the pool it is served to everyone
    // who asks that question for the next thirty days.
    //
    // 300 words against a 3-minute floor of 500: under 90% of it, and complete,
    // so nothing but the length rules it out.
    const fetcher = fixtureFetch([
      anthropicStreaming(sseLesson(lessonBody(300))),
      anthropicStreaming(sseLesson(lessonBody(300))),
    ]);
    await (await call({ fetcher, device: "short-writer" })).text();

    const callsBefore = (fetcher as any).calls.length;
    const next = await call({ fetcher, device: "short-reader" });
    expect(next.headers.get("x-spare-cache")).toBeNull();
    expect((fetcher as any).calls.length).toBeGreaterThan(callsBefore);
  });

  it("caches a lesson that clears the floor by a hair", async () => {
    // The other side of the same line, so the check is not passing by refusing
    // everything. 460 words is under the 500-word floor and over the 450-word
    // hard floor: tight, not short, and the reader is not made to wait for a
    // regeneration over forty words.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson(lessonBody(460)))]);
    await (await call({ fetcher, device: "tight-writer" })).text();

    const callsBefore = (fetcher as any).calls.length;
    const next = await call({ fetcher, device: "tight-reader" });
    expect(next.headers.get("x-spare-cache")).toBe("hit");
    expect((fetcher as any).calls.length).toBe(callsBefore);
  });

  it("serves a cached course back as four distinct chapters, in order", async () => {
    // The bug this exists to catch was invisible until premium started reading
    // the cache: an outline and all four chapters carried the same key, each
    // overwriting the last, so the entry ended up holding whichever chapter
    // finished most recently. Served back, that is a course made of four
    // copies of chapter four — and a corrupt course in the pool is read by
    // everyone who asks for that subject for the next thirty days.
    const chapterCount = 4;
    const course = {
      window: "thirty",
      format: "miniCourse",
      topic: "How electricity grids stay balanced",
      interest: "Engineering",
      receipt: premiumReceipt,
      pass: "final",
      request: modelRequest({ max_tokens: 24_000 }),
    };

    // Chapters must clear their own floor: a quarter of 6,000 words, times 90%.
    // One sequenced route, not five separate ones: fixture routes are matched
    // by predicate and never consumed, so a list of them all answers from the
    // first — which would hand every chapter the outline's JSON and make this
    // test pass or fail for the wrong reason.
    const writer = fixtureFetch([
      appleProduction(subscriptionStatus({
        productId: "app.spare.premium.yearly",
        status: 1,
        expiresDate: NOW + 30 * 86_400_000,
      })),
      anthropicSequence([
        { body: jsonMessage({ title: "A course", chapterHeadings: ["a", "b", "c", "d"] }), streaming: false },
        ...Array.from({ length: chapterCount }, (_, index) => ({
          body: sseLesson(`CHAPTERMARK${index} ` + lessonBody(1_400)),
        })),
      ]),
    ]);

    expect((await call({
      fetcher: writer, device: "course-writer", path: "/v1/outline", body: course,
    })).status).toBe(200);
    for (let index = 0; index < chapterCount; index += 1) {
      const chapter = await call({
        fetcher: writer, device: "course-writer", path: "/v1/chapter",
        body: { ...course, chapter: index },
      });
      expect(chapter.status, `writing chapter ${index}`).toBe(200);
      await chapter.text();
    }

    // A second premium reader, and an upstream that would throw if touched for
    // anything but the Apple check.
    const reader = fixtureFetch([
      appleProduction(subscriptionStatus({
        productId: "app.spare.premium.yearly",
        status: 1,
        expiresDate: NOW + 30 * 86_400_000,
      })),
    ]);

    const outline = await call({
      fetcher: reader, device: "course-reader", path: "/v1/outline", body: course,
    });
    expect(outline.headers.get("x-spare-cache"), "the outline regenerated").toBe("hit");

    const served: number[] = [];
    for (let index = 0; index < chapterCount; index += 1) {
      const chapter = await call({
        fetcher: reader, device: "course-reader", path: "/v1/chapter",
        body: { ...course, chapter: index },
      });
      expect(chapter.headers.get("x-spare-cache"), `chapter ${index} was not cached`).toBe("hit");
      const text = await chapter.text();
      const mark = /CHAPTERMARK(\d)/.exec(text);
      expect(mark, `chapter ${index} came back unrecognisable`).not.toBeNull();
      served.push(Number(mark![1]));
    }

    expect(served, "the four chapters came back out of order or duplicated")
      .toEqual([0, 1, 2, 3]);
    expect(new Set(served).size, "chapters collided on one cache key").toBe(chapterCount);
  });

  it("forces a free device onto the free pool's model rather than refusing it", async () => {
    // A free client naming Opus is either a stale build or a spoofed one. It is
    // served Sonnet, not a 400: a refusal names the boundary and invites
    // probing at its edges, while a perfectly good Sonnet lesson says nothing
    // at all. It also means an app build that drifts out of step with the
    // server keeps working for its reader.
    const upstream = recordingAnthropic(() =>
      new Response(sseLesson(lessonBody(520)), {
        headers: { "content-type": "text/event-stream" },
      }));
    const fetcher = fixtureFetch([upstream.route]);
    const body = {
      window: "three", format: "oneThing", topic: "Whichever model writes this",
      pass: "final",
      request: modelRequest({ model: "claude-opus-5" }),
    };

    const response = await call({ fetcher, device: "free-asking-for-opus", body });

    expect(response.status, "the request was refused rather than redirected").toBe(200);
    expect(upstream.bodies).toHaveLength(1);
    expect(upstream.bodies[0].model, "a free device spent Opus money").toBe("claude-sonnet-5");

    // And it landed in the free pool, not the premium one: another free reader
    // gets the hit, a premium reader does not.
    const freeReader = await call({
      fetcher: fixtureFetch([upstream.route]), device: "free-reader", body,
    });
    expect(freeReader.headers.get("x-spare-cache")).toBe("hit");

    const premiumReader = await call({
      fetcher: fixtureFetch(premiumRoutes(sseLesson(lessonBody(520)))),
      device: "premium-reader-of-free-entry",
      body: { ...body, receipt: premiumReceipt },
    });
    expect(premiumReader.headers.get("x-spare-cache"), "a free-pool entry reached premium")
      .toBeNull();
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
      body: { window: "seven", format: "explainer", topic: "Paid topic", receipt: premiumReceipt, request: modelRequest() },
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
    await response.arrayBuffer();
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
    await response.arrayBuffer();
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
