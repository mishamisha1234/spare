/**
 * Tier enforcement and the spend ceiling.
 *
 * All counters live in Durable Objects, not KV. KV is eventually consistent,
 * so "one lesson per day" on KV loses to a double-tap: both requests read 0,
 * both pass, both write 1. The user gets two lessons, the log shows one, and
 * nothing errors — a silent leak. A Durable Object serialises every request
 * for a given id, so read-check-increment is atomic with no protocol.
 */

import { hasPremiumAccess, isPaying, type EffectiveTier } from "./appstore";

/** Mirrors `EntitlementRules` in SpareCore. Kept in step by a shared test. */
export const FREE_LESSONS_PER_DAY = 1;

/**
 * The subscriber's month.
 *
 * A course counts against both: it is one of the 50 and one of the 8, the same
 * way a trial course is one of the 10 and one of the 2.
 *
 * Fifty is a number no honest daily reader meets -- 31 days at one a day is
 * 31, and 50 tolerates an average of 1.6 a day every day. Eight courses is
 * one every four days. Both bound the tail and neither fixes the median: a
 * daily 15-minute reader costs ~$15.90 a month against $6.30 net on the
 * annual plan, and the shared premium cache is what closes that, not these.
 *
 * Courses came down from 12 before there was anybody to lower them on. With a
 * lesson cap in place the saving is only about $3.50 of worst case -- the four
 * freed slots become four more 15-minute lessons rather than vanishing -- so
 * the reason is direction, not money. A disclosed cap can be raised whenever
 * usage says so and cannot be lowered on existing subscribers without a
 * material-change notice.
 */
export const PREMIUM_LESSONS_PER_MONTH = 50;
export const PREMIUM_COURSES_PER_MONTH = 8;
export const FREE_WINDOWS = ["three", "seven"] as const;
export const CHAPTERED_WINDOWS = ["thirty"] as const;

/**
 * The reverse trial: seven days of premium, bounded.
 *
 * Uncapped premium for a week is a real exposure. The premium pool is Opus, a
 * 15-minute lesson costs roughly $0.53 and a course roughly $1.40, so an
 * enthusiastic trialist who then declines can run to $20 of inference. Ten
 * lessons of which at most two are courses bounds the worst case near $8, and
 * in practice well under that because most trial reading is short.
 *
 * A course counts against *both* ceilings: it is one of the ten and one of
 * the two.
 */
export const TRIAL_LESSONS = 10;
export const TRIAL_COURSES = 2;
export const TRIAL_DAYS = 7;
export const TRIAL_DURATION_MS = TRIAL_DAYS * 24 * 60 * 60 * 1000;

export type Decision =
  | { allow: true; servedFromCache: boolean; milestone?: FunnelMilestone }
  | { allow: false; reason: DenialReason };

/**
 * A threshold crossed by this request, for the funnel counters.
 *
 * Reported out of the Durable Object rather than written from inside it: the
 * object is the only place that can see the transition atomically, and the
 * router is the only place that should be doing fire-and-forget writes to
 * another object. Keeping the write in the router also keeps `UsageCounter`
 * free of a second binding.
 */
export type FunnelMilestone = "trialThreeLessons";

export type DenialReason =
  | "dailyLimitReached"
  | "lockedWindow"
  | "courseCapReached"
  /** The subscriber's monthly lesson allowance is spent. Not a paywall: they
   * are already paying and cannot buy their way past a fair-use ceiling. */
  | "lessonCapReached"
  | "spendCeilingReached"
  /**
   * The trial is over: seven days elapsed, or ten lessons used, whichever
   * came first.
   *
   * Distinct from `dailyLimitReached` so a client whose mirror is stale
   * self-heals into the day-7 summary rather than a generic paywall. The
   * mirror going stale is normal -- it is display state, and the server is
   * the authority -- so the refusal has to carry enough for the app to
   * correct itself.
   */
  | "trialEnded"
  /**
   * Both course slots are spent, but trial lessons remain. Deliberately not
   * `trialEnded`: the shorter lengths still work, and telling somebody their
   * trial is over when it is not would cost them the rest of it.
   */
  | "trialCourseCapReached";

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
  /** Premium lessons of any length charged this calendar month. */
  lessonsThisMonth: number;
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

