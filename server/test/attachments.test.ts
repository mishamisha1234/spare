import { describe, expect, it } from "vitest";
import {
  anthropicStreaming,
  appleProduction,
  fixtureFetch,
  lessonBody,
  sseLesson,
  subscriptionStatus,
} from "./fixtures";
import { NOW, call, modelRequest, premiumReceipt } from "./harness";

/**
 * Tests and recall questions travel with the lesson, not with the reader.
 *
 * The number this exists to avoid: a 30-minute course read by two hundred
 * premium users, at roughly $0.20 of test generation each, is $40 of tests on
 * a lesson that cost $1.40 to write. So a test is generated once, by the
 * device that generated the lesson, and stored beside it — and these endpoints
 * are the only way bytes a client chose reach a pool other readers are served
 * from, which is why both guards below matter.
 */

function premiumRoutes(sse: string) {
  return [
    appleProduction(subscriptionStatus({
      productId: "app.spare.premium.yearly",
      status: 1,
      expiresDate: NOW + 30 * 86_400_000,
    })),
    anthropicStreaming(sse),
  ];
}

function question(index: number) {
  return {
    question: `Question ${index}?`,
    answer: `Answer ${index}`,
    distractors: [`Wrong ${index}a`, `Wrong ${index}b`, `Wrong ${index}c`],
    explanation: `Because of reason ${index}.`,
  };
}

function test(count: number) {
  return Array.from({ length: count }, (_, index) => question(index));
}

/** The lesson these attachments belong to. Premium unless said otherwise. */
function lesson(overrides: Record<string, unknown> = {}) {
  return {
    window: "seven",
    format: "explainer",
    topic: "How standard time was imposed",
    interest: "History",
    receipt: premiumReceipt,
    ...overrides,
  };
}

/** Words that clear each length's floor, so the lesson actually caches. */
const IN_BUDGET: Record<string, number> = {
  one: 220, three: 560, seven: 1_250, fifteen: 2_700, thirty: 6_200,
};

/**
 * Generates the lesson, so the device becomes its recorded generator.
 *
 * Every caller passes its own topic. Storage is isolated per test *file*, not
 * per test, so two tests sharing a topic share a cache entry — and the second
 * one is then served from cache, never generates, and never becomes the
 * generator. That failure looks like a 403 from `/v1/attach` and has nothing
 * to do with what the test was checking.
 */
async function generate(device: string, topic: string, body: Record<string, unknown> = {}) {
  const merged = lesson({ topic, ...body });
  const window = String(merged.window);
  const fetcher = fixtureFetch(premiumRoutes(sseLesson(lessonBody(IN_BUDGET[window]))));
  const response = await call({
    fetcher,
    device,
    body: { ...merged, pass: "final", request: modelRequest({ max_tokens: 24_000 }) },
  });
  expect(response.status, "the lesson itself failed to generate").toBe(200);
  return merged;
}

