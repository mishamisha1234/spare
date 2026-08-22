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
 *
 * Plus one that is not a generation call:
 *
 *   GET  /v1/status      (authenticated; read-only spend and usage)
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
  /**
   * Optional. Enables the read-only `/v1/status` endpoint when set.
   *
   * Unset is the safe default and the endpoint 404s, so a deploy that never
   * configures it does not advertise that it exists.
   */
  ADMIN_TOKEN?: string;
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

    // Handled before the method guard, because a status read is a GET. It is
    // the only endpoint that is not a generation call, and the only one that
    // answers a question about the deployment rather than about a lesson.
    if (url.pathname === "/v1/status") {
      return handleStatus(request, url, env, now);
    }

    // Operator bypass, for generating a batch of lessons to read and judge.
    //
    // Skips the per-device limits and the cache, so every request generates.
    // Deliberately does NOT skip the spend ceiling or the request policy: those
    // are what stop a leaked token turning into an unbounded bill, and a bypass
    // that disabled them would be a worse hole than the one it exists to work
    // around. Spend is recorded exactly as for any other request.
    const isOperator = isAuthorisedOperator(request, env);

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
      case "/v1/outline":
      case "/v1/chapter":
        return handleGeneration(
          body, modelRequest, env, entitlement, deviceId, ctx, hooks, now, isOperator,
        );

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

/**
 * Read-only operational status: what the ceiling is, and what has been spent
 * against it this month.
 *
 * Exists because that question was otherwise unanswerable from outside. The
 * `SpendLedger` object knew the number and nothing exposed it, so the one
 * figure the whole design is built to protect could only be inferred from
 * Anthropic's own billing page — which lags, and which cannot distinguish this
 * Worker's spend from anything else on the same key.
 *
 * Authenticated, because monthly spend and per-device usage are nobody else's
 * business. Unset token means the route does not exist at all rather than
 * refusing politely: an endpoint that answers "unauthorized" has confirmed it
 * is there.
 *
 * Deliberately read-only. There is no way through here to reset a counter,
 * raise the ceiling, or clear the cache — a token pasted into a terminal should
 * not be able to unlock free generation, and changing limits is a deploy, where
 * it is reviewable.
 */
async function handleStatus(
  request: Request,
  url: URL,
  env: Env,
  now: number,
): Promise<Response> {
  if (!env.ADMIN_TOKEN) {
    return errorResponse(404, "unknownEndpoint", "No such endpoint.");
  }
  if (request.method !== "GET") {
    return errorResponse(405, "methodNotAllowed", "Status is a GET.");
  }

  if (!isAuthorisedOperator(request, env)) {
    return errorResponse(401, "unauthorized", "Not authorised.");
  }

  const ceiling = Number(env.MONTHLY_SPEND_CEILING_USD ?? "0");
  const spendStub = env.SPEND.get(env.SPEND.idFromName("global"));
  const spend = (await (await spendStub.fetch(`https://spend/peek?now=${now}`)).json()) as {
    month: string;
    spentUSD: number;
  };

  const payload: Record<string, unknown> = {
    month: spend.month,
    spentUSD: Number(spend.spentUSD.toFixed(6)),
    ceilingUSD: ceiling,
    withinCeiling: spend.spentUSD < ceiling,
    // What a free request would be told right now, so the answer doesn't have
    // to be recomputed by eye from the two numbers above.
    freeGenerationPaused: !(spend.spentUSD < ceiling),
  };

  // Optional: one device's counters, for confirming a limit actually moved.
  const device = url.searchParams.get("device");
  if (device) {
    const usageStub = env.USAGE.get(env.USAGE.idFromName(device));
    const usage = await (await usageStub.fetch(`https://usage/peek?now=${now}`)).json();
    payload.device = { id: device, usage };
  }

  return new Response(JSON.stringify(payload, null, 2), {
    status: 200,
    headers: { ...JSON_HEADERS, "cache-control": "no-store" },
  });
}

/**
 * Whether this request carries the operator token.
 *
 * One definition, used by both the status endpoint and the generation bypass,
 * so there is a single place where "is this us" is decided. Returns false when
 * no token is configured, which is what makes an unconfigured deploy safe by
 * default rather than safe by accident.
 */
function isAuthorisedOperator(request: Request, env: Env): boolean {
  if (!env.ADMIN_TOKEN) return false;
  return constantTimeEquals(request.headers.get("x-spare-admin") ?? "", env.ADMIN_TOKEN);
}

/**
 * Compares without leaking length or position through timing.
 *
 * Hand-rolled rather than using a platform helper so it behaves identically in
 * workerd and in the test runner. The loop runs over the longer of the two so
 * a wrong-length guess costs the same as a wrong-value one.
 */
