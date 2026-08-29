/**
 * Shared test harness.
 *
 * Runs the real Worker in workerd with real Durable Objects — the consistency
 * guarantee the tier limits depend on is the thing under test, so mocking the
 * storage would test the mock.
 */

import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { expect } from "vitest";
import worker, { type Env, type Hooks } from "../src/index";
import { fakeJWS, TEST_P8 } from "./fixtures";

/**
 * A slug unique to the running test, used to scope the default device and the
 * default topic.
 *
 * Storage is isolated per test file, not per test, so without this every test
 * in a file shares one free-tier counter and one lesson cache — and they feed
 * each other. That produced eleven failures whose stated reasons were all
 * wrong: a streaming test compared against a cached replay left by an earlier
 * test, a policy test found no upstream call because the day's free lesson had
 * been spent three tests ago, and "allows the first lesson and refuses the
 * second" allowed both because its first request was a cache hit and cache hits
 * are deliberately not metered.
 *
 * Scoping the defaults means each test starts from a fresh allowance and an
 * empty cache without depending on the runner's isolation granularity. Tests
 * that are *about* sharing — the cache ones — pass explicit devices and topics
 * and so opt back in.
 */
function testScope(): string {
  const name = expect.getState().currentTestName ?? "unnamed-test";
  return name.replace(/[^a-z0-9]+/gi, "-").toLowerCase().slice(0, 96);
}

/** Fixed clock, so day and month rollover are decided by the test, not the calendar. */
export const NOW = Date.UTC(2026, 7, 17, 12, 0, 0);

export function testEnv(overrides: Partial<Env> = {}): Env {
  return {
    ...(env as unknown as Env),
    ANTHROPIC_API_KEY: "sk-ant-fixture-key",
    APPSTORE_PRIVATE_KEY: TEST_P8,
    APPSTORE_KEY_ID: "TESTKEYID",
    APPSTORE_ISSUER_ID: "issuer-uuid",
    BUNDLE_ID: "app.spare.ios",
    MONTHLY_SPEND_CEILING_USD: "50",
    // Both are set in `wrangler.toml` for the pre-release window, and both
    // would otherwise reach every test through the real bindings. Overridden
    // here to the shipped configuration -- trial on, client gate off -- so the
    // suite describes the app as it will run, and the two tests that are
    // *about* the window set their own values.
    TRIAL_START_ENABLED: "true",
    SPARE_CLIENT_TOKEN: undefined,
    ...overrides,
  };
}

/**
 * A model request the policy layer accepts.
 *
 * The app builds these; the proxy rebuilds them from an allowlist. Tests that
 * probe the policy pass their own deliberately-wrong version instead.
 */
export function modelRequest(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    model: "claude-opus-5",
    max_tokens: 8_000,
    messages: [{ role: "user", content: [{ type: "text", text: "Write a lesson." }] }],
    ...overrides,
  };
}

export interface CallOptions {
  path?: string;
  device?: string;
  body?: Record<string, unknown>;
  fetcher: typeof fetch;
  env?: Env;
  now?: number;
  /** Presents the operator token, and configures the env to accept it. The
   * batch tool's path: it skips the per-device limits and the cache, and it
   * is the one caller allowed to choose its own model. */
  admin?: string;
}

/**
 * Invokes the Worker and hands back the live response plus its context.
 *
 * For tests that need the response as a stream. The caller must drain the body
 * and then `await waitOnExecutionContext(ctx)`, in that order — see `call`.
 */
export async function callRaw(
  options: CallOptions,
): Promise<{ response: Response; ctx: ExecutionContext }> {
  const ctx = createExecutionContext();
  const scope = testScope();
  const hooks: Hooks = { fetcher: options.fetcher, now: () => options.now ?? NOW };
  const request = new Request(`https://proxy.spare.app${options.path ?? "/v1/lesson"}`, {
    method: "POST",
    headers: {
      // `device-` prefixed so the length always clears the 8-character floor
      // the router enforces, however short a test's name is.
      "x-spare-device": options.device ?? `device-${scope}`,
      "content-type": "application/json",
      ...(options.admin ? { "x-spare-admin": options.admin } : {}),
    },
    body: JSON.stringify(
      options.body ?? {
        window: "three",
        format: "oneThing",
        topic: `Why bridges hum ${scope}`,
        request: modelRequest(),
      },
    ),
  });
  const environment = options.env
    ?? (options.admin ? testEnv({ ADMIN_TOKEN: options.admin }) : testEnv());
  const response = await worker.fetch(request, environment, ctx, hooks);
  return { response, ctx };
}

/**
 * Invokes the Worker and returns a fully buffered response.
 *
 * The draining is not a convenience. On the streaming path the server tee()s
 * the upstream body and does its cost accounting and cache write on the second
 * branch, scheduled with `waitUntil`. A test that asserts only on the status
 * and walks away leaves the body unread, so that background work never
 * finishes — and it writes to a Durable Object, which the runner's per-test
 * storage isolation then fails to tear down. The failure surfaces as an opaque
 * "expected .sqlite, got .sqlite-shm" from the pool rather than as anything
 * pointing at the test that caused it.
 *
 * Order matters: drain first, then wait. Waiting on a context whose observer
 * branch is still blocked on an unread body waits for something that cannot
 * happen yet.
 */
export async function call(options: CallOptions): Promise<Response> {
  const { response, ctx } = await callRaw(options);
  const body = await response.arrayBuffer();
  await waitOnExecutionContext(ctx);
  // `null` rather than an empty buffer for a 204: workerd warns on every
  // re-wrap of a null-body status otherwise, and the endpoints that answer 204
  // are the ones called most often in a run.
  return new Response(body.byteLength === 0 ? null : body, {
    status: response.status,
    headers: response.headers,
  });
}

export const premiumReceipt = fakeJWS({ originalTransactionId: "2000000000000001" });

/**
 * Records the body of every upstream Anthropic call, so a test can assert on
 * what the proxy actually sent rather than on what the client asked for.
 */
export function recordingAnthropic(respondWith: () => Response) {
  const bodies: Array<Record<string, any>> = [];
  const route = {
    match: (url: string) => url.includes("api.anthropic.com"),
    respond: (_url: string, init?: RequestInit) => {
      bodies.push(JSON.parse(String(init?.body)));
      return respondWith();
    },
  };
  return { route, bodies };
}