/**
 * How long a started course may still draw chapters after the entitlement
 * that started it has gone.
 *
 * A course is an outline and four chapters, read over days. Without this, a
 * trialist who starts a course on day 6 and opens chapter 3 on day 8 is
 * refused mid-read -- the last thing the product does before asking for money
 * is break a feature they were enjoying. `chargedKeys` almost covers it, but
 * rolls over with the UTC day, so it only helps inside twenty-four hours.
 *
 * Thirty days is generous for finishing four chapters and still bounded: it
 * is not a standing grant of free generation, and at two courses per trial the
 * exposure it can carry past expiry is two courses.
 */
export const GRANT_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;

/** How many started courses a device remembers. Bounds the stored value. */
export const GRANT_HISTORY_LIMIT = 8;

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

/**
 * A course whose outline was paid for, and which may therefore finish.
 *
 * Separate from `chargedKeys` because it must outlive the day it was granted
 * on and the entitlement that granted it. See `GRANT_LIFETIME_MS`.
 */
export interface CourseGrant {
  /** `courseGrantKey`: the course's identity without its pool. */
  key: string;
  /** The pool it was generated into, and must keep being read from. */
  pool: string;
  grantedAt: number;
  requests: number;
}

/** Drops grants that have run out of time, then bounds what is left. */
function liveGrants(grants: CourseGrant[], now: number): CourseGrant[] {
  const live = grants.filter((grant) => now - grant.grantedAt < GRANT_LIFETIME_MS);
  return live.length <= GRANT_HISTORY_LIMIT ? live : live.slice(-GRANT_HISTORY_LIMIT);
}

/**
 * Trial state for one device.
 *
 * `startedAt` is the eligibility flag as well as the clock. There is no
 * separate `hasUsedTrial` boolean, because two fields that must agree are two
 * fields that can disagree -- and the one that would win is the one that
 * hands out Opus.
 */
export interface TrialState {
  /** Non-null means this device has consumed its one trial, ever. */
  startedAt: number | null;
  expiresAt: number | null;
  lessonsUsed: number;
  coursesUsed: number;
  /**
   * Whether this device's conversion has already been counted.
   *
   * A flag rather than a recomputation, because the thing being counted is an
   * event and not a state: a subscriber stays a subscriber, so without this
   * every launch would count another conversion and the denominator would
   * mean nothing.
   */
  conversionRecorded?: boolean;
}

/** What the client is allowed to mirror. Display only; never an authority. */
export interface TrialView {
  status: "eligible" | "active" | "ended";
  remainingLessons: number;
  remainingCourses: number;
  startedAt: number | null;
  expiresAt: number | null;
}

export const NO_TRIAL: TrialState = {
  startedAt: null,
  expiresAt: null,
  lessonsUsed: 0,
  coursesUsed: 0,
  conversionRecorded: false,
};

/**
 * Whether the trial still entitles anything.
 *
 * Both ceilings end it, whichever arrives first: seven days, or ten lessons.
 * Written as one function so the router, the meter, and the status endpoint
 * cannot answer it three different ways.
 */
export function isTrialActive(trial: TrialState, now: number): boolean {
  if (trial.startedAt === null || trial.expiresAt === null) return false;
  if (now >= trial.expiresAt) return false;
  return trial.lessonsUsed < TRIAL_LESSONS;
}

