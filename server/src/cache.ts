/**
 * The lesson cache — the single biggest cost lever.
 *
 * Two pools, never shared. The free pool is written by Sonnet and served to
 * free readers; the premium pool is written by Opus, carries an attached test,
 * and is served to premium readers. A reader is only ever shown entries from
 * their own pool, so what premium buys is the better pool plus interest
 * matching — not authorship. Two premium readers with the same interests may
 * well get the same words, and that is intended.
 *
 * Caching applies to both tiers. Generation happens only on a miss.
 *
 * KV is the right store here, unlike the counters: it is eventually consistent,
 * and both failure modes are harmless. A stale miss costs one regeneration; a
 * stale hit serves a slightly older lesson. Neither loses money or
 * double-counts anything.
 */

/** Which pool an entry belongs to. Never mixed: different models, different
 * attached artifacts, different readers. */
export type Pool = "free" | "premium";

export function poolFor(tier: string): Pool {
  return tier === "free" ? "free" : "premium";
}

/** Words carrying no topical signal, so "why do bridges hum" == "bridges hum". */
const STOPWORDS = new Set([
  "a", "an", "and", "are", "as", "at", "be", "but", "by", "do", "does", "for",
  "from", "how", "in", "is", "it", "its", "of", "on", "or", "the", "to", "was",
  "what", "when", "where", "which", "who", "why", "with", "you", "your",
]);

/**
 * Collapses a topic to a cache key component.
 *
 * Lowercases, strips punctuation, drops stopwords, then **sorts** the
 * remaining words — so "Why bridges hum" and "How do bridges hum?" collide on
 * purpose, and so does "hum bridges". Word order carries little topical
 * meaning in a seven-word title, and treating it as significant would miss
 * most of the available hits.
 */
export function normaliseTopic(topic: string): string {
  const words = topic
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .split(/\s+/)
    .filter((word) => word.length > 0 && !STOPWORDS.has(word));

  // Everything was a stopword: fall back to the raw text rather than an empty
  // key, which would collide every such topic into one entry.
  if (words.length === 0) {
    return topic.toLowerCase().replace(/\s+/g, "-").slice(0, 64);
  }

  return [...new Set(words)].sort().join("-").slice(0, 200);
}

/** Interest categories are free text from the client; flatten them the same
 * way, so "Art History" and "art  history" are one category. */
export function normaliseInterest(interest: string): string {
  return interest.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-|-$/g, "").slice(0, 48);
}

export interface LessonIdentity {
  pool: Pool;
  window: string;
  format: string;
  topic: string;
  /** The interest category the lesson was generated under. Premium pool only:
   * retrieval matches a reader's stated interests, and the free pool has no
   * interest matching to do. Empty elsewhere. */
  interest?: string;
}

/**
 * The identity of a *lesson*, independent of how many requests it takes.
 *
 * This is the metering key and the seen-once key. A 30-minute course is one
 * lesson to the reader — an outline plus four chapters plus their revisions —
 * and must be one charge and one "already read" mark between them. Counting
 * requests instead is what once made a free user's allowance go on the draft
 * and the revision come back 402.
 */
export function lessonPoolKey(identity: LessonIdentity): string {
  const interest = identity.pool === "premium" && identity.interest
    ? `${normaliseInterest(identity.interest)}:`
    : "";
  return `lesson:v2:${identity.pool}:${identity.format}:${identity.window}:`
    + `${interest}${normaliseTopic(identity.topic)}`;
}

/** One cacheable unit of a lesson. */
export type CacheUnit =
  | { kind: "whole" }
  | { kind: "outline" }
  | { kind: "chapter"; index: number };

/**
 * The key one stored body lives under.
 *
 * The chapter index is the part that was missing, and its absence was a bug
 * waiting for premium to start reading the cache. A course's outline and all
 * four of its chapters carried the same key, so each wrote over the last and
 * the entry ended up holding whichever chapter finished most recently. Serving
 * that back would have replayed chapter 4 as the whole course. It never fired
 * because only free readers read the cache and courses are premium — which is
 * exactly the kind of latent fault that surfaces the day a flag flips.
 */
