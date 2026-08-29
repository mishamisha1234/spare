/**
 * The controls that exist for the window between deploying the Worker and
 * shipping the app that uses it.
 *
 * They are not the same kind of thing as the tier limits. Those describe a
 * product and will be true forever. These describe a period — weeks, on the
 * way to TestFlight — in which every endpoint is reachable by anyone who finds
 * the URL and there is no client in the world whose behaviour bounds what gets
 * asked for. The global spend ceiling was the only thing standing there, and a
 * ceiling is a budget: it says how much may be lost, not who may spend it.
 */

import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker, { type Env } from "../src/index";
import {
  anthropicJSON,
  anthropicStreaming,
  appleProduction,
  fixtureFetch,
  jsonMessage,
  sseLesson,
  subscriptionStatus,
} from "./fixtures";
import { NOW, call, modelRequest, premiumReceipt, testEnv } from "./harness";
import { GO_DEEPER_PER_DAY_CEILING } from "../src/limits";

const DAY = 86_400_000;
const CLIENT_TOKEN = "client-token-for-tests";
const ADMIN_TOKEN = "admin-token-for-tests";

/** A request built by hand, so a test can send — or withhold — any header. */
async function raw(options: {
  path?: string;
  method?: string;
  headers?: Record<string, string>;
  body?: Record<string, unknown>;
  env?: Env;
  now?: number;
  fetcher?: typeof fetch;
}): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new Request(`https://proxy.spare.app${options.path ?? "/v1/lesson"}`, {
      method: options.method ?? "POST",
      headers: {
        "content-type": "application/json",
        "x-spare-device": "device-guards-default",
        ...(options.headers ?? {}),
      },
      body: options.method === "GET" ? undefined : JSON.stringify(options.body ?? {}),
    }),
    options.env ?? testEnv(),
    ctx,
    { fetcher: options.fetcher ?? fixtureFetch([]), now: () => options.now ?? NOW },
  );
  const buffered = await response.arrayBuffer();
  await waitOnExecutionContext(ctx);
  return new Response(buffered.byteLength === 0 ? null : buffered, {
    status: response.status,
    headers: response.headers,
  });
}

describe("the client gate", () => {
  const gated = () => testEnv({ SPARE_CLIENT_TOKEN: CLIENT_TOKEN });

  it("is off when no token is configured, which is what a deploy does today", async () => {
    const response = await raw({
      path: "/v1/trial/status",
      body: {},
      env: testEnv({ SPARE_CLIENT_TOKEN: undefined }),
    });
    expect(response.status).toBe(200);
  });

  it("404s a request with no client token", async () => {
    // 404, not 401. An endpoint that answers "unauthorized" has confirmed it
    // is there, and the whole value of this gate is that there is nothing
    // findable behind the URL until the app ships.
    const response = await raw({ path: "/v1/trial/status", body: {}, env: gated() });
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: { code: "unknownEndpoint" } });
  });

  it("404s a wrong client token, and one that is a prefix of the real one", async () => {
    for (const token of ["nope", CLIENT_TOKEN.slice(0, -1), CLIENT_TOKEN + "x"]) {
      const response = await raw({
        path: "/v1/trial/status",
        body: {},
        env: gated(),
        headers: { "x-spare-client": token },
      });
      expect(response.status, token).toBe(404);
    }
  });

  it("admits the right client token", async () => {
    const response = await raw({
      path: "/v1/trial/status",
      body: {},
      env: gated(),
      headers: { "x-spare-client": CLIENT_TOKEN },
    });
    expect(response.status).toBe(200);
  });

  it("closes before the method and device guards, so neither leaks", async () => {
    // A wrong method and a missing device each have their own distinctive
    // answer. Either would tell a scanner there is a real endpoint here.
    const wrongMethod = await raw({ path: "/v1/lesson", method: "PUT", env: gated() });
    expect(wrongMethod.status).toBe(404);

    const noDevice = await raw({
      path: "/v1/lesson",
      env: gated(),
      headers: { "x-spare-device": "" },
    });
    expect(noDevice.status).toBe(404);
  });

  it("lets the operator token through on its own", async () => {
    // The batch tool proves it is us with a strictly stronger secret. Making
    // it carry both would be two secrets for one claim.
    const response = await raw({
      path: "/v1/lesson",
      env: testEnv({ SPARE_CLIENT_TOKEN: CLIENT_TOKEN, ADMIN_TOKEN }),
      headers: { "x-spare-admin": ADMIN_TOKEN, "x-spare-device": "device-guards-operator" },
      body: { window: "three", format: "oneThing", topic: "Operator", request: modelRequest() },
      fetcher: fixtureFetch([anthropicStreaming(sseLesson("A lesson."))]),
    });
    expect(response.status).toBe(200);
  });

  it("does not gate the status endpoint", async () => {
    // Status is how you check whether the gate is up. Putting it behind the
    // gate would make that unanswerable from outside at the one moment it
    // matters, and it already has a token of its own.
    const response = await raw({
      path: "/v1/status",
      method: "GET",
      env: testEnv({ SPARE_CLIENT_TOKEN: CLIENT_TOKEN, ADMIN_TOKEN }),
      headers: { "x-spare-admin": ADMIN_TOKEN },
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ clientTokenRequired: true });
  });
});

