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
 * Plus three that are not generation calls:
 *
 *   POST /v1/attachments (read a cached lesson's recall question and test)
 *   POST /v1/attach      (store them, once, from the device that generated it)
 *   GET  /v1/status      (authenticated; read-only spend and usage)
 */

import {
  checkAttachments,
  isGenerator,
  readAttachments,
  recordGenerator,
  writeAttachments,
} from "./attachments";
import {
  AppStoreVerificationError,
  FREE_ENTITLEMENT,
  hasPremiumAccess,
  isPaying,
  verifyEntitlement,
  type AppStoreConfig,
  type EffectiveTier,
  type VerifiedEntitlement,
} from "./appstore";
import {
  courseGrantKey,
  lessonCacheKey,
  lessonPoolKey,
  poolFor,
  readCachedLesson,
  replayCachedJSON,
  replayCachedLesson,
  unitFor,
  writeCachedLesson,
  type LessonIdentity,
} from "./cache";
import {
  CHAPTERED_WINDOWS,
  FunnelLedger,
  SpendLedger,
  UsageCounter,
  type Decision,
  type FunnelCounter,
  type FunnelState,
  type TrialView,
} from "./limits";
import type { Pool } from "./cache";
import { applyPolicy, hardWordFloor, POOL_MODELS } from "./policy";
import {
  bodyWordCount,
  callAnthropic,
  estimateCostUSD,
  forwardStream,
  parseCompletedStream,
} from "./upstream";

export { FunnelLedger, SpendLedger, UsageCounter };

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
  FUNNEL: DurableObjectNamespace;
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

    // The reverse trial, which is an entitlement with no transaction behind
    // it. Only a device Apple says is free can be trialing: somebody with a
    // live subscription has nothing to gain from it, and burning their one
    // trial while they are already paying would be taking something away.
    //
    // Read here, before the pool and the model are chosen, because those
    // decisions cannot wait for the atomic claim. The claim happens later in
    // `UsageCounter.consume`, and a race between the two can only route a
    // request to Opus and then refuse it -- see the note there.
    let trial: TrialView | null = null;
    let effectiveTier: EffectiveTier = entitlement.tier;
    if (entitlement.tier === "free") {
      trial = await readTrial(env, deviceId, now);
      if (trial?.status === "active") effectiveTier = "trialing";
    }

    // Starting and reading the trial are not generation calls and carry no
    // model request, so they are answered before the policy layer -- the same
    // reasoning as attachments below.
    if (url.pathname === "/v1/trial/start" || url.pathname === "/v1/trial/status") {
      return withTrialHeader(
        await handleTrial(url.pathname, env, deviceId, entitlement, ctx, now),
        trial,
      );
    }

    // Two events the server cannot see for itself. Not a generation call and
    // not metered; see `FunnelLedger` for why five global integers with no
    // device identifiers is a different thing from analytics.
    if (url.pathname === "/v1/funnel") {
      return handleFunnel(body, env, deviceId, ctx, now);
    }

    // A course whose outline was already paid for may finish, out of the pool
    // it was written into.
    //
    // Looked up here rather than at metering time because the pool decision
    // happens here, and a course started under a trial lives in the premium
    // pool: serving its remaining chapters out of the free pool would drop a
    // Sonnet chapter into an Opus course and miss the cached outline entirely.
    const grantedPool = hasPremiumAccess(effectiveTier)
      ? null
      : await readCourseGrant(env, deviceId, body, now);

    // Which pool this reader belongs to, from what the server decided --
    // never from anything the client said.
    const pool = grantedPool ?? poolFor(effectiveTier);

    // Attachments carry no model request and cost nothing to serve, so they
    // are answered before the policy layer, which exists to decide what a
    // generation may spend.
    if (url.pathname === "/v1/attachments" || url.pathname === "/v1/attach") {
      return withTrialHeader(
        await handleAttachments(url.pathname, body, pool, env, deviceId, now),
        trial,
      );
    }

    // The client builds the Anthropic request; the proxy decides what it is
    // allowed to be. Runs before any metering so a request that will be
    // refused never consumes an allowance. See `policy.ts`.
    //
    // The operator tool keeps its own choice of model, because comparing
    // models is the whole reason it exists. Everyone else gets their pool's.
    const policy = applyPolicy(
      body.request,
      url.pathname,
      isOperator ? undefined : POOL_MODELS[pool],
    );
    if (!policy.ok) {
      const status = policy.code === "unknownEndpoint" ? 404 : 400;
      return errorResponse(status, policy.code, policy.message);
    }
    const modelRequest = policy.request;

    switch (url.pathname) {
      case "/v1/suggestions":
      case "/v1/recall":
      case "/v1/post-lesson-test":
        return withTrialHeader(
          await handleUnmetered(modelRequest, env, effectiveTier, ctx, hooks, now),
          trial,
        );

      case "/v1/lesson":
      case "/v1/outline":
      case "/v1/chapter":
        return withTrialHeader(
          await handleGeneration(
            body, modelRequest, url.pathname, pool, env, effectiveTier, deviceId,
            ctx, hooks, now, isOperator,
          ),
          // Re-read after metering: this is the response that just spent a
          // trial lesson, and a count taken before the spend would be one
          // ahead of the truth on the reader's screen.
          effectiveTier === "trialing" ? await readTrial(env, deviceId, now) : trial,
        );

      case "/v1/go-deeper":
        // Premium-only, and cheap enough not to meter separately.
        if (!hasPremiumAccess(effectiveTier)) {
          return errorResponse(402, "goDeeperLocked", "Going deeper is part of Premium.");
        }
        return withTrialHeader(
          await handleUnmetered(modelRequest, env, effectiveTier, ctx, hooks, now),
          trial,
        );

      default:
        return errorResponse(404, "unknownEndpoint", "No such endpoint.");
    }
  },
};