export function lessonCacheKey(identity: LessonIdentity, unit: CacheUnit = { kind: "whole" }): string {
  const base = lessonPoolKey(identity);
  switch (unit.kind) {
    case "whole": return base;
    case "outline": return `${base}#outline`;
    case "chapter": return `${base}#chapter:${unit.index}`;
  }
}

/** Which unit a generation endpoint produces. */
export function unitFor(pathname: string, chapterIndex: number | null): CacheUnit {
  if (pathname === "/v1/outline") return { kind: "outline" };
  if (pathname === "/v1/chapter") {
    // A chapter with no index is not cacheable as a chapter: without one,
    // every chapter of the course collides on a single key. Treated as the
    // outline's neighbour rather than as the whole lesson so it can never be
    // served as one.
    return { kind: "chapter", index: chapterIndex ?? -1 };
  }
  return { kind: "whole" };
}

export interface CachedLesson {
  /** The body, replayable verbatim: an SSE stream for the streamed endpoints,
   * a JSON message for the outline. */
  sse: string;
  /** False for the outline, which is a plain JSON response. */
  streaming?: boolean;
  createdAt: number;
  /** What it cost to make, for reporting how much the cache has saved. */
  originalCostUSD: number;
}

/**
 * Thirty days.
 *
 * Set in two places on purpose. The TTL is what stops entries accumulating in
 * KV; the age check on read is what actually enforces the policy, because KV
 * expiry is not instantaneous and an entry can outlive its TTL briefly. Relying
 * on the TTL alone would make "no lesson older than 30 days" true most of the
 * time, which is not the same as true.
 */
export const MAX_CACHE_AGE_DAYS = 30;
export const CACHE_TTL_SECONDS = 60 * 60 * 24 * MAX_CACHE_AGE_DAYS;
export const MAX_CACHE_AGE_MS = CACHE_TTL_SECONDS * 1000;

export async function readCachedLesson(
  kv: KVNamespace,
  key: string,
  now: number,
): Promise<CachedLesson | null> {
  const stored = await kv.get<CachedLesson>(key, "json");
  if (!stored) return null;
  // A missing or nonsensical timestamp is treated as too old rather than as
  // fresh: an entry we cannot date is one we cannot promise anything about.
  if (!Number.isFinite(stored.createdAt) || now - stored.createdAt > MAX_CACHE_AGE_MS) {
    return null;
  }
  return stored;
}

export async function writeCachedLesson(
  kv: KVNamespace,
  key: string,
  entry: CachedLesson,
): Promise<void> {
  await kv.put(key, JSON.stringify(entry), { expirationTtl: CACHE_TTL_SECONDS });
}

/**
 * Replays a cached SSE body as a streaming response.
 *
 * Chunked rather than sent as one blob, because the app's `RevisionGate` holds
 * display until pass 2 covers the opening and drives a progress indicator off
 * arriving deltas. A cached lesson delivered in a single write would jump from
 * nothing to complete, which is a different experience from a generated one
 * for no reason. Small chunks make the two paths feel the same.
 */
export function replayCachedLesson(sse: string, chunkSize = 512): Response {
  const encoder = new TextEncoder();
  let offset = 0;

  const stream = new ReadableStream({
    pull(controller) {
      if (offset >= sse.length) {
        controller.close();
        return;
      }
      controller.enqueue(encoder.encode(sse.slice(offset, offset + chunkSize)));
      offset += chunkSize;
    },
  });

  return new Response(stream, {
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-store",
      "x-accel-buffering": "no",
      // Visible to the client so the app can tell, and so a human debugging a
      // "why is this lesson familiar" report has an answer.
      "x-spare-cache": "hit",
    },
  });
}

/** The outline is JSON, not a stream, so it is replayed as it was stored. */
export function replayCachedJSON(body: string): Response {
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
      "x-spare-cache": "hit",
    },
  });
}
