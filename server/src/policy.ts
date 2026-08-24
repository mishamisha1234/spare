/**
 * What the client is allowed to ask the model for.
 *
 * The app builds the full Anthropic request body itself and the proxy adds the
 * key. That split is deliberate: the prompts are the product, they live in
 * `Prompts.swift`, and copying them into TypeScript would create two sources of
 * truth for the text that most needs one.
 *
 * The consequence is that the request arriving here is attacker-controlled. A
 * spoofed client could name a different model, ask for a far larger
 * `max_tokens`, or attach fields with billing meaning. The monthly ceiling caps
 * the damage over a month, but a single request should not be able to spend a
 * meaningful fraction of it — so every request is rebuilt here from an
 * allowlist rather than forwarded as received.
 *
 * Rebuilt, not validated. Validation leaves unknown fields in place and quietly
 * grows a hole every time the upstream API gains a parameter; reconstruction
 * means a field the proxy has never heard of cannot reach Anthropic at all.
 */

/**
 * Models the proxy will pay for.
 *
 * The app only ever asks for `AnthropicAPI.model`. The other two are here for
 * the batch tool, which runs one set of topics through several models to
 * compare them, and they are safe to allow for the reason the allowlist exists
 * in the first place: both are cheaper than the model already on the list, so
 * nothing a spoofed client can name here costs more than what it could already
 * ask for.
 */
export const ALLOWED_MODELS = new Set([
  "claude-opus-5",
  "claude-sonnet-5",
  "claude-haiku-4-5-20251001",
]);

/**
 * Per-endpoint `max_tokens` ceilings, taken from what the app actually asks
 * for, with no headroom added — headroom here is money someone else can spend.
 *
 * 24,000 is `AnthropicAPI.maxTokens(for: .fifteen)`, the largest legitimate
 * single request, and now also what a 30-minute course asks for per chapter —
 * raised from 16,000 after the first course to get past the outline came back
 * truncated. A course's total spend is capped by the course limit, not by this.
 */
export const TOKEN_CEILINGS: Record<string, number> = {
  "/v1/suggestions": 4_000,
  "/v1/lesson": 24_000,
  // The course outline: a small structured plan, not prose, and the only
  // generation call that is not streamed. It had no endpoint of its own and was
  // sent to /v1/lesson, which forces streaming — so every 30-minute course ever
  // requested through the proxy failed. See STREAMING_ENDPOINTS below.
  "/v1/outline": 4_000,
  "/v1/chapter": 24_000,
  "/v1/recall": 2_000,
  "/v1/post-lesson-test": 3_500,
  "/v1/go-deeper": 24_000,
};

/**
 * Endpoints whose upstream call must stream, because the response is forwarded.
 *
 * Mirrored by `ProxyRoute.streamingPaths` in SpareCore, and that mirror is the
 * whole contract: the client decides per call whether to stream, this decides
 * per endpoint, and when the two disagree the request is broken in a way
 * neither side's tests can see. A non-streaming call routed to an endpoint in
 * this set is the bug that kept every 30-minute course from ever working.
 */
export const STREAMING_ENDPOINTS = new Set(["/v1/lesson", "/v1/chapter"]);

/**
 * The lower end of each window's word budget, and the fraction of it below
 * which a generation is refused entry to the cache.
 *
 * Mirrors `TimeWindow.wordBudget.lowerBound` and
 * `LessonQualityCheck.hardFloorFraction` in SpareCore, in the same way
 * `TOKEN_CEILINGS` mirrors `AnthropicAPI.maxTokens`. The app checks the floor
 * too, and retries when it misses; this is the half that cannot be bypassed by
 * a client that decides not to.
 *
 * It matters here specifically because of what the cache is. A short lesson
 * shown to the reader who generated it is one bad lesson. The same lesson
 * written into the pool is served to everyone who asks that question for the
 * next thirty days, and nothing about reading it says it is 60% of the length
 * that was promised. Cache entries are the expensive kind of wrong.
 *
 * `/v1/chapter` is measured per chapter, not per course: a chapter of a
 * 30-minute course is a quarter of 6,000 words, and measuring it against the
 * course's floor would refuse every chapter ever written.
 */
export const WORD_FLOORS: Record<string, number> = {
  one: 180,
  three: 500,
  seven: 1100,
  fifteen: 2400,
  thirty: 6000,
};