/**
 * Reading and writing the artifacts that travel with a cached lesson.
 *
 * Neither call generates anything, and that is the whole point: a cached
 * lesson already has its recall question and, in the premium pool, its test,
 * so a reader who is served one costs nothing beyond the read. See
 * `attachments.ts` for why per-reader generation is not an option.
 *
 * Free readers get a recall question and no test. That is not a gate applied
 * here — the free pool simply has no test to give, because Sonnet is never
 * asked to write one.
 */
async function handleAttachments(
  pathname: string,
  body: Record<string, any>,
  pool: Pool,
  env: Env,
  deviceId: string,
  now: number,
): Promise<Response> {
  const window = typeof body.window === "string" ? body.window : "three";
  const identity: LessonIdentity = {
    pool,
    window,
    format: typeof body.format === "string" ? body.format : "oneThing",
    topic: typeof body.topic === "string" ? body.topic : "",
    interest: typeof body.interest === "string" ? body.interest : "",
  };
  if (identity.topic === "") {
    return errorResponse(400, "malformedRequest", "A topic is required.");
  }

  if (pathname === "/v1/attachments") {
    const stored = await readAttachments(env.LESSONS, identity, now);
    if (!stored) {
      // 404 rather than an empty object, so a client can tell "nothing is
      // attached yet, generate it" from "attached, and the test is empty
      // because this is the free pool".
      return errorResponse(404, "noAttachments", "Nothing is attached to that lesson.");
    }
    return new Response(
      JSON.stringify({ recall: stored.recall, test: stored.test }),
      { status: 200, headers: { ...JSON_HEADERS, "cache-control": "no-store" } },
    );
  }

  // Writing. Two guards, and they answer different questions.
  //
  // The first is *may this device write here at all*: only the one that
  // generated the lesson, which it proves by having been recorded as its
  // generator when the body was cached. Device ids are spoofable, so this is
  // not a strong claim — what it does is turn "anyone may overwrite any entry"
  // into "you must first pay to generate the lesson you want to attach to".
  if (!(await isGenerator(env.LESSONS, identity, deviceId))) {
    return errorResponse(
      403,
      "notTheGenerator",
      "Attachments come from the device that generated the lesson.",
    );
  }

  // The second is *is this the right shape for this length*. A 30-minute
  // course with a two-question test is a premium feature quietly failing to be
  // what it was sold as, for everyone who reads that lesson for thirty days.
  const checked = checkAttachments(body.attachments, pool, window, now);
  if (!checked.ok) {
    return errorResponse(400, checked.code, checked.message);
  }

  await writeAttachments(env.LESSONS, identity, checked.attachments);
  return new Response(JSON.stringify({ stored: true }), { status: 200, headers: JSON_HEADERS });
}

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

  const funnel = await readFunnel(env);

  const payload: Record<string, unknown> = {
    month: spend.month,
    spentUSD: Number(spend.spentUSD.toFixed(6)),
    ceilingUSD: ceiling,
    withinCeiling: spend.spentUSD < ceiling,
    // What a free request would be told right now, so the answer doesn't have
    // to be recomputed by eye from the two numbers above.
    freeGenerationPaused: !(spend.spentUSD < ceiling),
    // The reverse trial's funnel. Five integers, no device identifiers --
    // see `FunnelLedger` for why that is compatible with the no-tracking
    // promise, and why a device-local log cannot answer this question.
    funnel: funnel === null ? null : {
      ...funnel,
      // The one number §6 is about: of the readers who dismissed the first
      // paywall, what share went on to read enough to have an opinion. Above
      // 40% the model works and the lever is pricing; under 15% the lessons
      // are not good enough and no pricing change fixes that.
      //
      // Null rather than zero until somebody has dismissed a paywall. A
      // percentage of nothing is not a small percentage.
      engagedShare: funnel.paywallsDismissed > 0
        ? Number(
            ((funnel.trialsWithThreePlusLessons / funnel.paywallsDismissed) * 100).toFixed(1),
          )
        : null,
    },
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
  tier: EffectiveTier,
  ctx: ExecutionContext,
  hooks: Hooks,
  now: number,
): Promise<Response> {
  const ceiling = await spendCheck(env, hooks, now);
  if (!ceiling.withinCeiling && !isPaying(tier)) {
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
  /** Which generation endpoint this is. Decides the word floor: a chapter is
   * measured against a chapter's budget, not the whole course's. */
  pathname: string,
  /** Which pool to read from and write to. Decided by the server, never sent. */
  pool: Pool,
  env: Env,
  tier: EffectiveTier,
  deviceId: string,
  ctx: ExecutionContext,
  hooks: Hooks,
  now: number,
  isOperator = false,
): Promise<Response> {
  const window = typeof body.window === "string" ? body.window : "three";
  const format = typeof body.format === "string" ? body.format : "oneThing";
  const topic = typeof body.topic === "string" ? body.topic : "";
  const interest = typeof body.interest === "string" ? body.interest : "";
  const chapterIndex = Number.isInteger(body.chapter) ? (body.chapter as number) : null;

  const identity: LessonIdentity = { pool, window, format, topic, interest };

  // Two keys, and the difference matters.
  //
  // `chargeKey` is the lesson: one course, one charge, one "already read"
  // mark, however many requests it takes. `cacheKey` is one stored body —
  // the whole lesson, the outline, or one chapter. Collapsing them is what
  // made every chapter of a course overwrite the last.
  const chargeKey = lessonPoolKey(identity);
  const cacheKey = lessonCacheKey(identity, unitFor(pathname, chapterIndex));

  // The outline comes back as JSON rather than a stream. It is cached like
  // everything else — a cached course whose outline regenerated would hand
  // the reader chapter headings that do not match the chapters underneath
  // them — but it is replayed as JSON and never teed.
  const streaming = modelRequest.stream === true;
  // A chapter request with no index cannot be cached: every chapter of the
  // course would collide on one key. Better to pay for it than to poison the
  // pool with a course made of four copies of chapter four.
  // Read on either pass, write only on the final one.
  //
  // A draft must never be *written*: it is pass 1 of two, the reader never
  // sees it, and an entry holding one would serve unrevised prose to everyone
  // who asks that question for thirty days.
  //
  // But a draft must still be allowed to *read*, and that is the half that is
  // easy to get backwards. The client always sends the draft first. If the
  // cache only answered the revision, every hit would still have paid for a
  // draft it threw away — which is most of the saving gone, on the path the
  // cache exists for.
  //
  // Marking the entry read is likewise the final pass's job, so the revision
  // that follows a hit is a hit too, instead of finding its own draft has
  // already spent the entry.
  const isFinalPass = body.pass !== "draft";
  const cacheable = topic !== ""
    && !(pathname === "/v1/chapter" && chapterIndex === null);

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
  //
  // Both tiers read the cache now. Premium used to always generate, which was
  // the old shape of the product: premium bought fresh authorship. It buys
  // the better pool and interest matching instead, so a premium reader being
  // served another premium reader's lesson is the design rather than a
  // shortfall — and a 30-minute course read by two hundred people cannot be
  // written two hundred times.
  //
  // Seen-once is keyed on the stored body, not the lesson.
  //
  // Which is what makes a course work now that chapters have their own keys: a
  // reader is served each chapter once, in order, and none of them is blocked
  // because an earlier one was marked. On a later day every unit of that
  // course is marked, so the outline and all four chapters regenerate
  // together — the outline cannot come back fresh while the chapters under it
  // come back cached, which would leave the headings describing something
  // else.
  let cachedEntry: Awaited<ReturnType<typeof readCachedLesson>> = null;
  if (cacheable && !isOperator) {
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
    // `isPaying`, not "not premium": the ceiling is lifted for funded
    // requests, and only for those.
    if (!ceiling.withinCeiling && !isPaying(tier)) {
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
      env, deviceId, tier, window, chargeKey,
      // The grant key, for a course. Pool-independent, so a course started
      // under an entitlement that has since gone still resolves to the same
      // grant. Empty for anything that is not chaptered.
      format === "chaptered" ? courseGrantKey({ window, format, topic, interest }) : "",
      pool, hooks, now,
    );
    if (!decision.allow) {
      return errorResponse(402, decision.reason, denialMessage(decision.reason));
    }
    // Reported by the meter on the transition, so it counts devices rather
    // than requests. See `FunnelLedger`.
    if (decision.milestone === "trialThreeLessons") {
      bumpFunnel(env, ctx, "trialsWithThreePlusLessons");
    }
  }

  if (cachedEntry) {
    if (isFinalPass) await markSeen(env, deviceId, cacheKey);
    return cachedEntry.streaming === false
      ? replayCachedJSON(cachedEntry.sse)
      : replayCachedLesson(cachedEntry.sse);
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
    // The outline, cached so a course's chapters keep matching the headings
    // they were written under. No word floor applies: an outline is a plan,
    // not prose, and measuring it against a course's 6,000-word floor would
    // refuse every outline ever written.
    if (cacheable && isFinalPass && !isOperator && isCompleteMessage(text)) {
      ctx.waitUntil(Promise.all([
        writeCachedLesson(env.LESSONS, cacheKey, {
          sse: text,
          streaming: false,
          createdAt: now,
          originalCostUSD: 0,
        }),
        // Who may attach a test to this lesson later. See `attachments.ts`.
        recordGenerator(env.LESSONS, identity, deviceId),
      ]));
    }
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

      // Two admission rules, and they are the same rule.
      //
      // A stream that did not finish is a truncated lesson, and caching it
      // would serve the truncation to everyone who asks next. A stream that
      // finished but came back materially under its word floor is a lesson
      // that is not the length it was sold as, and caching it would serve
      // *that* to everyone who asks next. The reader who generated it may
      // still be looking at it — the app has its own floor check and retries,
      // and by here the response has already been forwarded — but nothing
      // short earns a thirty-day life in the pool.
      //
      // `words === null` means the body could not be read at all, which is not
      // the same as short and is not a reason to be lenient.
      const floor = hardWordFloor(window, pathname);
      const words = bodyWordCount(parsed.text);
      const longEnough = floor === null
        ? false
        : words !== null && words >= floor;

      if (parsed.complete && cacheable && isFinalPass && longEnough) {
        await writeCachedLesson(env.LESSONS, cacheKey, {
          sse: fullBody,
          createdAt: now,
          originalCostUSD: cost,
        });
        // Who may attach a test to this lesson later. See `attachments.ts`.
        await recordGenerator(env.LESSONS, identity, deviceId);
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

/**
 * Whether a non-streaming upstream body is a finished message worth caching.
 *
 * The streamed path has `message_stop` to go on. This one has the message
 * envelope: a body that will not parse, or that came back truncated at
 * `max_tokens`, is the same kind of thing as a cut-off stream and gets the
 * same answer.
 */
function isCompleteMessage(text: string): boolean {
  try {
    const parsed = JSON.parse(text) as { stop_reason?: unknown; content?: unknown };
    if (!Array.isArray(parsed.content) || parsed.content.length === 0) return false;
    return parsed.stop_reason !== "max_tokens" && parsed.stop_reason !== "refusal";
  } catch {
    return false;
  }
}

function denialMessage(reason: Decision extends { allow: false } ? never : string): string {
  switch (reason) {
    case "dailyLimitReached":
      return "That's today's free lesson. The next one unlocks tomorrow.";
    case "lockedWindow":
      return "That length is part of Premium.";
    case "courseCapReached":
      return "You've started every course included this month.";
    case "trialEnded":
      return "Your free week is over.";
    case "trialCourseCapReached":
      return "That's both courses from your free week. The shorter lengths still work.";
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

/**
 * This device's trial, as the client is allowed to see it.
 *
 * Read-only and display-only. Nothing the app does with this answer can grant
 * anything: the pool, the model, and the counters are all decided server-side
 * from the same state, and `UsageCounter.consume` re-checks it atomically
 * before a single token is generated.
 *
 * Null when the object could not be reached. Not "ended", which it used to be:
 * that is a real state with a real meaning, and manufacturing it here put a
 * fabricated `x-spare-trial` header on the wire saying a reader's week was
 * over. Refusing to answer is the honest failure, and the caller already
 * treats "no trial" as free -- so nothing is granted either way.
 */
/**
 * The pool a started course may keep drawing from, or null.
 *
 * Only asked for chaptered requests, so an ordinary lesson costs no extra
 * round trip. Falls back to null on any failure -- a Durable Object hiccup
 * must not hand a free device the premium pool.
 */
/**
 * `POST /v1/funnel`.
 *
 * Two events, both of which happen on the device and neither of which reaches
 * the server any other way: dismissing the first paywall, and buying. The
 * second is resolved against this device's own trial state, so the client says
 * *that* it converted and the server decides whether that was the day-7
 * decision or a later one.
 *
 * Always answers 204. There is nothing useful to tell a client about a counter,
 * and an error here must never surface as a failure in the app.
 */
async function handleFunnel(
  body: Record<string, any>,
  env: Env,
  deviceId: string,
  ctx: ExecutionContext,
  now: number,
): Promise<Response> {
  const event = typeof body.event === "string" ? body.event : "";

  if (event === "paywallDismissed") {
    bumpFunnel(env, ctx, "paywallsDismissed");
  } else if (event === "converted") {
    ctx.waitUntil(recordConversion(env, deviceId, now));
  }

  return new Response(null, { status: 204 });
}

/**
 * Counts a purchase once, on the side of expiry it actually fell.
 *
 * The Durable Object decides both, because it holds the trial and the
 * already-counted flag -- a client that reported "I converted at day 7" would
 * be reporting on the number the day-7 screen is being judged by.
 */
async function recordConversion(env: Env, deviceId: string, now: number): Promise<void> {
  try {
    const stub = env.USAGE.get(env.USAGE.idFromName(deviceId));
    const response = await stub.fetch(`https://usage/trial/converted?now=${now}`);
    const result = (await response.json()) as { recorded: "atDay7" | "afterDay7" | null };
    if (result.recorded === "atDay7") await bumpFunnelNow(env, "convertedAtDay7");
    if (result.recorded === "afterDay7") await bumpFunnelNow(env, "convertedAfterDay7");
  } catch {
    // A missed counter is a slightly wrong marketing number. Never a failure
    // the reader sees.
  }
}

function bumpFunnel(env: Env, ctx: ExecutionContext, counter: FunnelCounter): void {
  ctx.waitUntil(bumpFunnelNow(env, counter));
}

async function bumpFunnelNow(env: Env, counter: FunnelCounter): Promise<void> {
  try {
    const stub = env.FUNNEL.get(env.FUNNEL.idFromName("global"));
    await stub.fetch(`https://funnel/bump?counter=${encodeURIComponent(counter)}`);
  } catch {
    // Same reasoning as above.
  }
}

/**
 * Null when the counters could not be read.
 *
 * Not five zeros, which it used to be. `/v1/status` is read by a human
 * deciding whether the reverse trial is working, and "0 trials started" is a
 * finding. Reporting an unreachable object as an empty one turns a broken
 * binding into a business conclusion.
 */
async function readFunnel(env: Env): Promise<FunnelState | null> {
  try {
    const stub = env.FUNNEL.get(env.FUNNEL.idFromName("global"));
    const response = await stub.fetch("https://funnel/peek");
    if (!response.ok) return null;
    return (await response.json()) as FunnelState;
  } catch {
    return null;
  }
}

async function readCourseGrant(
  env: Env,
  deviceId: string,
  body: Record<string, any>,
  now: number,
): Promise<Pool | null> {
  const window = typeof body.window === "string" ? body.window : "";
  if (!CHAPTERED_WINDOWS.includes(window as (typeof CHAPTERED_WINDOWS)[number])) return null;

  try {
    const key = courseGrantKey(courseIdentity(body));
    const stub = env.USAGE.get(env.USAGE.idFromName(deviceId));
    const response = await stub.fetch(
      `https://usage/grant?key=${encodeURIComponent(key)}&now=${now}`,
    );
    const grant = (await response.json()) as { pool: Pool | null };
    return grant.pool === "premium" || grant.pool === "free" ? grant.pool : null;
  } catch {
    return null;
  }
}

/** The pool-independent half of a lesson identity, straight off the body. */
function courseIdentity(body: Record<string, any>): Omit<LessonIdentity, "pool"> {
  return {
    window: typeof body.window === "string" ? body.window : "three",
    format: typeof body.format === "string" ? body.format : "oneThing",
    topic: typeof body.topic === "string" ? body.topic : "",
    interest: typeof body.interest === "string" ? body.interest : "",
  };
}

async function readTrial(env: Env, deviceId: string, now: number): Promise<TrialView | null> {
  try {
    const stub = env.USAGE.get(env.USAGE.idFromName(deviceId));
    const response = await stub.fetch(`https://usage/trial?now=${now}`);
    if (!response.ok) return null;
    return (await response.json()) as TrialView;
  } catch {
    return null;
  }
}

/**
 * `POST /v1/trial/start` and `POST /v1/trial/status`.
 *
 * Eligibility is once per device, forever, and it is the Durable Object that
 * decides -- `startedAt` is both the clock and the consumed flag, so there is
 * no second field to disagree with it.
 *
 * A device with a live subscription is refused rather than started. It has
 * nothing to gain, and consuming its one trial while it is already paying
 * would quietly take something away from a customer.
 */
async function handleTrial(
  pathname: string,
  env: Env,
  deviceId: string,
  entitlement: VerifiedEntitlement,
  ctx: ExecutionContext,
  now: number,
): Promise<Response> {
  const stub = env.USAGE.get(env.USAGE.idFromName(deviceId));

  if (pathname === "/v1/trial/status") {
    const trial = await readTrial(env, deviceId, now);
    // 503 rather than a manufactured answer. The client reads a non-2xx as
    // "I could not ask" and keeps whatever it already had, which is the only
    // honest thing either side can do with a failed read.
    if (!trial) {
      return errorResponse(503, "trialUnavailable", "Couldn't read your trial. Try again shortly.");
    }
    return new Response(JSON.stringify(trial), { status: 200, headers: JSON_HEADERS });
  }

  if (isPaying(entitlement.tier)) {
    const trial = await readTrial(env, deviceId, now);
    if (!trial) {
      return errorResponse(503, "trialUnavailable", "Couldn't read your trial. Try again shortly.");
    }
    return new Response(
      JSON.stringify({ started: false, reason: "alreadySubscribed", trial }),
      { status: 200, headers: JSON_HEADERS },
    );
  }

  const response = await stub.fetch(`https://usage/trial/start?now=${now}`);
  const result = (await response.json()) as { started: boolean; trial: TrialView };
  if (result.started) bumpFunnel(env, ctx, "trialsStarted");
  return new Response(
    JSON.stringify(
      result.started ? result : { ...result, reason: "alreadyUsed" },
    ),
    { status: 200, headers: JSON_HEADERS },
  );
}

/**
 * Attaches the trial mirror to a response.
 *
 * A header rather than a body field because the lesson path is SSE and has no
 * JSON body to put it in, and because a remaining count that only arrived on
 * some endpoints would be a count the app had to guess about. Every response
 * a trialing device gets carries the current one, so the number on their
 * screen is never a round trip behind what they have actually spent.
 */
function withTrialHeader(response: Response, trial: TrialView | null): Response {
  if (!trial || trial.status === "eligible") return response;
  const headers = new Headers(response.headers);
  headers.set("x-spare-trial", JSON.stringify(trial));
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

async function consume(
  env: Env,
  deviceId: string,
  tier: EffectiveTier,
  window: string,
  lessonKey: string,
  courseKey: string,
  pool: Pool,
  hooks: Hooks,
  now: number,
): Promise<Decision> {
  const stub = env.USAGE.get(env.USAGE.idFromName(deviceId));
  const response = await stub.fetch(
    `https://usage/consume?tier=${encodeURIComponent(tier)}` +
      `&window=${encodeURIComponent(window)}` +
      `&key=${encodeURIComponent(lessonKey)}` +
      `&courseKey=${encodeURIComponent(courseKey)}` +
      `&pool=${encodeURIComponent(pool)}&now=${now}`,
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
