/**
 * Talking to Anthropic, and getting the stream to the app untouched.
 */

export const ANTHROPIC_HOST = "https://api.anthropic.com";
const MESSAGES_PATH = "/v1/messages";
const API_VERSION = "2023-06-01";

export interface UpstreamConfig {
  apiKey: string;
  fetcher?: typeof fetch;
}

export async function callAnthropic(
  body: unknown,
  config: UpstreamConfig,
): Promise<Response> {
  const fetcher = config.fetcher ?? fetch;
  return fetcher(`${ANTHROPIC_HOST}${MESSAGES_PATH}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "anthropic-version": API_VERSION,
      // The only place the key appears. It comes from a secret binding and is
      // never returned to the caller, logged, or echoed in an error.
      "x-api-key": config.apiKey,
    },
    body: JSON.stringify(body),
  });
}

/**
 * Forwards an SSE response to the client byte-for-byte while still observing
 * it, using `tee()`.
 *
 * The forwarding has to be exact. `RevisionGate`'s invariants are defined over
 * the SSE event sequence — revised text only ever appends, display is held
 * until pass 2 covers the opening, chapters arrive in order — so any
 * buffering, re-chunking, or JSON round-trip in the middle can turn a valid
 * stream into one the reader rejects. The server's job on this path is to not
 * interfere.
 *
 * But the server also needs the finished text, to record cost and populate the
 * cache. Reading the stream to do that would consume it. `tee()` splits it:
 * one branch goes straight to the client, the other is drained in the
 * background via `waitUntil` after the response has already been returned. The
 * client's branch is never waited on by the observer, so a slow reader cannot
 * stall the cache write and a failed cache write cannot break the stream.
 */
export function forwardStream(
  upstream: Response,
  observe: (fullBody: string) => void | Promise<void>,
  waitUntil: (promise: Promise<unknown>) => void,
): Response {
  if (!upstream.body) {
    return new Response(null, { status: upstream.status, headers: sseHeaders(upstream) });
  }

  const [toClient, toObserver] = upstream.body.tee();

  waitUntil(
    (async () => {
      try {
        const text = await new Response(toObserver).text();
        await observe(text);
      } catch {
        // A failed observation must never affect the client. The stream has
        // already been delivered by this point; losing a cache entry or a
        // usage row is the correct thing to trade away.
      }
    })(),
  );

  return new Response(toClient, {
    status: upstream.status,
    headers: sseHeaders(upstream),
  });
}

function sseHeaders(upstream: Response): Headers {
  const headers = new Headers();
  headers.set("content-type", upstream.headers.get("content-type") ?? "text/event-stream");
  headers.set("cache-control", "no-store");
  // Proxies that buffer would defeat the whole design.
  headers.set("x-accel-buffering", "no");
  return headers;
}

/**
 * Pulls the assembled text and token usage out of a completed SSE body.
 *
 * Parsed after the fact rather than during forwarding, so the parser can never
 * be in the path of the bytes the app sees. A malformed stream yields whatever
 * was assembled plus zero usage, which the caller treats as "don't cache".
 */
export function parseCompletedStream(body: string): { text: string; inputTokens: number; outputTokens: number; complete: boolean } {
  let text = "";
  let inputTokens = 0;
  let outputTokens = 0;
  let complete = false;

  for (const rawLine of body.split("\n")) {
    const line = rawLine.trim();
    if (!line.startsWith("data:")) continue;
    const payload = line.slice(5).trim();
    if (!payload || payload === "[DONE]") continue;

    try {
      const event = JSON.parse(payload) as Record<string, any>;
      switch (event.type) {
        case "content_block_delta":
          if (typeof event.delta?.text === "string") text += event.delta.text;
          break;
        case "message_start":
          inputTokens += Number(event.message?.usage?.input_tokens ?? 0);
          outputTokens += Number(event.message?.usage?.output_tokens ?? 0);
          break;
        case "message_delta":
          outputTokens += Number(event.usage?.output_tokens ?? 0);
          break;
        case "message_stop":
          complete = true;
          break;
        default:
          break;
      }
    } catch {
      // Skip the malformed event; the surrounding stream may still be usable.
    }
  }

  return { text, inputTokens, outputTokens, complete };
}

/**
 * Words of prose in a completed structured-output stream.
 *
 * Both cacheable schemas — `Schemas.lesson` and `Schemas.chapter` — carry the
 * prose in `bodyMarkdown`, and the assembled stream text is that whole JSON
 * object. Counting words on the raw text instead would count the title, the
 * subtitle, the three deeper angles and every JSON delimiter, which reads about
 * forty words heavy on a 3-minute lesson and would let a short one through.
 *
 * Null when the text will not parse or carries no body: unreadable, not empty.
 * The caller must not treat that as zero — see `hardWordFloor`.
 */
export function bodyWordCount(streamText: string): number | null {
  try {
    const parsed = JSON.parse(streamText) as { bodyMarkdown?: unknown };
    if (typeof parsed.bodyMarkdown !== "string") return null;
    return countWords(parsed.bodyMarkdown);
  } catch {
    return null;
  }
}

/** Mirrors `StringProtocol.lessonWordCount`: whitespace-separated, nothing else. */
export function countWords(text: string): number {
  const trimmed = text.trim();
  if (trimmed.length === 0) return 0;
  return trimmed.split(/\s+/).length;
}

/**
 * Cost estimate, mirroring `CostEstimator.pricing` in SpareCore so the server's
 * ceiling and the app's usage ledger agree about what a call cost.
 *
 * Per-model since the batch tool started comparing models: charging Haiku's
 * tokens at Opus's rates overstates the ledger fivefold, and the ledger is what
 * the monthly ceiling reads.
 */
export const MODEL_PRICES: Record<string, { input: number; output: number }> = {
  "claude-opus-5": { input: 5, output: 25 },
  // Sonnet's list price. It is on an introductory $2/$10 until 2026-08-31,
  // and this deliberately does not track that: the number feeds the monthly
  // spend ceiling, so being wrong high stops generation slightly early and
  // being wrong low lets the ceiling be sailed past. The free pool runs
  // entirely on this model, which makes the direction of the error matter
  // more than its size.
  "claude-sonnet-5": { input: 3, output: 15 },
};

/** The generation model's prices, and the fallback for anything unlisted. */
export const PRICE_PER_MTOK_INPUT = MODEL_PRICES["claude-opus-5"].input;
export const PRICE_PER_MTOK_OUTPUT = MODEL_PRICES["claude-opus-5"].output;

export function estimateCostUSD(
  inputTokens: number,
  outputTokens: number,
  model?: string,
): number {
  // Unlisted models fall back to the most expensive entry, so an unknown model
  // can never make the ceiling read low.
  const prices = (model !== undefined ? MODEL_PRICES[model] : undefined)
    ?? { input: PRICE_PER_MTOK_INPUT, output: PRICE_PER_MTOK_OUTPUT };
  return (inputTokens / 1_000_000) * prices.input
    + (outputTokens / 1_000_000) * prices.output;
}