function constantTimeEquals(a: string, b: string): boolean {
  if (a.length === 0 || b.length === 0) return false;
  let diff = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i += 1) {
    diff |= (a.charCodeAt(i % a.length) || 0) ^ (b.charCodeAt(i % b.length) || 0);
  }
  return diff === 0;
}

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
  recordSpendFromBody(
      text,
      typeof modelRequest.model === "string" ? modelRequest.model : undefined,
      env, ctx, hooks, now,
    );
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
  isOperator = false,
): Promise<Response> {
  const window = typeof body.window === "string" ? body.window : "three";
  const format = typeof body.format === "string" ? body.format : "oneThing";
  const topic = typeof body.topic === "string" ? body.topic : "";

  const isFree = entitlement.tier === "free";
  const cacheKey = lessonCacheKey({ window, format, topic });

  // The outline is the only generation call that comes back as JSON. It is
  // metered like the rest — it is what starts a course, so it is what the
  // course cap should count — but there is nothing to tee, and the cache holds
  // SSE, so both the cache read and the cache write are skipped for it.
  const streaming = modelRequest.stream === true;

  // Work out what we would serve before metering anything, so the allowance is
  // spent on exactly one thing and never on a request that then fails.
  //
  // Two conditions beyond "there is an entry". It must be under 30 days old,
  // which `readCachedLesson` enforces. And this device must not already have
  // read it — otherwise a reader who asks about bridges twice gets the same
  // lesson back, which reads as the app being broken rather than as a cache
  // working.
  //
  // The operator bypass skips the cache too: a batch run exists to produce
  // fresh lessons to judge, and replaying old ones would quietly make it
  // measure nothing.
  let cachedEntry: Awaited<ReturnType<typeof readCachedLesson>> = null;
  if (streaming && isFree && topic && !isOperator) {
    const cached = await readCachedLesson(env.LESSONS, cacheKey, now);
    if (cached && !(await hasSeenLesson(env, deviceId, cacheKey))) {
      cachedEntry = cached;
    }
  }

  // The ceiling guards spend, and a cached lesson costs nothing to serve, so it
  // only applies when we are about to generate. That keeps the documented
  // behaviour: past the ceiling, free generation stops and the cache still
  // answers.
  if (!cachedEntry) {
    const ceiling = await spendCheck(env, hooks, now);
    if (!ceiling.withinCeiling && isFree) {
      return errorResponse(
        429,
        "spendCeilingReached",
        "Spare is at its monthly limit. Try again later.",
      );
    }
  }

  // One lesson a day, whatever its source.
  //
  // Cached reads used to be free, on the reasoning that a cache hit costs
  // nothing so charging a day's allowance for it would be punitive. That was
  // wrong for a reason that has nothing to do with cost: a reader cannot tell a
  // cached lesson from a generated one, so an allowance that only counted
  // generations made the free tier behave unpredictably from their side and
  // impossible to describe honestly on the paywall. It also decayed — the
  // fuller the cache, the more a free user could read, so the more successful
  // the app became the weaker its paywall got.
  //
  // Metering here rather than inside the cache branch also closes the
  // hasSeen/markSeen race for free: `consume` is atomic and allows one lesson
  // per day, so two simultaneous requests cannot both reach the serve step.
  if (!isOperator) {
    // Keyed on the lesson, not the request. The draft and the revision, and an
    // outline and its eight chapter calls, all carry the same key and are one
    // charge between them. Counting requests meant a free user's allowance went
    // on the draft and the revision came back 402 — the free tier could not
    // finish a single lesson — and one course counted nine against a cap of
    // twelve. `ProxyProviderTests` already asserted this contract from the
    // client side; nothing asserted it here.
    const decision = await consume(
      env, deviceId, entitlement.tier, window, cacheKey, hooks, now,
    );
    if (!decision.allow) {
      return errorResponse(402, decision.reason, denialMessage(decision.reason));
    }
  }

  if (cachedEntry) {
    await markSeen(env, deviceId, cacheKey);
    return replayCachedLesson(cachedEntry.sse);
  }

  const upstream = await callAnthropic(modelRequest, {
    apiKey: env.ANTHROPIC_API_KEY,
    fetcher: hooks.fetcher,
  });

  if (!upstream.ok) return passUpstreamError(upstream);

  if (!streaming) {
    const text = await upstream.text();
    recordSpendFromBody(
      text,
      typeof modelRequest.model === "string" ? modelRequest.model : undefined,
      env, ctx, hooks, now,
    );
    return new Response(text, { status: 200, headers: JSON_HEADERS });
  }

  // Forwarded byte-for-byte; observation happens on a teed branch after the
  // response is already on its way. See `forwardStream`.
  return forwardStream(
    upstream,
    async (fullBody) => {
      const parsed = parseCompletedStream(fullBody);
      const cost = estimateCostUSD(
        parsed.inputTokens,
        parsed.outputTokens,
        typeof modelRequest.model === "string" ? modelRequest.model : undefined,
      );
      await recordSpend(env, cost, hooks, now);

      // Only cache a stream that actually finished. Caching a truncated one
      // would serve the truncation to everyone who asks next.
      if (parsed.complete && topic) {
        await writeCachedLesson(env.LESSONS, cacheKey, {
          sse: fullBody,
          createdAt: now,
          originalCostUSD: cost,
        });
        // Recorded against the reader who generated it, so tomorrow they aren't
        // served their own lesson back from the cache. Marked here rather than
        // when generation started, so a truncated stream — which is also not
        // cached — doesn't count as read.
        await markSeen(env, deviceId, cacheKey);
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
 * Anthropic's own error taxonomy, as an allowlist.
 *
 * The whole error body still never reaches a client — it can name the model,
 * the account, or the key's shape. But the `type` field is a fixed enum with
 * none of that in it, and withholding it cost two separate investigations: a
 * batch run reported six identical "rejected upstream" failures and the log
 * could not say whether that was a malformed request, an expired key, or an
 * exhausted balance. A value not on this list is reported as unrecognised
 * rather than echoed, so nothing free-form can ride out on this path.
 */
const UPSTREAM_ERROR_TYPES = new Set([
  "invalid_request_error",
  "authentication_error",
  "permission_error",
  "not_found_error",
  "request_too_large",
  "rate_limit_error",
  "billing_error",
  "api_error",
  "overloaded_error",
]);

async function upstreamErrorType(upstream: Response): Promise<string> {
  try {
    const body = (await upstream.clone().json()) as { error?: { type?: unknown } };
    const type = body?.error?.type;
    if (typeof type === "string" && UPSTREAM_ERROR_TYPES.has(type)) return type;
    return "unrecognised";
  } catch {
    return "unreadable";
  }
}

/**
 * Upstream failures are forwarded as a status the app can map, plus the class
 * of failure and nothing else.
 *
 * The two 5xx-shaped outcomes are split. 503 means Anthropic is down and the
 * request was fine, which is worth retrying. 502 means Anthropic refused what
 * this proxy sent, which is a bug or an account problem here — retrying it
 * three times, as the client used to, buys nothing but latency.
 */
async function passUpstreamError(upstream: Response): Promise<Response> {
  if (upstream.status === 429) {
    return errorResponse(429, "rateLimited", "Anthropic is throttling requests. Try shortly.");
  }
  const kind = await upstreamErrorType(upstream);
  if (upstream.status >= 500) {
    return errorResponse(
      503,
      "upstreamUnavailable",
      `The model is unavailable right now (${upstream.status} ${kind}).`,
    );
  }
  return errorResponse(
    502,
    "upstreamRejected",
    `The request was rejected upstream (${upstream.status} ${kind}).`,
  );
}

async function consume(
  env: Env,
  deviceId: string,
  tier: string,
  window: string,
  lessonKey: string,
  hooks: Hooks,
  now: number,
): Promise<Decision> {
  const stub = env.USAGE.get(env.USAGE.idFromName(deviceId));
  const response = await stub.fetch(
    `https://usage/consume?tier=${encodeURIComponent(tier)}` +
      `&window=${encodeURIComponent(window)}` +
      `&key=${encodeURIComponent(lessonKey)}&now=${now}`,
  );
  return (await response.json()) as Decision;
}

/**
 * Whether this device has already been served this lesson.
 *
 * A plain read, now that metering happens before the serve step: `consume` is
 * atomic and allows one lesson a day, so the read-then-mark sequence cannot be
 * raced by a second request from the same device. Before that it needed to be
 * an atomic claim.
 *
 * Answers "yes" if the lookup itself fails, so a Durable Object hiccup falls
 * through to generation. That costs money and serves a correct lesson, which is
 * the right way round — serving a possible repeat to save a fraction of a penny
 * is the trade nobody wants.
 */
async function hasSeenLesson(env: Env, deviceId: string, cacheKey: string): Promise<boolean> {
  try {
    const stub = env.USAGE.get(env.USAGE.idFromName(deviceId));
    const response = await stub.fetch(
      `https://usage/hasSeen?key=${encodeURIComponent(cacheKey)}`,
    );
    const body = (await response.json()) as { seen?: boolean };
    return body.seen === true;
  } catch {
    return true;
  }
}

async function markSeen(env: Env, deviceId: string, cacheKey: string): Promise<void> {
  const stub = env.USAGE.get(env.USAGE.idFromName(deviceId));
  await stub.fetch(`https://usage/markSeen?key=${encodeURIComponent(cacheKey)}`);
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
  model: string | undefined,
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
          model,
        );
        await recordSpend(env, cost, hooks, now);
      } catch {
        // An unparseable success body means no usage figure. Losing one
        // reading is better than failing a request that already succeeded.
      }
    })(),
  );
}
