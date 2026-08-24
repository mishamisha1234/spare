/**
 * Tier enforcement and the spend ceiling.
 *
 * All counters live in Durable Objects, not KV. KV is eventually consistent,
 * so "one lesson per day" on KV loses to a double-tap: both requests read 0,
 * both pass, both write 1. The user gets two lessons, the log shows one, and
 * nothing errors — a silent leak. A Durable Object serialises every request
 * for a given id, so read-check-increment is atomic with no protocol.
 */

import type { Tier } from "./appstore";

/** Mirrors `EntitlementRules` in SpareCore. Kept in step by a shared test. */
export const FREE_LESSONS_PER_DAY = 1;
export const PREMIUM_COURSES_PER_MONTH = 12;
export const FREE_WINDOWS = ["three", "ten"] as const;
export const CHAPTERED_WINDOWS = ["thirty"] as const;

export type Decision =
  | { allow: true; servedFromCache: boolean }
  | { allow: false; reason: DenialReason };

export type DenialReason =
  | "dailyLimitReached"
  | "lockedWindow"
  | "courseCapReached"
  | "spendCeilingReached";

export interface ChargedLesson {
  key: string;
  /** HTTP requests served under this charge, including retries. */
  requests: number;
}

export interface UsageState {
  /** UTC day key, e.g. "2026-08-17". */
  day: string;
  lessonsToday: number;
  /** UTC month key, e.g. "2026-08". */
  month: string;
  coursesThisMonth: number;
  /**
   * Lessons charged for today, and how many requests each has been allowed.
   *
   * One lesson is several HTTP requests: a draft and a revision, and for a
   * course an outline plus four chapters twice over. Counting requests charged
   * a free user's single daily lesson to the draft and then refused the
   * revision, so the free tier could not finish one lesson; and it counted a
   * single course as nine against a cap of twelve a month.
   *
   * Keyed on the lesson rather than on a pass number the client sends, because
   * the key is already derived from window, format, and topic — facts the proxy
   * needs anyway — and a client-supplied "this is only the revision" flag would
   * be a free-generation switch for anyone who read the request.
   *
   * The count is what stops the fix becoming a worse hole than the bug. Once a
   * lesson is paid for, its later requests are free — so without a bound, a free
   * device could send the same topic all day and generate every time. Spoofing
   * the device id already resets the allowance, but that costs a reinstall;
   * repeating a request costs nothing.
   */
  chargedKeys: ChargedLesson[];
}

/**
 * How many cache keys a device remembers having read.
 *
 * Bounded because this list never rolls over — it is the whole point that it
 * persists — and an unbounded array in a single Durable Object value would
 * eventually hit the per-value size limit and start failing writes. A free user
 * gets one lesson a day, so 400 is over a year of history, and the oldest entry
 * falling off means at worst a repeat of something read more than a year ago.
 */
export const SEEN_HISTORY_LIMIT = 400;

/**
 * How many distinct lessons a device may be charged for in one day before the
 * oldest is forgotten.
 *
 * Rolls over daily, so unlike the seen list this never has to hold a year. A
 * premium reader doing a hundred lessons in a day is already implausible; the
 * cost of falling off the end is one extra charge for a lesson resumed after
 * ninety-nine others, which for a premium reader is not a charge at all.
 */
export const CHARGED_HISTORY_LIMIT = 100;

/**
 * How many requests one charged lesson may cover.
 *
 * A single lesson is two: a draft and a revision. A 30-minute course is nine: an
 * outline plus four chapters twice over.
 *
 * Raised from sixteen when the word-floor check landed. A pass that comes back
 * materially under its floor is now run again, once, so a course's worst
 * honest case became an outline plus four chapters of two drafts and two
 * revisions — seventeen, one past the old bound. A limit that a legitimate
 * course could cross is worse than no limit: it turns a length problem into a
 * 402 in the middle of chapter three, which reads as the app being broken.
 * Twenty-four leaves that worst case room for the client's retry policy on top.
 *
 * Past it, the lesson is refused as if it were a new one. That is not a limit
 * any honest client can reach; it is the ceiling on what a dishonest one gets
 * for a single day's allowance.
 */
