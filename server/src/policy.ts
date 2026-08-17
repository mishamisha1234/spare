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

/** Models the proxy will pay for. Mirrors `AnthropicAPI.model` in SpareCore. */
export const ALLOWED_MODELS = new Set(["claude-opus-5"]);

/**
 * Per-endpoint `max_tokens` ceilings, taken from what the app actually asks
 * for, with no headroom added — headroom here is money someone else can spend.
 *
 * 24,000 is `AnthropicAPI.maxTokens(for: .fifteen)`, the largest legitimate
 * single request. The 30-minute course asks for 16,000 per chapter and is
 * capped by the course limit, not by this.
 */
export const TOKEN_CEILINGS: Record<string, number> = {
  "/v1/suggestions": 4_000,
  "/v1/lesson": 24_000,
  "/v1/chapter": 24_000,
  "/v1/recall": 2_000,
  "/v1/post-lesson-test": 3_500,
  "/v1/go-deeper": 24_000,
};

/** Endpoints whose upstream call must stream, because the response is forwarded. */
export const STREAMING_ENDPOINTS = new Set(["/v1/lesson", "/v1/chapter"]);

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
