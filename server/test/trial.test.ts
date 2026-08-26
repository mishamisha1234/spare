/**
 * The reverse trial.
 *
 * Seven days of premium with no card and no account, bounded at ten lessons
 * of which at most two may be courses. The device is not the authority on any
 * of that — these tests exist to prove the server is.
 */

import { describe, expect, it } from "vitest";
import {
  anthropicStreaming,
  appleProduction,
  fixtureFetch,
  sseLesson,
  subscriptionStatus,
} from "./fixtures";
import { NOW, call, modelRequest, premiumReceipt, recordingAnthropic, testEnv } from "./harness";
import { TRIAL_DURATION_MS, TRIAL_LESSONS, type TrialView } from "../src/limits";

const DAY = 86_400_000;

function anthropic() {
  return anthropicStreaming(sseLesson("A lesson."));
}

async function startTrial(device: string, now = NOW): Promise<TrialView> {
  const response = await call({
    path: "/v1/trial/start",
    device,
    now,
    body: {},
    fetcher: fixtureFetch([anthropic()]),
  });
  const body = (await response.json()) as { started: boolean; trial: TrialView };
  return body.trial;
}

async function trialStatus(device: string, now = NOW): Promise<TrialView> {
  const response = await call({
    path: "/v1/trial/status",
    device,
    now,
    body: {},
    fetcher: fixtureFetch([anthropic()]),
  });
  return (await response.json()) as TrialView;
}

/** One lesson request, with a topic distinct enough to be its own charge. */
function lesson(
  device: string,
  topic: string,
  options: { window?: string; now?: number; fetcher?: typeof fetch } = {},
) {
  return call({
    device,
    now: options.now ?? NOW,
    fetcher: options.fetcher ?? fixtureFetch([anthropic()]),
    body: {
      window: options.window ?? "three",
      format: options.window === "thirty" ? "chaptered" : "oneThing",
      topic,
      request: modelRequest(),
    },
  });
}

describe("starting a trial", () => {
  it("grants seven days and ten lessons", async () => {
    const trial = await startTrial("device-trial-grant-shape");
    expect(trial.status).toBe("active");
    expect(trial.remainingLessons).toBe(10);
    expect(trial.remainingCourses).toBe(2);
    expect(trial.expiresAt).toBe(NOW + TRIAL_DURATION_MS);
  });

  /**
   * The whole of "once per device" rests on this. A start that extended, or
   * that reset the counters, would be a renewable free week for anyone who
   * tapped twice.
   */
  it("is idempotent and never extends", async () => {
    const device = "device-trial-idempotent";
    const first = await startTrial(device);
    const second = await startTrial(device, NOW + 2 * DAY);
    expect(second.expiresAt).toBe(first.expiresAt);
    expect(second.startedAt).toBe(first.startedAt);
  });

  it("refuses a second trial once the first has expired", async () => {
    const device = "device-trial-once";
    await startTrial(device);

    const after = NOW + 8 * DAY;
    const response = await call({
      path: "/v1/trial/start",
      device,
      now: after,
      body: {},
      fetcher: fixtureFetch([anthropic()]),
    });
    const body = (await response.json()) as {
      started: boolean;
      reason?: string;
      trial: TrialView;
    };

    expect(body.started).toBe(false);
    expect(body.reason).toBe("alreadyUsed");
    expect(body.trial.status).toBe("ended");
    expect(body.trial.remainingLessons).toBe(0);
  });

  /**
   * Consuming a subscriber's one trial would take something away from a
   * paying customer for no benefit to either side.
   */
  it("does not burn a subscriber's eligibility", async () => {
    const device = "device-trial-subscriber";
    const response = await call({
      path: "/v1/trial/start",
      device,
      now: NOW,
      body: { receipt: premiumReceipt },
      fetcher: fixtureFetch([
        appleProduction(
          subscriptionStatus({
            productId: "app.spare.premium.yearly",
            status: 1,
            expiresDate: NOW + 30 * DAY,
          }),
        ),
        anthropic(),
      ]),
    });
    const body = (await response.json()) as { started: boolean; reason?: string };
    expect(body.started).toBe(false);
    expect(body.reason).toBe("alreadySubscribed");

    // Still eligible: nothing was spent.
    expect((await trialStatus(device)).status).toBe("eligible");
  });
});