describe("attachments", () => {
  it("stores a test from the generating device and serves it back to another reader", async () => {
    const device = "attach-writer";
    const body = await generate(device, "Attaching and reading back");

    const stored = await call({
      fetcher: fixtureFetch(premiumRoutes(sseLesson(lessonBody(1_250)))),
      device,
      path: "/v1/attach",
      body: { ...body, attachments: { recall: question(99), test: test(4) } },
    });
    expect(stored.status).toBe(200);

    // A different premium reader, and nothing generated for them.
    const read = await call({
      fetcher: fixtureFetch(premiumRoutes(sseLesson(lessonBody(1_250)))),
      device: "attach-reader",
      path: "/v1/attachments",
      body,
    });
    expect(read.status).toBe(200);
    const payload = (await read.json()) as { recall: any; test: any[] };
    expect(payload.test).toHaveLength(4);
    expect(payload.recall.question).toBe("Question 99?");
  });

  it("refuses an attachment from a device that did not generate the lesson", async () => {
    // Not a strong claim — device ids are spoofable — but it turns "anyone may
    // overwrite any entry in the pool" into "you must first pay to generate
    // the lesson you want to attach to".
    const body = await generate("attach-owner", "Only the generator may attach");

    const response = await call({
      fetcher: fixtureFetch(premiumRoutes(sseLesson(lessonBody(1_250)))),
      device: "attach-impostor",
      path: "/v1/attach",
      body: { ...body, attachments: { recall: question(1), test: test(4) } },
    });

    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ error: { code: "notTheGenerator" } });
  });

  it("refuses a test whose question count is wrong for the length", async () => {
    // A 30-minute course carries ten questions. Three would be a premium
    // feature quietly failing to be what it was sold as, for everyone who
    // reads that lesson for the next thirty days.
    const device = "attach-short-test";
    const body = await generate(device, "A course with a short test", {
      window: "thirty", format: "miniCourse",
    });

    const response = await call({
      fetcher: fixtureFetch(premiumRoutes(sseLesson(lessonBody(1_250)))),
      device,
      path: "/v1/attach",
      body: { ...body, attachments: { recall: question(1), test: test(3) } },
    });

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: { code: "wrongQuestionCount" } });
  });

  it("accepts the exact count for each length", async () => {
    for (const [window, format, count] of [
      ["one", "oneThing", 2],
      ["three", "oneThing", 3],
      ["seven", "explainer", 4],
      ["fifteen", "lesson", 5],
      ["thirty", "miniCourse", 10],
    ] as Array<[string, string, number]>) {
      const device = `attach-count-${window}`;
      const body = await generate(device, `Counting ${window}`, { window, format });
      const response = await call({
        fetcher: fixtureFetch(premiumRoutes(sseLesson(lessonBody(1_250)))),
        device,
        path: "/v1/attach",
        body: { ...body, attachments: { recall: question(1), test: test(count) } },
      });
      expect(response.status, `${window} rejected ${count} questions`).toBe(200);
    }
  });

  it("refuses a malformed question rather than storing it", async () => {
    const device = "attach-malformed";
    const body = await generate(device, "A malformed question");

    const response = await call({
      fetcher: fixtureFetch(premiumRoutes(sseLesson(lessonBody(1_250)))),
      device,
      path: "/v1/attach",
      body: {
        ...body,
        attachments: {
          recall: question(1),
          // Two distractors, not three: three is what makes four options, and
          // a question with three options is a different question.
          test: [{ ...question(2), distractors: ["a", "b"] }, question(3), question(4), question(5)],
        },
      },
    });

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: { code: "malformedAttachment" } });
  });

  it("keeps the pools apart", async () => {
    // A free reader asking about the same subject is asking about a different
    // entry, in a pool that has no test in it at all.
    const device = "attach-pool-writer";
    const body = await generate(device, "Pools stay apart");
    await call({
      fetcher: fixtureFetch(premiumRoutes(sseLesson(lessonBody(1_250)))),
      device,
      path: "/v1/attach",
      body: { ...body, attachments: { recall: question(7), test: test(4) } },
    });

    const free = await call({
      fetcher: fixtureFetch([anthropicStreaming(sseLesson(lessonBody(1_250)))]),
      device: "attach-free-reader",
      path: "/v1/attachments",
      body: { ...body, receipt: undefined },
    });
    expect(free.status, "a free reader reached the premium pool's attachments").toBe(404);
  });

  it("answers 404 rather than generating when nothing is attached yet", async () => {
    // The whole cost argument depends on this never falling back to
    // generation. A reader who arrives before the attachment does gets
    // nothing, and asks again later.
    const response = await call({
      fetcher: fixtureFetch(premiumRoutes(sseLesson(lessonBody(1_250)))),
      device: "attach-nothing-yet",
      path: "/v1/attachments",
      body: lesson({ topic: "Never generated" }),
    });

    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: { code: "noAttachments" } });
  });

  it("does not spend the daily allowance", async () => {
    // Reading an attachment is not reading a lesson. A free reader who checks
    // for a recall question must not lose their lesson for the day over it.
    const device = "attach-free-allowance";
    const body = lesson({ receipt: undefined, topic: "Allowance untouched" });

    await call({
      fetcher: fixtureFetch([anthropicStreaming(sseLesson(lessonBody(1_250)))]),
      device,
      path: "/v1/attachments",
      body,
    });

    const generated = await call({
      fetcher: fixtureFetch([anthropicStreaming(sseLesson(lessonBody(1_250)))]),
      device,
      body: { ...body, pass: "final", request: modelRequest() },
    });
    expect(generated.status, "checking for attachments cost the day's lesson").toBe(200);
  });
});
