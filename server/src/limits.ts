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

export interface UsageState {
  /** UTC day key, e.g. "2026-08-17". */
  day: string;
  lessonsToday: number;
  /** UTC month key, e.g. "2026-08". */
  month: string;
  coursesThisMonth: number;
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

/** Keeps the most recent `SEEN_HISTORY_LIMIT` entries, dropping the oldest. */
function trimSeen(keys: string[]): string[] {
  return keys.length <= SEEN_HISTORY_LIMIT ? keys : keys.slice(-SEEN_HISTORY_LIMIT);
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
      const decision = await this.consume(tier, window, now);
      return Response.json(decision);
    }

    // Atomic check-and-mark, for the same reason `consume` is atomic: split
    // into a read then a write, two simultaneous requests both see "unseen"
    // and the device is served the same cached lesson twice.
    if (url.pathname === "/claimUnseen") {
      const key = url.searchParams.get("key") ?? "";
      return Response.json({ unseen: await this.claimUnseen(key) });
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

  /** True if this device had not read the lesson; records it either way. */
  private async claimUnseen(key: string): Promise<boolean> {
    if (!key) return false;
    const seen = await this.seenKeys();
    if (seen.includes(key)) return false;
    await this.state.storage.put("seenLessons", trimSeen([...seen, key]));
    return true;
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
    };

    // Rollover on read.
    const today = dayKey(now);
    const thisMonth = monthKey(now);
    return {
      day: today,
      lessonsToday: stored.day === today ? stored.lessonsToday : 0,
      month: thisMonth,
      coursesThisMonth: stored.month === thisMonth ? stored.coursesThisMonth : 0,
    };
  }

  /**
   * Checks and records in one atomic step.
   *
   * Deliberately not split into `check()` then `record()`: two round trips to
   * the same object are individually atomic but jointly racy, which is the
   * bug this class exists to prevent.
   */
  private async consume(tier: Tier, window: string, now: number): Promise<Decision> {
    const usage = await this.load(now);
    const isPremium = tier !== "free";
    const isChaptered = (CHAPTERED_WINDOWS as readonly string[]).includes(window);

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