describe("a device with no trial behind it", () => {
  /**
   * The same shape as the model test: a client that believes it is premium is
   * not argued with, it is *served the truth*. Nothing in the request can
   * assert a tier, and the absence of server-side trial state means the free
   * pool and the free lengths whatever the app thinks.
   */
  it("is metered and modelled as free", async () => {
    const device = "device-trial-liar";
    const { route, bodies } = recordingAnthropic(
      () =>
        new Response(sseLesson("Free."), {
          headers: { "content-type": "text/event-stream" },
        }),
    );

    const locked = await lesson(device, "Locked length", {
      window: "fifteen",
      fetcher: fixtureFetch([route]),
    });
    expect(locked.status).toBe(402);

    const allowed = await lesson(device, "Free length", { fetcher: fixtureFetch([route]) });
    expect(allowed.status).toBe(200);
    expect(bodies[0].model).toBe("claude-sonnet-5");
  });

  it("carries no trial header", async () => {
    const response = await lesson("device-trial-noheader", "No header here");
    expect(response.headers.get("x-spare-trial")).toBeNull();
  });
});

describe("what the trial unlocks", () => {
  it("routes a trialist to the premium pool's model", async () => {
    const device = "device-trial-opus";
    await startTrial(device);

    const { route, bodies } = recordingAnthropic(
      () =>
        new Response(sseLesson("Opus."), {
          headers: { "content-type": "text/event-stream" },
        }),
    );
    const response = await lesson(device, "Premium pool", { fetcher: fixtureFetch([route]) });

    expect(response.status).toBe(200);
    expect(bodies[0].model).toBe("claude-opus-5");
  });

  it("opens the lengths the free tier does not have", async () => {
    const device = "device-trial-lengths";
    await startTrial(device);
    const response = await lesson(device, "Fifteen minutes", { window: "fifteen" });
    expect(response.status).toBe(200);
  });

  it("reports the remaining count on every response", async () => {
    const device = "device-trial-header";
    await startTrial(device);
    const response = await lesson(device, "Counting down");

    const header = response.headers.get("x-spare-trial");
    expect(header).not.toBeNull();
    const trial = JSON.parse(header!) as TrialView;
    expect(trial.status).toBe("active");
    // Taken after metering, so it reflects the lesson this response carries
    // rather than the one before it.
    expect(trial.remainingLessons).toBe(9);
  });
});