export const MAX_REQUESTS_PER_LESSON = 24;

/** Keeps the most recent `SEEN_HISTORY_LIMIT` entries, dropping the oldest. */
function trimSeen(keys: string[]): string[] {
  return keys.length <= SEEN_HISTORY_LIMIT ? keys : keys.slice(-SEEN_HISTORY_LIMIT);
}

/** Same, for the day's charged lessons. */
function trimCharged(charged: ChargedLesson[]): ChargedLesson[] {
  return charged.length <= CHARGED_HISTORY_LIMIT
    ? charged
    : charged.slice(-CHARGED_HISTORY_LIMIT);
}

export function dayKey(now: number): string {
  return new Date(now).toISOString().slice(0, 10);
}

export function monthKey(now: number): string {
  return new Date(now).toISOString().slice(0, 7);
}

/**
 * Per-device counters.
 *
 * One object per device id. Rollover is computed on read rather than by a
 * scheduled reset: a stored day that isn't today means the count is zero,
 * which needs no cron and cannot drift if the object sleeps for a week.
 */
export class UsageCounter implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const now = Number(url.searchParams.get("now") ?? Date.now());

    if (url.pathname === "/peek") {
      return Response.json(await this.load(now));
    }

    if (url.pathname === "/consume") {
      const tier = (url.searchParams.get("tier") ?? "free") as Tier;
      const window = url.searchParams.get("window") ?? "three";
      const key = url.searchParams.get("key") ?? "";
      const decision = await this.consume(tier, window, key, now);
      return Response.json(decision);
    }

    // A plain read. It does not need to be an atomic claim any more: the router
    // meters before it serves, and `consume` already allows only one lesson a
    // day, so two simultaneous requests from one device cannot both be served.
    if (url.pathname === "/hasSeen") {
      const key = url.searchParams.get("key") ?? "";
      return Response.json({ seen: (await this.seenKeys()).includes(key) });
    }

    if (url.pathname === "/markSeen") {
      await this.markSeen(url.searchParams.get("key") ?? "");
      return Response.json({ ok: true });
    }

    return new Response("not found", { status: 404 });
  }

  private async seenKeys(): Promise<string[]> {
    return (await this.state.storage.get<string[]>("seenLessons")) ?? [];
  }

  private async markSeen(key: string): Promise<void> {
    if (!key) return;
    const seen = await this.seenKeys();
    if (seen.includes(key)) return;
    await this.state.storage.put("seenLessons", trimSeen([...seen, key]));
  }

  private async load(now: number): Promise<UsageState> {
    const stored = (await this.state.storage.get<UsageState>("usage")) ?? {
      day: dayKey(now),
      lessonsToday: 0,
      month: monthKey(now),
      coursesThisMonth: 0,
      chargedKeys: [],
    };

    // Rollover on read.
    const today = dayKey(now);
    const thisMonth = monthKey(now);
    return {
      day: today,
      lessonsToday: stored.day === today ? stored.lessonsToday : 0,
      month: thisMonth,
      coursesThisMonth: stored.month === thisMonth ? stored.coursesThisMonth : 0,
      // Rolls over with the day it belongs to. A record written before this
      // deploy has no field at all, hence the fallback.
      chargedKeys: stored.day === today ? (stored.chargedKeys ?? []) : [],
    };
  }

  /**
   * Checks and records in one atomic step.
   *
   * Deliberately not split into `check()` then `record()`: two round trips to
   * the same object are individually atomic but jointly racy, which is the
   * bug this class exists to prevent.
   */
  private async consume(
    tier: Tier,
    window: string,
    key: string,
    now: number,
  ): Promise<Decision> {
    const usage = await this.load(now);
    const isPremium = tier !== "free";
    const isChaptered = (CHAPTERED_WINDOWS as readonly string[]).includes(window);

    // Already paid for today. The second pass of a lesson, and every chapter of
    // a course, arrive as separate requests carrying the same key -- they are
    // one lesson to the reader and have to be one unit here. Allowed without a
    // tier check as well as without a charge: refusing the revision pass of a
    // lesson whose draft was allowed would leave the reader with half a lesson.
    //
    // Up to a point. See MAX_REQUESTS_PER_LESSON: an unbounded free repeat is a
    // generate-forever loop for anyone who noticed it.
    const charged = key ? usage.chargedKeys.find((entry) => entry.key === key) : undefined;
    if (charged) {
      if (charged.requests >= MAX_REQUESTS_PER_LESSON) {
        return { allow: false, reason: "dailyLimitReached" };
      }
      await this.state.storage.put<UsageState>("usage", {
        ...usage,
        chargedKeys: usage.chargedKeys.map((entry) =>
          entry.key === key ? { key, requests: entry.requests + 1 } : entry,
        ),
      });
      return { allow: true, servedFromCache: false };
    }

    if (!isPremium) {
      if (!(FREE_WINDOWS as readonly string[]).includes(window)) {
        return { allow: false, reason: "lockedWindow" };
      }
      if (usage.lessonsToday >= FREE_LESSONS_PER_DAY) {
        return { allow: false, reason: "dailyLimitReached" };
      }
    } else if (isChaptered && usage.coursesThisMonth >= PREMIUM_COURSES_PER_MONTH) {
      return { allow: false, reason: "courseCapReached" };
    }

    await this.state.storage.put<UsageState>("usage", {
      ...usage,
      lessonsToday: isPremium ? usage.lessonsToday : usage.lessonsToday + 1,
      coursesThisMonth: isChaptered ? usage.coursesThisMonth + 1 : usage.coursesThisMonth,
      chargedKeys: key
        ? trimCharged([...usage.chargedKeys, { key, requests: 1 }])
        : usage.chargedKeys,
    });

    return { allow: true, servedFromCache: false };
  }
}