describe("the trial start switch", () => {
  const off = () => testEnv({ TRIAL_START_ENABLED: "false" });

  it("404s trial/start when off", async () => {
    const response = await raw({
      path: "/v1/trial/start",
      body: {},
      env: off(),
      headers: { "x-spare-device": "device-trial-switch" },
    });
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: { code: "unknownEndpoint" } });
  });

  it("still reads a trial and an allowance when off", async () => {
    // Reading costs nothing and a device with no trial reads as eligible, so
    // switching the read off too would break the app for no saving.
    for (const path of ["/v1/trial/status", "/v1/allowance"]) {
      const response = await raw({ path, body: {}, env: off() });
      expect(response.status, path).toBe(200);
    }
  });

  it("leaves a device that tried to start one free, not trialing", async () => {
    // The trial is read on every request to decide the pool. With starting
    // off, a device that could not start one is free and routed to Sonnet.
    const device = "device-trial-switch-generation";
    await raw({
      path: "/v1/trial/start",
      body: {},
      env: off(),
      headers: { "x-spare-device": device },
    });

    const allowance = await raw({
      path: "/v1/allowance",
      body: {},
      env: off(),
      headers: { "x-spare-device": device },
    });
    expect(((await allowance.json()) as any).trial.status).toBe("eligible");
  });

  it("is on by default, so only this window depends on the flag", async () => {
    const response = await raw({
      path: "/v1/trial/start",
      body: {},
      env: testEnv({ TRIAL_START_ENABLED: undefined }),
      headers: { "x-spare-device": "device-trial-switch-default" },
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ started: true });
  });
});

describe("the go-deeper counter", () => {
  function subscriberFetcher() {
    return fixtureFetch([
      appleProduction(
        subscriptionStatus({
          productId: "app.spare.premium.yearly",
          status: 1,
          expiresDate: NOW + 400 * DAY,
        }),
      ),
      anthropicJSON(jsonMessage({ deeper: "More." })),
    ]);
  }

  async function goDeeper(device: string, now = NOW): Promise<Response> {
    return call({
      path: "/v1/go-deeper",
      device,
      now,
      fetcher: subscriberFetcher(),
      body: { receipt: premiumReceipt, request: modelRequest() },
    });
  }

  it("allows the ceiling and refuses the next", async () => {
    const device = "device-deeper-ceiling";
    for (let index = 0; index < GO_DEEPER_PER_DAY_CEILING; index += 1) {
      expect((await goDeeper(device)).status, `call ${index + 1}`).toBe(200);
    }

    const past = await goDeeper(device);
    expect(past.status).toBe(429);
    expect(await past.json()).toMatchObject({ error: { code: "tooManyRequests" } });
  });

  it("rolls over with the day", async () => {
    const device = "device-deeper-rollover";
    for (let index = 0; index < GO_DEEPER_PER_DAY_CEILING; index += 1) {
      await goDeeper(device);
    }
    expect((await goDeeper(device)).status).toBe(429);
    expect((await goDeeper(device, NOW + DAY)).status).toBe(200);
  });

  it("does not spend the daily lesson allowance", async () => {
    // Still unmetered against the product's limits. The count is an abuse
    // ceiling and nothing else, so a subscriber who used it has lost nothing
    // they were sold.
    const device = "device-deeper-not-a-lesson";
    await goDeeper(device);

    const lesson = await call({
      device,
      fetcher: fixtureFetch([
        appleProduction(
          subscriptionStatus({
            productId: "app.spare.premium.yearly",
            status: 1,
            expiresDate: NOW + 400 * DAY,
          }),
        ),
        anthropicStreaming(sseLesson("A lesson.")),
      ]),
      body: {
        window: "fifteen",
        format: "lesson",
        topic: "Unaffected",
        receipt: premiumReceipt,
        request: modelRequest(),
      },
    });
    expect(lesson.status).toBe(200);
  });

  it("counts before the model is called, so a refusal costs nothing", async () => {
    const device = "device-deeper-no-upstream";
    for (let index = 0; index < GO_DEEPER_PER_DAY_CEILING; index += 1) {
      await goDeeper(device);
    }

    const fetcher = subscriberFetcher();
    const refused = await call({
      path: "/v1/go-deeper",
      device,
      fetcher,
      body: { receipt: premiumReceipt, request: modelRequest() },
    });
    expect(refused.status).toBe(429);
    // The App Store call happens — entitlement is decided first — and
    // Anthropic's does not, which is the one that costs money.
    const anthropicCalls = ((fetcher as any).calls as string[]).filter((url) =>
      url.includes("api.anthropic.com"),
    );
    expect(anthropicCalls).toHaveLength(0);
  });
});

