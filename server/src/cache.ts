/**
 * The lesson cache — the single biggest cost lever.
 *
 * A free user who generates every lesson costs roughly $2/month, and free
 * users ask about overlapping topics. Serving a cached lesson to a free user
 * on a near-identical topic removes almost all of that.
 *
 * KV is the right store here, unlike the counters: it is eventually
 * consistent, and both failure modes are harmless. A stale miss costs one
 * regeneration; a stale hit serves a slightly older lesson. Neither loses
 * money or double-counts anything.
 *
 * The product consequence, stated rather than buried: two free users asking
 * about the same subject get the same words. Premium always generates fresh.
 */

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

export function lessonCacheKey(params: {
  window: string;
  format: string;
  topic: string;
}): string {
  return `lesson:v1:${params.format}:${params.window}:${normaliseTopic(params.topic)}`;
}

export interface CachedLesson {
  /** The SSE body, replayable verbatim. */
  sse: string;
  createdAt: number;
  /** What it cost to make, for reporting how much the cache has saved. */
  originalCostUSD: number;
}

/** Ninety days. Long enough to be worth having, short enough to refresh. */
export const CACHE_TTL_SECONDS = 60 * 60 * 24 * 90;

export async function readCachedLesson(
  kv: KVNamespace,
  key: string,
): Promise<CachedLesson | null> {
  const stored = await kv.get<CachedLesson>(key, "json");
  return stored ?? null;
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