export const HARD_FLOOR_FRACTION = 0.9;

/** Chapters per window, mirroring `LessonFormat.chapterCount`. */
const CHAPTER_COUNTS: Record<string, number> = { thirty: 4 };

/**
 * The fewest words a completed generation may carry and still be cached.
 *
 * Returns null for a window with no floor on record, which the caller reads as
 * "cannot judge" rather than "passes" — an unknown window is a client this
 * server has not been deployed to match, and guessing in the permissive
 * direction is how a wrong lesson gets a thirty-day life.
 */
export function hardWordFloor(window: string, pathname: string): number | null {
  const floor = WORD_FLOORS[window];
  if (floor === undefined) return null;
  const chapters = pathname === "/v1/chapter" ? (CHAPTER_COUNTS[window] ?? 1) : 1;
  return Math.round((floor / chapters) * HARD_FLOOR_FRACTION);
}

/**
 * Input ceiling, in bytes of serialised request.
 *
 * The largest honest request is a revision pass, which carries the full draft
 * of a chapter plus the system prompt — a few tens of kilobytes. 256 KB leaves
 * that comfortably alone while refusing a body whose only purpose is to be
 * expensive: input is billed too, and a megabyte of it costs real money before
 * a single token comes back.
 */
export const MAX_REQUEST_BYTES = 256 * 1024;

/** Nothing legitimate sends more than a handful. */
export const MAX_MESSAGES = 8;

export type PolicyResult =
  | { ok: true; request: Record<string, unknown> }
  | { ok: false; code: string; message: string };

/**
 * Rebuilds a client request from fields the proxy recognises.
 *
 * `system`, `messages`, and `output_config` are passed through as content —
 * they are the prompt, and the prompt is the app's business. `model`,
 * `max_tokens`, and `stream` are the proxy's business, because they decide what
 * a request costs and whether the response can be forwarded, so the client's
 * values are checked or overwritten rather than trusted.
 */
export function applyPolicy(raw: unknown, pathname: string): PolicyResult {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return { ok: false, code: "malformedRequest", message: "Request body is missing." };
  }
  const input = raw as Record<string, unknown>;

  const ceiling = TOKEN_CEILINGS[pathname];
  if (ceiling === undefined) {
    return { ok: false, code: "unknownEndpoint", message: "No such endpoint." };
  }

  const model = typeof input.model === "string" ? input.model : "";
  if (!ALLOWED_MODELS.has(model)) {
    // Rejected rather than silently substituted: a client asking for a model
    // the server won't pay for is either stale or hostile, and both are worth
    // an explicit answer instead of a surprising one.
    return { ok: false, code: "modelNotAllowed", message: "That model isn't available." };
  }

  const messages = input.messages;
  if (!Array.isArray(messages) || messages.length === 0) {
    return { ok: false, code: "malformedRequest", message: "Request has no messages." };
  }
  if (messages.length > MAX_MESSAGES) {
    return { ok: false, code: "requestTooLarge", message: "Too many messages." };
  }

  // Clamped, not rejected: a client asking for more than its endpoint's
  // ceiling still gets a usable answer, just not a more expensive one. An
  // absent or unparseable value falls to the ceiling for the same reason.
  const requested = Number(input.max_tokens);
  const maxTokens = Number.isFinite(requested) && requested > 0
    ? Math.min(Math.floor(requested), ceiling)
    : ceiling;

  const request: Record<string, unknown> = {
    model,
    max_tokens: maxTokens,
    messages,
    // Forced to the endpoint's mode. A non-streaming response on /v1/lesson
    // would break `forwardStream`, and a streaming one on /v1/recall would be
    // read as text and fail to parse — in both cases from a client-supplied
    // flag, which is not somewhere a server's control flow should live.
    stream: STREAMING_ENDPOINTS.has(pathname),
  };

  if (input.system !== undefined) request.system = input.system;
  if (input.output_config !== undefined) request.output_config = input.output_config;

  // Measured on the rebuilt body, so the number reflects what will actually be
  // sent rather than what arrived.
  const serialised = JSON.stringify(request);
  if (byteLength(serialised) > MAX_REQUEST_BYTES) {
    return { ok: false, code: "requestTooLarge", message: "That request is too large." };
  }

  return { ok: true, request };
}

function byteLength(value: string): number {
  return new TextEncoder().encode(value).length;
}
