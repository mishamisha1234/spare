/**
 * The subscriber's month, and the mirror that reports it.
 *
 * The reason these matter more than an ordinary cap test: the remaining count
 * is printed on the paywall and in Settings. A cap nobody reaches can drift
 * from what is displayed and nobody notices. A cap with a number next to it
 * cannot — a reader told "6 left" and refused at 4 has been lied to by the
 * screen, which is why the count comes from here and not from a local
 * derivation.
 */

import { describe, expect, it } from "vitest";
import {
  anthropicStreaming,
  appleProduction,
  fixtureFetch,
  sseLesson,
  subscriptionStatus,
} from "./fixtures";
import { NOW, call, modelRequest, premiumReceipt } from "./harness";
import {
  PREMIUM_COURSES_PER_MONTH,
  PREMIUM_LESSONS_PER_MONTH,
  TRIAL_COURSES,
} from "../src/limits";

const DAY = 86_400_000;

function subscriberRoutes() {
  return [
    appleProduction(
      subscriptionStatus({
        productId: "app.spare.premium.yearly",
        status: 1,
        expiresDate: NOW + 400 * DAY,
      }),
    ),
    anthropicStreaming(sseLesson("A lesson.")),
  ];
}

function subscriberLesson(
  device: string,
  topic: string,
  options: { window?: string; now?: number } = {},
) {
  return call({
    device,
    now: options.now ?? NOW,
    fetcher: fixtureFetch(subscriberRoutes()),
    body: {
      window: options.window ?? "fifteen",
      format: options.window === "thirty" ? "miniCourse" : "lesson",
      topic,
      receipt: premiumReceipt,
      request: modelRequest(),
    },
  });
}

interface Allowance {
  trial: { status: string };
  premium: { lessonsRemaining: number; coursesRemaining: number } | null;
}

async function allowance(device: string, receipt?: string): Promise<Allowance> {
  const response = await call({
    path: "/v1/allowance",
    device,
    fetcher: fixtureFetch(subscriberRoutes()),
    body: receipt ? { receipt } : {},
  });
  return (await response.json()) as Allowance;
}

describe("the monthly lesson cap", () => {
  it("allows the last lesson of the month and refuses the next", async () => {
    const device = "device-lesson-cap";

    for (let index = 0; index < PREMIUM_LESSONS_PER_MONTH; index += 1) {
      const response = await subscriberLesson(device, `Lesson ${index}`);
      expect(response.status, `lesson ${index + 1}`).toBe(200);
    }

    const oneTooMany = await subscriberLesson(device, "One too many");
    expect(oneTooMany.status).toBe(402);
    expect(((await oneTooMany.json()) as any).error.code).toBe("lessonCapReached");
  });

  /**
   * A course is one of the 50 *and* one of the 8 — the same shape as a trial
   * course being one of the 10 and one of the 2. Counting it against only one
   * would make the two caps describable only in combination, which no sentence
   * on a paywall could do.
   */
  it("counts a course against both ceilings", async () => {
    const device = "device-course-counts-twice";
    await subscriberLesson(device, "A course", { window: "thirty" });

    const after = await allowance(device, premiumReceipt);
    expect(after.premium?.lessonsRemaining).toBe(PREMIUM_LESSONS_PER_MONTH - 1);
    expect(after.premium?.coursesRemaining).toBe(PREMIUM_COURSES_PER_MONTH - 1);
  });

  it("refuses the ninth course while lessons remain", async () => {
    const device = "device-course-first";
    for (let index = 0; index < PREMIUM_COURSES_PER_MONTH; index += 1) {
      const response = await subscriberLesson(device, `Course ${index}`, { window: "thirty" });
      expect(response.status, `course ${index + 1}`).toBe(200);
    }

    // The more specific refusal wins: "every course this month" explains
    // itself where "every lesson" would be wrong, since shorter lengths work.
    const extraCourse = await subscriberLesson(device, "Course too many", { window: "thirty" });
    expect(((await extraCourse.json()) as any).error.code).toBe("courseCapReached");

    const shorter = await subscriberLesson(device, "Still fine");
    expect(shorter.status).toBe(200);
  });

  it("rolls over with the calendar month", async () => {
    const device = "device-lesson-cap-rollover";
    for (let index = 0; index < PREMIUM_LESSONS_PER_MONTH; index += 1) {
      await subscriberLesson(device, `Lesson ${index}`);
    }
    expect((await subscriberLesson(device, "Blocked")).status).toBe(402);

    const nextMonth = Date.UTC(2026, 8, 2, 12, 0, 0);
    const response = await subscriberLesson(device, "New month", { now: nextMonth });
    expect(response.status).toBe(200);
  });

  it("counts a cached read", async () => {
    const device = "device-lesson-cap-cache";
    const topic = "A cached premium lesson for the cap";

    // Same topic twice from two devices: the second is a cache hit, and it
    // still costs a lesson. A reader cannot tell the two apart, so a cap that
    // counted only generations would be a cap nobody could describe.
    await subscriberLesson("device-lesson-cap-warm", topic);
    const hit = await subscriberLesson(device, topic);
    expect(hit.status).toBe(200);

    const after = await allowance(device, premiumReceipt);
    expect(after.premium?.lessonsRemaining).toBe(PREMIUM_LESSONS_PER_MONTH - 1);
  });
});

describe("a trialist is not a subscriber", () => {
  /**
   * A trialist's courses used to increment `coursesThisMonth`, so the two
   * courses they were *given* came out of the eight they get if they subscribe
   * that month — charging a new customer for a gift.
   */
  it("spends no monthly allowance during the free week", async () => {
    const device = "device-trial-not-monthly";
    await call({
      path: "/v1/trial/start",
      device,
      body: {},
      fetcher: fixtureFetch(subscriberRoutes()),
    });

    for (let index = 0; index < TRIAL_COURSES; index += 1) {
      const response = await call({
        device,
        fetcher: fixtureFetch(subscriberRoutes()),
        body: {
          window: "thirty",
          format: "miniCourse",
          topic: `Trial course ${index}`,
          request: modelRequest(),
        },
      });
      expect(response.status, `trial course ${index + 1}`).toBe(200);
    }

    // Subscribing now: the month is untouched.
    const after = await allowance(device, premiumReceipt);
    expect(after.premium?.lessonsRemaining).toBe(PREMIUM_LESSONS_PER_MONTH);
    expect(after.premium?.coursesRemaining).toBe(PREMIUM_COURSES_PER_MONTH);
  });
});

describe("the allowance mirror", () => {
  /**
   * Null, not zeros. A free device has no monthly premium allowance, and
   * `{"lessonsRemaining": 0}` reads as a cap they have exhausted rather than
   * one that does not apply to them.
   */
  it("reports no premium allowance for a device that is not paying", async () => {
    const body = await allowance("device-allowance-free");
    expect(body.premium).toBeNull();
    expect(body.trial.status).toBe("eligible");
  });

  it("reports the month's remaining figures for a subscriber", async () => {
    const device = "device-allowance-subscriber";
    await subscriberLesson(device, "One read");

    const body = await allowance(device, premiumReceipt);
    expect(body.premium).not.toBeNull();
    expect(body.premium?.lessonsRemaining).toBe(PREMIUM_LESSONS_PER_MONTH - 1);
    expect(body.premium?.coursesRemaining).toBe(PREMIUM_COURSES_PER_MONTH);
  });
});