export interface SpendState {
  month: string;
  /** Estimated USD spent this month across every user. */
  spentUSD: number;
}

/**
 * The global spend ceiling.
 *
 * A single object, and therefore a single serialisation point for every
 * generation in the system. That is a bottleneck by construction, and at this
 * scale it is the right trade: this is the number that actually protects the
 * money, and an approximate ceiling is not a ceiling.
 *
 * Past the ceiling, free generation stops and falls back to the cache;
 * premium keeps working, because those requests are verified and paid for.
 * Tripping this is a signal that something is wrong, not a normal operating
 * state.
 */
export class SpendLedger implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const now = Number(url.searchParams.get("now") ?? Date.now());
    const ceiling = Number(url.searchParams.get("ceiling") ?? "0");

    if (url.pathname === "/peek") {
      return Response.json(await this.load(now));
    }

    if (url.pathname === "/check") {
      const state = await this.load(now);
      return Response.json({ withinCeiling: state.spentUSD < ceiling, spentUSD: state.spentUSD });
    }

    if (url.pathname === "/record") {
      const amount = Number(url.searchParams.get("usd") ?? "0");
      const state = await this.load(now);
      const updated: SpendState = {
        month: state.month,
        spentUSD: state.spentUSD + (Number.isFinite(amount) ? Math.max(0, amount) : 0),
      };
      await this.state.storage.put<SpendState>("spend", updated);
      return Response.json(updated);
    }

    return new Response("not found", { status: 404 });
  }

  private async load(now: number): Promise<SpendState> {
    const stored = await this.state.storage.get<SpendState>("spend");
    const thisMonth = monthKey(now);
    if (!stored || stored.month !== thisMonth) {
      return { month: thisMonth, spentUSD: 0 };
    }
    return stored;
  }
}
