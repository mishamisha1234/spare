/**
 * The five global integers behind §6's one decision number.
 *
 * No device identifiers reach this object, which is what lets it exist next to
 * a no-analytics promise. What these tests hold it to is that the counters
 * mean what the threshold reads them as: devices, not requests, and a
 * conversion counted once on the right side of expiry.
 */

import { describe, expect, it } from "vitest";
import { anthropicStreaming, fixtureFetch, sseLesson } from "./fixtures";
import { NOW, call, modelRequest, testEnv } from "./harness";
import { FUNNEL_ENGAGED_LESSONS, TRIAL_DURATION_MS, type FunnelState } from "../src/limits";

const DAY = 86_400_000;

function anthropic() {
  return anthropicStreaming(sseLesson("A lesson."));
}

async function funnel(): Promise<FunnelState> {
  const environment = testEnv();
  const stub = environment.FUNNEL.get(environment.FUNNEL.idFromName("global"));
  return (await (await stub.fetch("https://funnel/peek")).json()) as FunnelState;
}

function post(path: string, device: string, body: Record<string, unknown>, now = NOW) {
  return call({ path, device, now, body, fetcher: fixtureFetch([anthropic()]) });
}

function lesson(device: string, topic: string, now = NOW) {
  return call({
    device,
    now,
    fetcher: fixtureFetch([anthropic()]),
    body: { window: "three", format: "oneThing", topic, request: modelRequest() },
  });
}

describe("the funnel", () => {
  it("counts a trial start", async () => {
    const before = (await funnel()).trialsStarted;
    await post("/v1/trial/start", "device-funnel-start", {});
    expect((await funnel()).trialsStarted).toBe(before + 1);
  });

  /**
   * Idempotent starts must not inflate the denominator. A device that taps
   * twice is one trial and has to be one count.
   */
  it("counts a trial start once however often it is asked for", async () => {
    const device = "device-funnel-start-twice";
    await post("/v1/trial/start", device, {});
    const after = (await funnel()).trialsStarted;
    await post("/v1/trial/start", device, {});
    expect((await funnel()).trialsStarted).toBe(after);
  });

  it("counts a dismissed paywall, which it cannot see any other way", async () => {
    const before = (await funnel()).paywallsDismissed;
    await post("/v1/funnel", "device-funnel-dismiss", { event: "paywallDismissed" });
    expect((await funnel()).paywallsDismissed).toBe(before + 1);
  });

  it("ignores an event name it does not know", async () => {
    const before = await funnel();
    await post("/v1/funnel", "device-funnel-junk", { event: "somethingElse" });
    expect(await funnel()).toEqual(before);
  });

  /**
   * The numerator of the number §6 turns on. Counted on the transition to the
   * third lesson and not once per request afterwards, or it would be counting
   * requests and the threshold would mean nothing.
   */
  it("counts a device that read three trial lessons, once", async () => {
    const device = "device-funnel-engaged";
    await post("/v1/trial/start", device, {});
    const before = (await funnel()).trialsWithThreePlusLessons;

    for (let index = 0; index < FUNNEL_ENGAGED_LESSONS; index += 1) {
      expect((await lesson(device, `Engaged ${index}`)).status).toBe(200);
    }
    expect((await funnel()).trialsWithThreePlusLessons).toBe(before + 1);

    // Three more lessons, still one device.
    for (let index = 3; index < 6; index += 1) {
      expect((await lesson(device, `Engaged ${index}`)).status).toBe(200);
    }
    expect((await funnel()).trialsWithThreePlusLessons).toBe(before + 1);
  });

  it("does not count a device that stopped at two", async () => {
    const device = "device-funnel-two";
    await post("/v1/trial/start", device, {});
    const before = (await funnel()).trialsWithThreePlusLessons;

    await lesson(device, "Only one");
    await lesson(device, "Only two");
    expect((await funnel()).trialsWithThreePlusLessons).toBe(before);
  });

  // MARK: conversions

  it("counts a purchase near expiry as the day-7 decision", async () => {
    const device = "device-funnel-day7";
    await post("/v1/trial/start", device, {});
    const before = await funnel();

    await post("/v1/funnel", device, { event: "converted" }, NOW + TRIAL_DURATION_MS + DAY);
    const after = await funnel();
    expect(after.convertedAtDay7).toBe(before.convertedAtDay7 + 1);
    expect(after.convertedAfterDay7).toBe(before.convertedAfterDay7);
  });

  /**
   * A meaningful share of freemium conversions land six or more weeks after
   * install. Folding those into the day-7 figure would make the day-7 screen
   * look better than it is.
   */
  it("counts a much later purchase separately", async () => {
    const device = "device-funnel-later";
    await post("/v1/trial/start", device, {});
    const before = await funnel();

    await post("/v1/funnel", device, { event: "converted" }, NOW + 40 * DAY);
    const after = await funnel();
    expect(after.convertedAfterDay7).toBe(before.convertedAfterDay7 + 1);
    expect(after.convertedAtDay7).toBe(before.convertedAtDay7);
  });

  /**
   * A subscriber stays a subscriber, so without a recorded flag every launch
   * would count another conversion and the denominator would mean nothing.
   */
  it("counts a conversion once, however often it is reported", async () => {
    const device = "device-funnel-once";
    await post("/v1/trial/start", device, {});
    await post("/v1/funnel", device, { event: "converted" }, NOW + TRIAL_DURATION_MS);
    const after = await funnel();

    await post("/v1/funnel", device, { event: "converted" }, NOW + TRIAL_DURATION_MS);
    await post("/v1/funnel", device, { event: "converted" }, NOW + 30 * DAY);
    expect(await funnel()).toEqual(after);
  });

  it("does not count a conversion from a device that never had a trial", async () => {
    const before = await funnel();
    await post("/v1/funnel", "device-funnel-notrial", { event: "converted" });
    expect(await funnel()).toEqual(before);
  });
});
