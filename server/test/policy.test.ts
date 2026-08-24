/**
 * The proxy pays for whatever it forwards, and the request arriving here was
 * built by a client we do not control. These are the tests for the fields that
 * decide what a call costs.
 */

import { describe, expect, it } from "vitest";
import {
  anthropicStreaming,
  appleProduction,
  fixtureFetch,
  jsonMessage,
  sseLesson,
  subscriptionStatus,
} from "./fixtures";
import { NOW, call, modelRequest, premiumReceipt, recordingAnthropic } from "./harness";

/**
 * A live premium subscription.
 *
 * The outline endpoint only ever carries a 30-minute course, which is a premium
 * length — a free device is refused at the tier check before the policy layer
 * is reached, so a policy test about the outline has to be a premium one.
 */
function premiumRoute() {
  return appleProduction(
    subscriptionStatus({
      productId: "app.spare.premium.yearly",
      status: 1,
      expiresDate: NOW + 30 * 86_400_000,
    }),
  );
}

/** An SSE response, for endpoints whose upstream call streams. */
const streamed = () =>
  new Response(sseLesson("Body."), { headers: { "content-type": "text/event-stream" } });

/** A plain JSON response, for the small endpoints. */
const plain = () =>
  new Response(jsonMessage({ prompt: "q" }), { headers: { "content-type": "application/json" } });

function lessonBody(topic: string, request: Record<string, unknown>) {
  return { window: "three", format: "oneThing", topic, request };
}

describe("streaming mode is decided by the endpoint", () => {
  // The client does not get a say, so the client's routing has to agree with
  // this table. `ProxyRoute.streamingPaths` in SpareCore is the other half.
  it("forces streaming on the endpoints whose response is forwarded", async () => {
    // A device each: one lesson a day is the free tier, and the second
    // iteration would otherwise be refused before it reached the policy.
    for (const path of ["/v1/lesson", "/v1/chapter"]) {
      const { route, bodies } = recordingAnthropic(streamed);
      await call({
        fetcher: fixtureFetch([route]),
        path,
        device: `device-streamed-${path.replace(/\W+/g, "-")}`,
        body: lessonBody(`streamed ${path}`, modelRequest({ stream: false })),
      });
      expect(bodies[0].stream, `${path} should stream`).toBe(true);
    }
  });

  it("forces the outline not to stream, whatever the client asked for", async () => {
    // The bug this endpoint exists to fix: the course outline is a small
    // structured JSON call, it was routed to /v1/lesson because an outline is
    // part of starting a lesson, and the policy turned it into a streaming
    // request. Every 30-minute course through the proxy failed on its first
    // call. Neither side's tests could see it — the client's fixtures answer
    // whatever they are asked, and these tests build their own bodies.
    const { route, bodies } = recordingAnthropic(plain);
    const response = await call({
      fetcher: fixtureFetch([premiumRoute(), route]),
      path: "/v1/outline",
      device: "device-outline-mode",
      body: {
        window: "thirty",
        format: "miniCourse",
        topic: "outline mode",
        receipt: premiumReceipt,
        request: modelRequest({ stream: true, max_tokens: 4_000 }),
      },
    });

    expect(response.status).toBe(200);
    expect(bodies[0].stream).toBe(false);
    expect(response.headers.get("content-type")).toContain("application/json");
  });

  it("caps the outline well below a lesson, because it is a plan not prose", async () => {
    const { route, bodies } = recordingAnthropic(plain);
    await call({
      fetcher: fixtureFetch([premiumRoute(), route]),
      path: "/v1/outline",
      device: "device-outline-ceiling",
      body: {
        window: "thirty",
        format: "miniCourse",
        topic: "outline ceiling",
        receipt: premiumReceipt,
        request: modelRequest({ max_tokens: 24_000 }),
      },
    });

    expect(bodies[0].max_tokens).toBe(4_000);
  });
});

/** Any non-empty string; the harness configures the env to match. */
const OPERATOR_TOKEN = "operator-token-fixture";