describe("the trial's two ceilings", () => {
  /**
   * The tenth lesson lands, and the eleventh is a *free* one.
   *
   * This originally asserted a 402 on the eleventh, which was wrong about the
   * product rather than about the code. Spending the tenth lesson ends the
   * trial; §4 says what happens then, and it is not a wall — it is the free
   * tier, one lesson a day from the Sonnet pool. So the honest assertions are
   * that the premium lengths close, the pool drops back to free, and the
   * mirror says the week is over.
   */
  it("collapses to the free tier once the tenth lesson is spent", async () => {
    const device = "device-trial-ten";
    await startTrial(device);

    for (let index = 0; index < TRIAL_LESSONS; index += 1) {
      const response = await lesson(device, `Trial lesson ${index}`);
      expect(response.status, `lesson ${index + 1} of ${TRIAL_LESSONS}`).toBe(200);
    }

    expect((await trialStatus(device)).status).toBe("ended");

    // The premium lengths are gone.
    const locked = await lesson(device, "Fifteen after the cap", { window: "fifteen" });
    expect(locked.status).toBe(402);
    expect(((await locked.json()) as any).error.code).toBe("lockedWindow");

    // The refusal still carries the mirror, so a client that thought it was
    // trialing learns otherwise from the same response rather than showing a
    // paywall for a length it believes it owns.
    const mirror = JSON.parse(locked.headers.get("x-spare-trial")!) as TrialView;
    expect(mirror.status).toBe("ended");
    expect(mirror.remainingLessons).toBe(0);

    // And a free length still works, out of the free pool.
    const { route, bodies } = recordingAnthropic(
      () =>
        new Response(sseLesson("Back to free."), {
          headers: { "content-type": "text/event-stream" },
        }),
    );
    const free = await lesson(device, "Free again", { fetcher: fixtureFetch([route]) });
    expect(free.status).toBe(200);
    expect(bodies[0].model).toBe("claude-sonnet-5");
  });

  /**
   * `trialEnded` is what the meter answers when the router thought the trial
   * was live and the Durable Object knew better -- the read-then-consume race.
   * The router cannot produce it on its own, because it re-reads the trial
   * before choosing a tier, so it is asserted against the object directly.
   */
  it("refuses at the meter when the trial ran out between the read and the claim", async () => {
    const environment = testEnv();
    const device = "device-trial-race";
    const stub = environment.USAGE.get(environment.USAGE.idFromName(device));
    await stub.fetch(`https://usage/trial/start?now=${NOW}`);

    const milestones: Array<string | undefined> = [];
    for (let index = 0; index < TRIAL_LESSONS; index += 1) {
      const decision = (await (
        await stub.fetch(
          `https://usage/consume?tier=trialing&window=three&key=k${index}&now=${NOW}`,
        )
      ).json()) as { allow: boolean; milestone?: string };
      expect(decision.allow, `lesson ${index + 1}`).toBe(true);
      milestones.push(decision.milestone);
    }

    // The funnel milestone fires on the transition, once. Reported on every
    // lesson from the third onwards it would count requests rather than
    // devices, and the one number §6 turns on would be meaningless.
    expect(milestones).toEqual([
      undefined, undefined, "trialThreeLessons",
      undefined, undefined, undefined, undefined, undefined, undefined, undefined,
    ]);

    const refused = await (
      await stub.fetch(`https://usage/consume?tier=trialing&window=three&key=k99&now=${NOW}`)
    ).json();
    expect(refused).toEqual({ allow: false, reason: "trialEnded" });
  });

  /**
   * Independent ceilings. Spending both course slots must not read as the
   * trial being over, because it is not: the shorter lengths still work, and
   * saying otherwise would cost somebody the rest of their week.
   */
  it("refuses a third course while lessons remain", async () => {
    const device = "device-trial-courses";
    await startTrial(device);

    for (const index of [0, 1]) {
      const response = await lesson(device, `Course ${index}`, { window: "thirty" });
      expect(response.status, `course ${index + 1}`).toBe(200);
    }

    const third = await lesson(device, "Course 3", { window: "thirty" });
    expect(third.status).toBe(402);
    expect(((await third.json()) as any).error.code).toBe("trialCourseCapReached");

    const shorter = await lesson(device, "Still allowed");
    expect(shorter.status).toBe(200);
    expect(JSON.parse(shorter.headers.get("x-spare-trial")!).remainingLessons).toBe(7);
  });

  it("ends the trial at seven days even with lessons left", async () => {
    const device = "device-trial-clock";
    await startTrial(device);
    await lesson(device, "Day one");

    // Past expiry the device is plain free again, so a free-tier length is
    // refused by the daily limit rather than by anything trial-shaped. The
    // trial itself is what has to be gone; see the premium-length case below.
    const after = NOW + TRIAL_DURATION_MS + 1;
    expect((await trialStatus(device, after)).status).toBe("ended");

    const locked = await lesson(device, "Day eight, premium length", {
      window: "fifteen",
      now: after,
    });
    expect(locked.status).toBe(402);
    expect(((await locked.json()) as any).error.code).toBe("lockedWindow");
  });

  /**
   * A course is nine requests and one charge. Counting requests would spend a
   * whole trial on a single course — the bug `chargedKeys` already exists to
   * prevent for the free tier.
   */
  it("counts a whole course as one lesson and one course", async () => {
    const device = "device-trial-course-unit";
    await startTrial(device);

    await lesson(device, "Long course", { window: "thirty" });
    for (const chapter of [0, 1, 2, 3]) {
      const response = await call({
        path: "/v1/chapter",
        device,
        fetcher: fixtureFetch([anthropic()]),
        body: {
          window: "thirty",
          format: "chaptered",
          topic: "Long course",
          chapter,
          request: modelRequest(),
        },
      });
      expect(response.status, `chapter ${chapter}`).toBe(200);
    }

    const trial = await trialStatus(device);
    expect(trial.remainingLessons).toBe(9);
    expect(trial.remainingCourses).toBe(1);
  });
});

describe("a course started under the trial", () => {
  /**
   * Day 6 you start a course; day 8 you open chapter three. Without a grant
   * that request is refused, and the last thing the product does before
   * asking for money is break a feature you were enjoying. `chargedKeys` does
   * not cover it — that list rolls over with the UTC day.
   */
  it("finishes after the trial has ended", async () => {
    const device = "device-trial-grant-finish";
    await startTrial(device);
    const started = await lesson(device, "Unfinished course", { window: "thirty" });
    expect(started.status).toBe(200);

    const afterExpiry = NOW + TRIAL_DURATION_MS + 2 * DAY;
    const chapter = await call({
      path: "/v1/chapter",
      device,
      now: afterExpiry,
      fetcher: fixtureFetch([anthropic()]),
      body: {
        window: "thirty",
        format: "chaptered",
        topic: "Unfinished course",
        chapter: 2,
        request: modelRequest(),
      },
    });
    expect(chapter.status).toBe(200);
  });

  /**
   * The grant finishes *that* course and nothing else. One that opened the
   * chaptered window generally would be a standing free course.
   */
  it("does not open a different course after the trial has ended", async () => {
    const device = "device-trial-grant-scope";
    await startTrial(device);
    await lesson(device, "First course", { window: "thirty" });

    const afterExpiry = NOW + TRIAL_DURATION_MS + 2 * DAY;
    const other = await lesson(device, "A different course", {
      window: "thirty",
      now: afterExpiry,
    });
    expect(other.status).toBe(402);
  });
});