describe("readings the ledger never saw", () => {
  async function unrecordedReadings(): Promise<number> {
    const response = await raw({
      path: "/v1/status",
      method: "GET",
      env: testEnv({ ADMIN_TOKEN }),
      headers: { "x-spare-admin": ADMIN_TOKEN },
    });
    return ((await response.json()) as any).unrecordedReadings;
  }

  it("counts a success whose body carried no usage figure", async () => {
    // The catch stays a catch: the reader already has their answer, and
    // failing the request now would be worse. What changed is that the loss
    // is visible, so `spentUSD` is known to be a floor rather than assumed to
    // be a total.
    const before = await unrecordedReadings();

    const response = await call({
      path: "/v1/suggestions",
      device: "device-unrecorded-usage",
      fetcher: fixtureFetch([
        anthropicJSON(jsonMessage({ suggestions: [] }, { input_tokens: 0, output_tokens: 0 })),
      ]),
      body: { request: modelRequest() },
    });
    expect(response.status).toBe(200);

    expect(await unrecordedReadings()).toBe(before + 1);
  });

  it("counts a success whose body could not be parsed at all", async () => {
    const before = await unrecordedReadings();

    const response = await call({
      path: "/v1/suggestions",
      device: "device-unrecorded-garbage",
      fetcher: fixtureFetch([anthropicJSON("not json at all")]),
      body: { request: modelRequest() },
    });
    expect(response.status).toBe(200);

    expect(await unrecordedReadings()).toBe(before + 1);
  });

  it("does not count a reading it recorded", async () => {
    const before = await unrecordedReadings();

    await call({
      path: "/v1/suggestions",
      device: "device-unrecorded-fine",
      fetcher: fixtureFetch([anthropicJSON(jsonMessage({ suggestions: [] }))]),
      body: { request: modelRequest() },
    });

    expect(await unrecordedReadings()).toBe(before);
  });
});

describe("rate limiting", () => {
  /** Records every key it was asked about, and answers as told. */
  function limiter(succeed: boolean) {
    const keys: string[] = [];
    return {
      keys,
      binding: {
        limit: async ({ key }: { key: string }) => {
          keys.push(key);
          return { success: succeed };
        },
      },
    };
  }

  it("refuses a blocked caller before anything else runs", async () => {
    const { binding, keys } = limiter(false);
    const response = await raw({
      path: "/v1/status",
      method: "GET",
      env: testEnv({ ADMIN_TOKEN, RATE_LIMITER: binding }),
      headers: { "x-spare-admin": ADMIN_TOKEN, "cf-connecting-ip": "203.0.113.7" },
    });
    expect(response.status).toBe(429);
    expect(await response.json()).toMatchObject({ error: { code: "tooManyRequests" } });
    // Keyed on the address Cloudflare sets, not on anything the caller chose.
    expect(keys).toEqual(["203.0.113.7"]);
  });

  it("covers the status endpoint, which nothing else here does", async () => {
    // Every other control lets `/v1/status` through: it has its own token, and
    // it is how you check whether the other controls are up. That makes it the
    // one endpoint an unauthenticated scanner can hammer, so the rate limiter
    // deliberately runs ahead of it.
    const { binding } = limiter(false);
    const response = await raw({
      path: "/v1/status",
      method: "GET",
      env: testEnv({ ADMIN_TOKEN: undefined, RATE_LIMITER: binding }),
      headers: { "cf-connecting-ip": "203.0.113.8" },
    });
    expect(response.status).toBe(429);
  });

  it("lets an allowed caller through", async () => {
    const { binding, keys } = limiter(true);
    const response = await raw({
      path: "/v1/trial/status",
      body: {},
      env: testEnv({ RATE_LIMITER: binding }),
      headers: { "cf-connecting-ip": "203.0.113.9" },
    });
    expect(response.status).toBe(200);
    expect(keys).toHaveLength(1);
  });

  it("is skipped when there is no client address, so it cannot bucket everyone together", async () => {
    // No `cf-connecting-ip` means we are not behind Cloudflare, which off a
    // deployed Worker means a test. Keying on a constant would rate-limit the
    // whole world as one caller.
    const { binding, keys } = limiter(false);
    const response = await raw({
      path: "/v1/trial/status",
      body: {},
      env: testEnv({ RATE_LIMITER: binding }),
    });
    expect(response.status).toBe(200);
    expect(keys).toHaveLength(0);
  });

  it("serves normally on a deploy that has no limiter bound", async () => {
    const response = await raw({
      path: "/v1/trial/status",
      body: {},
      env: testEnv({ RATE_LIMITER: undefined }),
      headers: { "cf-connecting-ip": "203.0.113.10" },
    });
    expect(response.status).toBe(200);
  });
});

describe("what the status endpoint says about the window", () => {
  it("reports both switches, so neither has to be assumed", async () => {
    const response = await raw({
      path: "/v1/status",
      method: "GET",
      env: testEnv({
        ADMIN_TOKEN,
        SPARE_CLIENT_TOKEN: undefined,
        TRIAL_START_ENABLED: "false",
        MONTHLY_SPEND_CEILING_USD: "15",
      }),
      headers: { "x-spare-admin": ADMIN_TOKEN },
    });
    expect(await response.json()).toMatchObject({
      ceilingUSD: 15,
      clientTokenRequired: false,
      trialStartEnabled: false,
    });
  });
});
