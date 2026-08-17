/**
 * The proxy.
 *
 * Endpoints mirror `LessonProvider` in SpareCore one-for-one, so
 * `ProxyProvider` is a thin translation and not a second design.
 *
 *   POST /v1/suggestions
 *   POST /v1/lesson      (SSE)
 *   POST /v1/chapter     (SSE)
 *   POST /v1/recall
 *   POST /v1/post-lesson-test
 *   POST /v1/go-deeper
 */

import {
  AppStoreVerificationError,
  FREE_ENTITLEMENT,
  verifyEntitlement,
  type AppStoreConfig,
  type VerifiedEntitlement,
} from "./appstore";
import { lessonCacheKey, readCachedLesson, replayCachedLesson, writeCachedLesson } from "./cache";
import { SpendLedger, UsageCounter, type Decision } from "./limits";
import { applyPolicy } from "./policy";
import {
  callAnthropic,
  estimateCostUSD,
  forwardStream,
  parseCompletedStream,
} from "./upstream";

export { SpendLedger, UsageCounter };

export interface Env {
  ANTHROPIC_API_KEY: string;
  APPSTORE_PRIVATE_KEY: string;
  APPSTORE_KEY_ID: string;
  APPSTORE_ISSUER_ID: string;
  BUNDLE_ID: string;
  /** Monthly ceiling in USD. A string because bindings are strings. */
  MONTHLY_SPEND_CEILING_USD: string;
  USAGE: DurableObjectNamespace;
  SPEND: DurableObjectNamespace;
  LESSONS: KVNamespace;
}

/** Test seam: swapped for fixture handlers so no test makes a network call. */
export interface Hooks {
  fetcher?: typeof fetch;
  now?: () => number;
}

const JSON_HEADERS = { "content-type": "application/json" };

function errorResponse(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: JSON_HEADERS,
  });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext, hooks: Hooks = {}): Promise<Response> {
    const now = hooks.now?.() ?? Date.now();
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return errorResponse(405, "methodNotAllowed", "Only POST is accepted.");
    }

    // Device identity. Spoofable by design — there are no accounts — so it
    // gates *fairness*, not spend. The ceiling below is what protects money.
    const deviceId = request.headers.get("x-spare-device");
    if (!deviceId || deviceId.length < 8 || deviceId.length > 128) {
      return errorResponse(400, "missingDevice", "A device identifier is required.");
    }

    let body: Record<string, any>;
    try {
      body = (await request.json()) as Record<string, any>;
    } catch {
      return errorResponse(400, "malformedRequest", "Body must be JSON.");
    }

    // Entitlement. A verification outage fails closed to free rather than open
    // to premium, and is reported as retryable so the app can try again
    // instead of quietly downgrading someone who pays.
    let entitlement: VerifiedEntitlement = FREE_ENTITLEMENT;
    const receipt = typeof body.receipt === "string" ? body.receipt : null;
    if (receipt) {
      try {
        entitlement = await verifyEntitlement(receipt, appStoreConfig(env), hooks.fetcher, now);
      } catch (error) {
        if (error instanceof AppStoreVerificationError) {
          return errorResponse(
            503,
            "verificationUnavailable",
            "Couldn't confirm your subscription. Try again shortly.",
          );
        }
        throw error;
      }
    }

    // The client builds the Anthropic request; the proxy decides what it is
    // allowed to be. Runs before any metering so a request that will be
    // refused never consumes an allowance. See `policy.ts`.
    const policy = applyPolicy(body.request, url.pathname);
    if (!policy.ok) {
      const status = policy.code === "unknownEndpoint" ? 404 : 400;
      return errorResponse(status, policy.code, policy.message);
    }
    const modelRequest = policy.request;

    switch (url.pathname) {
      case "/v1/suggestions":
      case "/v1/recall":
      case "/v1/post-lesson-test":
        return handleUnmetered(modelRequest, env, entitlement, ctx, hooks, now);

      case "/v1/lesson":
      case "/v1/chapter":
        return handleGeneration(body, modelRequest, env, entitlement, deviceId, ctx, hooks, now);

      case "/v1/go-deeper":
        // Premium-only, and cheap enough not to meter separately.
        if (entitlement.tier === "free") {
          return errorResponse(402, "goDeeperLocked", "Going deeper is part of Premium.");
        }
        return handleUnmetered(modelRequest, env, entitlement, ctx, hooks, now);

      default:
        return errorResponse(404, "unknownEndpoint", "No such endpoint.");
    }
  },
};

function appStoreConfig(env: Env): AppStoreConfig {
  return {
    keyId: env.APPSTORE_KEY_ID,
    issuerId: env.APPSTORE_ISSUER_ID,
    bundleId: env.BUNDLE_ID,
    privateKeyPem: env.APPSTORE_PRIVATE_KEY,
  };
}

/**
 * Suggestions, recall questions, and tests.
 *
 * Not metered against the daily lesson limit: they are small, and a reader who
 * shuffles suggestions without committing to a lesson has not consumed their
 * allowance. They still count toward the spend ceiling, because they still
 * cost.
 */
async function handleUnmetered(
  modelRequest: Record<string, unknown>,
  env: Env,
  entitlement: VerifiedEntitlement,
  ctx: ExecutionContext,
  hooks: Hooks,
  now: number,
): Promise<Response> {
  const ceiling = await spendCheck(env, hooks, now);
  if (!ceiling.withinCeiling && entitlement.tier === "free") {
    return errorResponse(429, "spendCeilingReached", "Spare is at its monthly limit. Try later.");
  }

  const upstream = await callAnthropic(modelRequest, {
    apiKey: env.ANTHROPIC_API_KEY,
    fetcher: hooks.fetcher,
  });

  if (!upstream.ok) return passUpstreamError(upstream);

  const text = await upstream.text();
  recordSpendFromBody(text, env, ctx, hooks, now);
  return new Response(text, { status: 200, headers: JSON_HEADERS });
}

