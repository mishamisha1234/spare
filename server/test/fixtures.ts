/**
 * Recorded upstream responses. No test makes a network call: every `fetch` in
 * these tests is one of these handlers.
 */

export const ANTHROPIC_MESSAGES = "https://api.anthropic.com/v1/messages";
export const APPLE_PRODUCTION = "https://api.storekit.itunes.apple.com";
export const APPLE_SANDBOX = "https://api.storekit-sandbox.itunes.apple.com";

/**
 * Prose of a given length, for tests that care how long a lesson is.
 *
 * Real words rather than one repeated token: the word count is a whitespace
 * split, so "a".repeat(n) is one word however long it is, and a fixture that
 * looks long while counting as one is exactly the confusion this avoids.
 */
export function lessonBody(words: number): string {
  const vocabulary = [
    "the", "bridge", "swayed", "because", "soldiers", "marched", "in", "step",
    "and", "resonance", "did", "the", "rest", "on", "a", "cold", "morning",
  ];
  return Array.from({ length: words }, (_, index) => vocabulary[index % vocabulary.length])
    .join(" ");
}

/**
 * An SSE body shaped like a real streaming completion.
 *
 * `text` becomes the lesson's `bodyMarkdown`, and what streams is the whole
 * structured-output object — which is what the real endpoint returns and what
 * the server now has to read to decide whether a lesson is long enough to
 * cache. The fixture used to stream the bare prose, which no client could have
 * decoded; nothing depended on the difference until the cache started counting
 * words.
 */
export function sseLesson(text: string, options: { complete?: boolean; inputTokens?: number; outputTokens?: number } = {}): string {
  const { complete = true, inputTokens = 1200, outputTokens = 800 } = options;
  const payload = JSON.stringify({
    title: "A lesson",
    subtitle: "What it is about",
    domainTag: "History",
    bodyMarkdown: text,
    surprisingClaim: "Something checkable and counterintuitive.",
    deeperAngles: ["One", "Two", "Three"],
  });
  const lines: string[] = [];
  lines.push(
    `event: message_start\ndata: ${JSON.stringify({
      type: "message_start",
      message: { usage: { input_tokens: inputTokens, output_tokens: 0 } },
    })}\n`,
  );
  // Several deltas, so a test can tell whether chunk boundaries survived.
  for (const chunk of payload.match(/.{1,20}/gs) ?? []) {
    lines.push(
      `event: content_block_delta\ndata: ${JSON.stringify({
        type: "content_block_delta",
        delta: { type: "text_delta", text: chunk },
      })}\n`,
    );
  }
  lines.push(
    `event: message_delta\ndata: ${JSON.stringify({
      type: "message_delta",
      usage: { output_tokens: outputTokens },
    })}\n`,
  );
  if (complete) {
    lines.push(`event: message_stop\ndata: ${JSON.stringify({ type: "message_stop" })}\n`);
  }
  return lines.join("\n");
}

export function jsonMessage(body: unknown, usage = { input_tokens: 400, output_tokens: 200 }): string {
  return JSON.stringify({
    id: "msg_fixture",
    type: "message",
    role: "assistant",
    content: [{ type: "text", text: JSON.stringify(body) }],
    usage,
  });
}

/**
 * An unsigned JWS-shaped string.
 *
 * Deliberately not signed: the server decodes the payload without verifying it
 * and then asks Apple, so a test fixture does not need a valid signature. If
 * that ever stops being true these tests will start failing, which is the
 * correct alarm.
 */
export function fakeJWS(payload: Record<string, unknown>): string {
  const encode = (value: unknown) =>
    btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `${encode({ alg: "ES256", x5c: ["fixture"] })}.${encode(payload)}.signature`;
}

export function subscriptionStatus(options: {
  productId: string;
  status: number;
  expiresDate: number | null;
}): string {
  return JSON.stringify({
    data: [
      {
        lastTransactions: [
          {
            status: options.status,
            signedTransactionInfo: fakeJWS({
              productId: options.productId,
              expiresDate: options.expiresDate ?? undefined,
            }),
          },
        ],
      },
    ],
  });
}

/** A P-256 key in PKCS#8 PEM, generated for tests only. Signs nothing real. */
export const TEST_P8 = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----`;

export interface FixtureRoute {
  match: (url: string, init?: RequestInit) => boolean;
  respond: (url: string, init?: RequestInit) => Response;
}

/**
 * Builds a `fetch` that only answers recorded routes and throws on anything
 * else — so a test that accidentally reaches the real internet fails loudly
 * rather than silently passing.
 */
export function fixtureFetch(routes: FixtureRoute[]): typeof fetch {
  const calls: string[] = [];
  const fetcher = (async (input: any, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.url;
    calls.push(url);
    const route = routes.find((candidate) => candidate.match(url, init));
    if (!route) throw new Error(`unrecorded request: ${url}`);
    return route.respond(url, init);
  }) as unknown as typeof fetch & { calls: string[] };
  (fetcher as any).calls = calls;
  return fetcher;
}

export function anthropicStreaming(sse: string, status = 200): FixtureRoute {
  return {
    match: (url) => url.startsWith(ANTHROPIC_MESSAGES),
    respond: () =>
      new Response(sse, {
        status,
        headers: { "content-type": "text/event-stream" },
      }),
  };
}

export function anthropicJSON(body: string, status = 200): FixtureRoute {
  return {
    match: (url) => url.startsWith(ANTHROPIC_MESSAGES),
    respond: () => new Response(body, { status, headers: { "content-type": "application/json" } }),
  };
}

export function appleProduction(body: string, status = 200): FixtureRoute {
  return {
    match: (url) => url.startsWith(APPLE_PRODUCTION),
    respond: () => new Response(body, { status, headers: { "content-type": "application/json" } }),
  };
}

export function appleSandbox(body: string, status = 200): FixtureRoute {
  return {
    match: (url) => url.startsWith(APPLE_SANDBOX),
    respond: () => new Response(body, { status, headers: { "content-type": "application/json" } }),
  };
}