describe("the client cannot choose what it costs", () => {
  it("ignores the model a reader's client names, whatever it is", async () => {
    // This used to be a 400. It is a substitution now, and the change is
    // deliberate: the model is decided by the pool, which is decided by the
    // entitlement the server verified with Apple, so there is nothing for a
    // client's value to be right or wrong about. A refusal would also name the
    // boundary for anyone probing it, and break every reader on a stale build
    // the day the pool models change.
    //
    // What has to stay true is the part this test was really protecting:
    // nothing the client names can decide what the request costs.
    const { route, bodies } = recordingAnthropic(streamed);
    const response = await call({
      fetcher: fixtureFetch([route]),
      body: lessonBody("Cheap model swap", modelRequest({ model: "some-other-model" })),
    });

    expect(response.status).toBe(200);
    expect(bodies[0].model).toBe("claude-sonnet-5");
  });

  it("still refuses an unknown model on the operator path", async () => {
    // The batch tool names its own model, because comparing models is why it
    // exists — so it is the one caller whose value is used, and therefore the
    // one caller the allowlist still has to answer.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Should not happen."))]);
    const response = await call({
      fetcher,
      admin: OPERATOR_TOKEN,
      body: lessonBody("Operator model swap", modelRequest({ model: "some-other-model" })),
    });

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: { code: "modelNotAllowed" } });
    // The load-bearing half: nothing went upstream, so nothing was billed.
    expect((fetcher as any).calls).toHaveLength(0);
  });

  it("no longer pays for Haiku at all", async () => {
    // Not a cost decision. A blind comparison across three durations and six
    // topics found confident fabrications in all three of its lessons,
    // including an invented act of Congress. Left on the allowlist "for the
    // batch tool", it quietly reappears in the next comparison run.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Should not happen."))]);
    const response = await call({
      fetcher,
      admin: OPERATOR_TOKEN,
      body: lessonBody("Haiku", modelRequest({ model: "claude-haiku-4-5-20251001" })),
    });

    expect(response.status).toBe(400);
    expect((fetcher as any).calls).toHaveLength(0);
  });

  it("clamps an inflated max_tokens to the endpoint ceiling", async () => {
    const { route, bodies } = recordingAnthropic(streamed);
    const response = await call({
      fetcher: fixtureFetch([route]),
      body: lessonBody("Expensive request", modelRequest({ max_tokens: 200_000 })),
    });

    expect(response.status).toBe(200);
    expect(bodies[0].max_tokens).toBe(24_000);
  });

  it("holds a small endpoint to its own much lower ceiling", async () => {
    // /v1/recall asking for a lesson-sized budget is either stale or hostile.
    const { route, bodies } = recordingAnthropic(plain);
    await call({
      fetcher: fixtureFetch([route]),
      path: "/v1/recall",
      body: { request: modelRequest({ max_tokens: 24_000 }) },
    });

    expect(bodies[0].max_tokens).toBe(2_000);
  });

  it("leaves an honest max_tokens alone", async () => {
    const { route, bodies } = recordingAnthropic(streamed);
    await call({
      fetcher: fixtureFetch([route]),
      body: lessonBody("Ordinary request", modelRequest({ max_tokens: 8_000 })),
    });

    expect(bodies[0].max_tokens).toBe(8_000);
  });

  it("drops fields it does not recognise instead of forwarding them", async () => {
    // Rebuilt from an allowlist rather than filtered, so a parameter the proxy
    // has never heard of cannot reach Anthropic even if one is added upstream
    // tomorrow. Filtering would grow a hole on every API release.
    const { route, bodies } = recordingAnthropic(streamed);
    await call({
      fetcher: fixtureFetch([route]),
      body: lessonBody(
        "Smuggled fields",
        modelRequest({
          metadata: { user_id: "someone-elses-account" },
          service_tier: "priority",
          top_k: 500,
        }),
      ),
    });

    expect(Object.keys(bodies[0]).sort()).toEqual(["max_tokens", "messages", "model", "stream"]);
  });

  it("passes the prompt through untouched", async () => {
    // The prompts are the product and live in Prompts.swift. This layer
    // constrains cost, not content: if it started editing prompts, the app's
    // quality checks would be judging text the model never received.
    const { route, bodies } = recordingAnthropic(streamed);
    const system = [
      { type: "text", text: "You are an editor.", cache_control: { type: "ephemeral" } },
    ];
    const outputConfig = {
      effort: "high",
      format: { type: "json_schema", schema: { type: "object" } },
    };

    await call({
      fetcher: fixtureFetch([route]),
      body: lessonBody("Prompt fidelity", modelRequest({ system, output_config: outputConfig })),
    });

    expect(bodies[0].system).toEqual(system);
    expect(bodies[0].output_config).toEqual(outputConfig);
    expect(bodies[0].messages[0].content[0].text).toBe("Write a lesson.");
  });

  it("forces streaming on for streamed endpoints and off for the rest", async () => {
    // Otherwise a client-supplied flag decides whether the response can be
    // handled at all: a non-streaming body on /v1/lesson breaks forwardStream,
    // and a streamed one on /v1/recall gets read as text and fails to parse.
    const lesson = recordingAnthropic(streamed);
    await call({
      fetcher: fixtureFetch([lesson.route]),
      body: lessonBody("Stream forced on", modelRequest({ stream: false })),
    });

    const recall = recordingAnthropic(plain);
    await call({
      fetcher: fixtureFetch([recall.route]),
      path: "/v1/recall",
      body: { request: modelRequest({ stream: true }) },
    });

    expect(lesson.bodies[0].stream).toBe(true);
    expect(recall.bodies[0].stream).toBe(false);
  });

  it("refuses a request whose only purpose is to be large", async () => {
    // Input is billed too: a megabyte of it costs money before a single token
    // comes back.
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Should not happen."))]);
    const response = await call({
      fetcher,
      body: lessonBody(
        "Padding",
        modelRequest({
          messages: [{ role: "user", content: [{ type: "text", text: "x".repeat(300 * 1024) }] }],
        }),
      ),
    });

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: { code: "requestTooLarge" } });
    expect((fetcher as any).calls).toHaveLength(0);
  });

  it("allows a revision pass, which legitimately carries a whole draft", async () => {
    // The size limit has to sit above the largest honest request or it becomes
    // a bug that only shows up on long lessons.
    const { route, bodies } = recordingAnthropic(streamed);
    const draft = "word ".repeat(4_000); // ~20 KB, a fifteen-minute draft
    const response = await call({
      fetcher: fixtureFetch([route]),
      body: lessonBody(
        "Revision pass",
        modelRequest({
          messages: [{ role: "user", content: [{ type: "text", text: draft }] }],
        }),
      ),
    });

    expect(response.status).toBe(200);
    expect(bodies).toHaveLength(1);
  });

  it("refuses a request with no messages", async () => {
    const fetcher = fixtureFetch([anthropicStreaming(sseLesson("Should not happen."))]);
    const response = await call({
      fetcher,
      body: lessonBody("Empty", modelRequest({ messages: [] })),
    });

    expect(response.status).toBe(400);
    expect((fetcher as any).calls).toHaveLength(0);
  });

  it("refuses a bad request before spending the day's free lesson", async () => {
    // Order matters. A refusal that still consumed the allowance would let one
    // malformed request cost a free user their only lesson for the day.
    const device = "policy-then-meter";
    const rejected = await call({
      fetcher: fixtureFetch([]),
      device,
      // Malformed rather than mis-modelled: a client's model is substituted
      // now, not refused, so it no longer produces the 400 this test needs.
      body: { window: "three", format: "oneThing", topic: "Rejected first", request: { messages: [] } },
    });
    expect(rejected.status).toBe(400);

    const allowed = await call({
      fetcher: fixtureFetch([anthropicStreaming(sseLesson("Still allowed."))]),
      device,
      body: lessonBody("Rejected first", modelRequest()),
    });
    expect(allowed.status).toBe(200);
  });
});