/**
 * Lesson and chapter generation: metered, capped, cached, and streamed.
 */
async function handleGeneration(
  body: Record<string, any>,
  modelRequest: Record<string, unknown>,
  env: Env,
  entitlement: VerifiedEntitlement,
  deviceId: string,
  ctx: ExecutionContext,
  hooks: Hooks,
  now: number,
): Promise<Response> {
  const window = typeof body.window === "string" ? body.window : "three";
  const format = typeof body.format === "string" ? body.format : "oneThing";
  const topic = typeof body.topic === "string" ? body.topic : "";

  const isFree = entitlement.tier === "free";
  const cacheKey = lessonCacheKey({ window, format, topic });

  // Free users are served from cache before anything is metered: a cache hit
  // costs nothing, so spending a day's allowance on it would be punitive.
  if (isFree && topic) {
    const cached = await readCachedLesson(env.LESSONS, cacheKey);
    if (cached) return replayCachedLesson(cached.sse);
  }

  const ceiling = await spendCheck(env, hooks, now);
  if (!ceiling.withinCeiling && isFree) {
    return errorResponse(
      429,
      "spendCeilingReached",
      "Spare is at its monthly limit. Try again later.",
    );
  }

  const decision = await consume(env, deviceId, entitlement.tier, window, hooks, now);
  if (!decision.allow) {
    return errorResponse(402, decision.reason, denialMessage(decision.reason));
  }

  const upstream = await callAnthropic(modelRequest, {
    apiKey: env.ANTHROPIC_API_KEY,
    fetcher: hooks.fetcher,
  });

  if (!upstream.ok) return passUpstreamError(upstream);

  // Forwarded byte-for-byte; observation happens on a teed branch after the
  // response is already on its way. See `forwardStream`.
  return forwardStream(
    upstream,
    async (fullBody) => {
      const parsed = parseCompletedStream(fullBody);
      const cost = estimateCostUSD(parsed.inputTokens, parsed.outputTokens);
      await recordSpend(env, cost, hooks, now);

      // Only cache a stream that actually finished. Caching a truncated one
      // would serve the truncation to everyone who asks next.
      if (parsed.complete && topic) {
        await writeCachedLesson(env.LESSONS, cacheKey, {
          sse: fullBody,
          createdAt: now,
          originalCostUSD: cost,
        });
      }
    },
    (promise) => ctx.waitUntil(promise),
  );
}

function denialMessage(reason: Decision extends { allow: false } ? never : string): string {
  switch (reason) {
    case "dailyLimitReached":
      return "That's today's free lesson. The next one unlocks tomorrow.";
    case "lockedWindow":
      return "That length is part of Premium.";
    case "courseCapReached":
      return "You've started every course included this month.";
    default:
      return "Not available right now.";
  }
}

/**
 * Upstream failures are forwarded as a status the app can map, with the
 * message discarded — an Anthropic error body can name the model, the account,
 * or the key's shape, none of which belongs in a client response.
 */
function passUpstreamError(upstream: Response): Response {
  if (upstream.status === 429) {
    return errorResponse(429, "rateLimited", "Anthropic is throttling requests. Try shortly.");
  }
  if (upstream.status >= 500) {
    return errorResponse(502, "upstreamUnavailable", "The model is unavailable right now.");
  }
  return errorResponse(502, "upstreamRejected", "The request was rejected upstream.");
}

async function consume(
  env: Env,
  deviceId: string,
  tier: string,
  window: string,
  hooks: Hooks,
  now: number,
): Promise<Decision> {
  const stub = env.USAGE.get(env.USAGE.idFromName(deviceId));
  const response = await stub.fetch(
    `https://usage/consume?tier=${encodeURIComponent(tier)}&window=${encodeURIComponent(window)}&now=${now}`,
  );
  return (await response.json()) as Decision;
}

async function spendCheck(
  env: Env,
  hooks: Hooks,
  now: number,
): Promise<{ withinCeiling: boolean; spentUSD: number }> {
  const ceiling = Number(env.MONTHLY_SPEND_CEILING_USD ?? "0");
  const stub = env.SPEND.get(env.SPEND.idFromName("global"));
  const response = await stub.fetch(`https://spend/check?ceiling=${ceiling}&now=${now}`);
  return (await response.json()) as { withinCeiling: boolean; spentUSD: number };
}

async function recordSpend(env: Env, usd: number, hooks: Hooks, now: number): Promise<void> {
  if (!(usd > 0)) return;
  const stub = env.SPEND.get(env.SPEND.idFromName("global"));
  await stub.fetch(`https://spend/record?usd=${usd}&now=${now}`);
}

/** Non-streaming responses carry usage in the body. */
function recordSpendFromBody(
  text: string,
  env: Env,
  ctx: ExecutionContext,
  hooks: Hooks,
  now: number,
): void {
  ctx.waitUntil(
    (async () => {
      try {
        const parsed = JSON.parse(text) as Record<string, any>;
        const cost = estimateCostUSD(
          Number(parsed.usage?.input_tokens ?? 0),
          Number(parsed.usage?.output_tokens ?? 0),
        );
        await recordSpend(env, cost, hooks, now);
      } catch {
        // An unparseable success body means no usage figure. Losing one
        // reading is better than failing a request that already succeeded.
      }
    })(),
  );
}