export function trialView(trial: TrialState, now: number): TrialView {
  const status = trial.startedAt === null ? "eligible" : isTrialActive(trial, now) ? "active" : "ended";
  return {
    status,
    // Zero once it is over, whichever ceiling ended it. A remaining count
    // that survives expiry would be shown to somebody who cannot spend it.
    remainingLessons: status === "active" ? Math.max(0, TRIAL_LESSONS - trial.lessonsUsed) : 0,
    remainingCourses: status === "active" ? Math.max(0, TRIAL_COURSES - trial.coursesUsed) : 0,
    startedAt: trial.startedAt,
    expiresAt: trial.expiresAt,
  };
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
      const tier = (url.searchParams.get("tier") ?? "free") as EffectiveTier;
      const window = url.searchParams.get("window") ?? "three";
      const key = url.searchParams.get("key") ?? "";
      const courseKey = url.searchParams.get("courseKey") ?? "";
      const pool = url.searchParams.get("pool") ?? "free";
      const decision = await this.consume(tier, window, key, courseKey, pool, now);
      return Response.json(decision);
    }

    // Whether a started course may still draw chapters, and out of which
    // pool. Read by the router before it picks a pool, which is earlier than
    // metering can happen; `consume` re-checks the same list.
    if (url.pathname === "/grant") {
      const grants = await this.loadGrants(now);
      const grant = grants.find((entry) => entry.key === (url.searchParams.get("key") ?? ""));
      return Response.json({ pool: grant?.pool ?? null });
    }

    // Read-only. The router needs it before it can pick a pool and a model,
    // which is earlier than any atomic claim can happen. See `consume` for
    // why that ordering is safe.
    if (url.pathname === "/trial") {
      return Response.json(trialView(await this.loadTrial(), now));
    }

    // Trial state and the month's counters in one round trip, for
    // `/v1/allowance`. The router turns the counters into remaining figures,
    // because it is the router that knows whether this device is paying.
    if (url.pathname === "/allowance") {
      const usage = await this.load(now);
      return Response.json({
        trial: trialView(await this.loadTrial(), now),
        lessonsThisMonth: usage.lessonsThisMonth,
        coursesThisMonth: usage.coursesThisMonth,
      });
    }

    if (url.pathname === "/trial/start") {
      return Response.json(await this.startTrial(now));
    }

    // Counts a conversion once, ever, and says which side of expiry it fell.
    // Reported by the client at purchase time rather than polled, so a
    // subscriber costs no extra read on any other request.
    if (url.pathname === "/trial/converted") {
      return Response.json(await this.recordConversion(now));
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

  private async loadTrial(): Promise<TrialState> {
    return (await this.state.storage.get<TrialState>("trial")) ?? NO_TRIAL;
  }

  /**
   * Claims this device's one trial.
   *
   * Idempotent, and deliberately so: a retry, a double-tap, or a second
   * install must not extend anything. A device that already has a trial --
   * running or long finished -- gets its existing state back with
   * `started: false`, and `startedAt` is never written twice.
   *
   * Atomic because it is a Durable Object method: read-check-write for a
   * given device id cannot interleave with another request for that device.
   * Two simultaneous taps therefore produce one trial, not two overlapping
   * clocks.
   */
  private async startTrial(now: number): Promise<{ started: boolean; trial: TrialView }> {
    const existing = await this.loadTrial();
    if (existing.startedAt !== null) {
      return { started: false, trial: trialView(existing, now) };
    }

    const started: TrialState = {
      startedAt: now,
      expiresAt: now + TRIAL_DURATION_MS,
      lessonsUsed: 0,
      coursesUsed: 0,
    };
    await this.state.storage.put<TrialState>("trial", started);
    return { started: true, trial: trialView(started, now) };
  }

  /**
   * Marks this device as converted, if it had a trial and has not been
   * counted yet.
   *
   * `atDay7` means within a couple of days either side of the trial ending --
   * the decision made *because* of the day-7 screen. Anything later is a
   * different thing worth knowing separately: a meaningful share of freemium
   * conversions land six or more weeks after install, and folding those into
   * the day-7 figure would make the screen look better than it is.
   */
  private async recordConversion(
    now: number,
  ): Promise<{ recorded: "atDay7" | "afterDay7" | null }> {
    const trial = await this.loadTrial();
    if (trial.startedAt === null || trial.conversionRecorded) return { recorded: null };

    const expiry = trial.expiresAt ?? trial.startedAt;
    const recorded = now - expiry <= CONVERSION_AT_DAY7_WINDOW_MS ? "atDay7" : "afterDay7";
    await this.state.storage.put<TrialState>("trial", { ...trial, conversionRecorded: true });
    return { recorded };
  }

  private async loadGrants(now: number): Promise<CourseGrant[]> {
    return liveGrants((await this.state.storage.get<CourseGrant[]>("grants")) ?? [], now);
  }

  private async load(now: number): Promise<UsageState> {
    const stored = (await this.state.storage.get<UsageState>("usage")) ?? {
      day: dayKey(now),
      lessonsToday: 0,
      month: monthKey(now),
      coursesThisMonth: 0,
      lessonsThisMonth: 0,
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
      // Absent in anything written before the monthly lesson cap existed.
      lessonsThisMonth: stored.month === thisMonth ? (stored.lessonsThisMonth ?? 0) : 0,
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
    tier: EffectiveTier,
    window: string,
    key: string,
    /** `courseGrantKey`, or "" for anything that is not a course. */
    courseKey: string,
    pool: string,
    now: number,
  ): Promise<Decision> {
    const usage = await this.load(now);
    const isTrialing = tier === "trialing";
    const isPremium = hasPremiumAccess(tier);
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

    // A course whose outline was paid for may finish, whatever has happened
    // to the entitlement since. Checked before the tier gates on purpose:
    // that is the entire point of a grant.
    //
    // Bounded the same way a charged lesson is. Without a ceiling this is a
    // generate-forever loop on one topic for anyone who noticed it -- worse
    // than the daily one, because a grant outlives the day.
    if (courseKey) {
      const grants = await this.loadGrants(now);
      const grant = grants.find((entry) => entry.key === courseKey);
      if (grant) {
        if (grant.requests >= MAX_REQUESTS_PER_LESSON) {
          return { allow: false, reason: "dailyLimitReached" };
        }
        await this.state.storage.put<CourseGrant[]>(
          "grants",
          grants.map((entry) =>
            entry.key === courseKey ? { ...entry, requests: entry.requests + 1 } : entry,
          ),
        );
        return { allow: true, servedFromCache: false };
      }
    }

    // The trial's two ceilings, checked here and nowhere else.
    //
    // The router reads trial state earlier, to pick a pool and a model, and
    // that read is not atomic with this one. It does not need to be. The
    // worst a race can do is route a request to Opus and then refuse it here
    // before a single token is generated -- a refusal, not a leak. This is
    // the only place the counters move.
    let trial: TrialState | null = null;
    if (isTrialing) {
      trial = await this.loadTrial();
      if (!isTrialActive(trial, now)) {
        return { allow: false, reason: "trialEnded" };
      }
      if (isChaptered && trial.coursesUsed >= TRIAL_COURSES) {
        return { allow: false, reason: "trialCourseCapReached" };
      }
    } else if (!isPremium) {
      if (!(FREE_WINDOWS as readonly string[]).includes(window)) {
        return { allow: false, reason: "lockedWindow" };
      }
      if (usage.lessonsToday >= FREE_LESSONS_PER_DAY) {
        return { allow: false, reason: "dailyLimitReached" };
      }
    } else {
      // A subscriber's month. The course ceiling is checked first because it
      // is the more specific refusal: "you have used every course this month"
      // explains itself, where "you have used every lesson" would not, given
      // the shorter lengths are still open.
      if (isChaptered && usage.coursesThisMonth >= PREMIUM_COURSES_PER_MONTH) {
        return { allow: false, reason: "courseCapReached" };
      }
      if (usage.lessonsThisMonth >= PREMIUM_LESSONS_PER_MONTH) {
        return { allow: false, reason: "lessonCapReached" };
      }
    }

    let milestone: FunnelMilestone | undefined;
    if (trial) {
      // The one number §6 turns on: did somebody who was given a free week
      // read enough to have an opinion about it. Reported on the transition,
      // so it counts devices and not requests.
      if (trial.lessonsUsed + 1 === FUNNEL_ENGAGED_LESSONS) milestone = "trialThreeLessons";
      await this.state.storage.put<TrialState>("trial", {
        ...trial,
        // Cache hits count. A reader cannot tell a cached lesson from a
        // generated one, so a cap that only counted generations would be a
        // cap nobody could describe -- the same reasoning that made the free
        // daily limit count cached reads.
        lessonsUsed: trial.lessonsUsed + 1,
        coursesUsed: isChaptered ? trial.coursesUsed + 1 : trial.coursesUsed,
      });
    }

    // A started course may finish, whatever happens to the entitlement that
    // started it. Recorded for every tier, not just the trial: a monthly
    // subscription lapsing mid-course has exactly the same shape.
    if (isChaptered && courseKey) {
      const grants = await this.loadGrants(now);
      await this.state.storage.put<CourseGrant[]>(
        "grants",
        liveGrants([...grants, { key: courseKey, pool, grantedAt: now, requests: 1 }], now),
      );
    }

    // A trialist is not a subscriber, so neither monthly counter moves for
    // them. `coursesThisMonth` used to, which meant a trialist's two courses
    // came out of the eight they would get if they subscribed that month --
    // charging a new customer for something they were given.
    const spendsMonthlyAllowance = isPaying(tier);

    await this.state.storage.put<UsageState>("usage", {
      ...usage,
      lessonsToday: isPremium ? usage.lessonsToday : usage.lessonsToday + 1,
      coursesThisMonth:
        spendsMonthlyAllowance && isChaptered
          ? usage.coursesThisMonth + 1
          : usage.coursesThisMonth,
      // Cache hits count, like everywhere else: a reader cannot tell a cached
      // lesson from a generated one, so a cap that counted only generations
      // would be a cap nobody could describe.
      lessonsThisMonth: spendsMonthlyAllowance
        ? usage.lessonsThisMonth + 1
        : usage.lessonsThisMonth,
      chargedKeys: key
        ? trimCharged([...usage.chargedKeys, { key, requests: 1 }])
        : usage.chargedKeys,
    });

    return { allow: true, servedFromCache: false, milestone };
  }
}

/**
 * How many trial lessons count as having actually tried the thing.
 *
 * From §6: above 40% of paywall-dismissers reaching this, the model works and
 * the lever is pricing; under 15%, the lessons are not good enough and no
 * pricing change fixes that. Three is the number that makes those two
 * thresholds mean something.
 */
export const FUNNEL_ENGAGED_LESSONS = 3;

/** How close to expiry a purchase still counts as the day-7 decision. */
export const CONVERSION_AT_DAY7_WINDOW_MS = 2 * 24 * 60 * 60 * 1000;

/**
 * Five integers, globally.
 *
 * No device identifiers, no per-user rows, nothing that can be traced back to
 * anybody -- which is what lets this exist at all alongside a no-analytics,
 * no-tracking promise. It answers one question: what share of the people who
 * dismissed the first paywall went on to read enough to have an opinion.
 * A device-local log cannot answer that, because a percentage needs a
 * denominator that spans devices.
 *
 * Two of the five are client-reported (`paywallsDismissed`, and the trigger
 * for a conversion) and are therefore inflatable by anyone who reads the
 * endpoint. That is accepted: these are internal decision numbers, not
 * billing, and the cost of a wrong one is a marketing judgement rather than
 * money. The three derived from server state are not spoofable.
 */
export interface FunnelState {
  trialsStarted: number;
  trialsWithThreePlusLessons: number;
  paywallsDismissed: number;
  convertedAtDay7: number;
  convertedAfterDay7: number;
}

export const EMPTY_FUNNEL: FunnelState = {
  trialsStarted: 0,
  trialsWithThreePlusLessons: 0,
  paywallsDismissed: 0,
  convertedAtDay7: 0,
  convertedAfterDay7: 0,
};

export type FunnelCounter = keyof FunnelState;

export class FunnelLedger implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/peek") {
      return Response.json(await this.load());
    }

    if (url.pathname === "/bump") {
      const counter = url.searchParams.get("counter") as FunnelCounter | null;
      const current = await this.load();
      // An unrecognised counter is dropped rather than created. This object
      // holds a fixed set of five and nothing should be able to grow it from
      // outside.
      if (!counter || !(counter in current)) return Response.json(current);
      const updated: FunnelState = { ...current, [counter]: current[counter] + 1 };
      await this.state.storage.put<FunnelState>("funnel", updated);
      return Response.json(updated);
    }

    return new Response("not found", { status: 404 });
  }

  private async load(): Promise<FunnelState> {
    return { ...EMPTY_FUNNEL, ...(await this.state.storage.get<FunnelState>("funnel")) };
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
