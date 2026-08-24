/**
 * What travels with a cached lesson: its recall question, and — in the premium
 * pool — its test.
 *
 * The reason this exists at all is a cost cliff, not a preference. A test is
 * generated *once per lesson*, by whichever device generated the lesson, and
 * stored beside it. Generating one per reader instead would mean a 30-minute
 * course read by two hundred premium users cost roughly $40 in tests on a
 * lesson that cost $1.40 to write. There is no per-reader test generation
 * anywhere, at any tier, and these endpoints are what make that possible.
 *
 * The recall question is different: it is free for every reader, so both pools
 * carry one, written by the same model that wrote the lesson.
 *
 * The bodies here are client-supplied, which the lesson bodies are not — those
 * are Anthropic's own bytes, forwarded. So this is the one path where the pool
 * can be written to directly, and it is guarded twice: only the device that
 * generated the lesson may attach to it, and the shape must match what the
 * length calls for exactly.
 */

import { lessonPoolKey, CACHE_TTL_SECONDS, MAX_CACHE_AGE_MS, type LessonIdentity, type Pool } from "./cache";

/**
 * Questions per test, by length.
 *
 * Mirrors `TimeWindow.testQuestionCount` in SpareCore, the way `TOKEN_CEILINGS`
 * mirrors `AnthropicAPI.maxTokens`. The client is told this number in its
 * prompt and the server checks it here — the check is what makes it a contract
 * rather than a request, and what stops a spoofed client attaching a
 * one-question test to a 30-minute course.
 */
export const TEST_QUESTION_COUNTS: Record<string, number> = {
  one: 2,
  three: 3,
  seven: 4,
  fifteen: 5,
  thirty: 10,
};

/** Generous for ten questions with four options each; nowhere near enough to
 * be worth using as free storage. */
export const MAX_ATTACHMENT_BYTES = 64 * 1024;

export interface StoredAttachments {
  recall: unknown;
  /** Empty in the free pool, which has no test. */
  test: unknown[];
  createdAt: number;
}

export function attachmentsKey(identity: LessonIdentity): string {
  return `${lessonPoolKey(identity)}#attachments`;
}

/**
 * Which device generated this lesson.
 *
 * Written alongside the lesson body, read by `/v1/attach`. It is the whole
 * authorisation model for that endpoint: a device may attach to a lesson it
 * just wrote and to nothing else. Not a strong claim — device ids are
 * spoofable and always have been — but it turns "anyone may overwrite any
 * entry in the pool" into "you must first pay to generate the lesson you want
 * to attach to", which is the difference between a free write and an expensive
 * one.
 */
export function generatorKey(identity: LessonIdentity): string {
  return `${lessonPoolKey(identity)}#generator`;
}

/** One multiple-choice question, as the app's `RecallQuestion` encodes. */
function isQuestion(value: unknown): boolean {
  if (typeof value !== "object" || value === null) return false;
  const question = value as Record<string, unknown>;
  return typeof question.question === "string" && question.question.length > 0
    && typeof question.answer === "string" && question.answer.length > 0
    && typeof question.explanation === "string"
    && Array.isArray(question.distractors)
    && question.distractors.length === 3
    && question.distractors.every((option) => typeof option === "string" && option.length > 0);
}

export type AttachmentCheck =
  | { ok: true; attachments: StoredAttachments }
  | { ok: false; code: string; message: string };

/**
 * Validates an upload against the length it claims to belong to.
 *
 * Hard, and deliberately so. This is the only route by which bytes a client
 * chose reach a pool that other readers are served from, and a wrong-shaped
 * test is not a cosmetic problem: a 30-minute course whose test is two
 * questions is a premium feature quietly failing to be the thing it was sold
 * as, for everyone who reads that lesson for the next thirty days.
 */
export function checkAttachments(
  raw: unknown,
  pool: Pool,
  window: string,
  now: number,
): AttachmentCheck {
  if (typeof raw !== "object" || raw === null) {
    return { ok: false, code: "malformedRequest", message: "No attachments." };
  }
  const input = raw as Record<string, unknown>;

  if (!isQuestion(input.recall)) {
    return { ok: false, code: "malformedAttachment", message: "The recall question is malformed." };
  }

  const expected = pool === "premium" ? TEST_QUESTION_COUNTS[window] : 0;
  if (expected === undefined) {
    return { ok: false, code: "unknownWindow", message: "No such length." };
  }

  const test = input.test;
  if (!Array.isArray(test)) {
    return { ok: false, code: "malformedAttachment", message: "The test is malformed." };
  }
  if (test.length !== expected) {
    // Named in the message because this one is a client bug worth fixing, not
    // an attack: the count is in the prompt the client sent, so a mismatch
    // means the model came back short and the client uploaded it anyway.
    return {
      ok: false,
      code: "wrongQuestionCount",
      message: `A ${window} test carries ${expected} questions, not ${test.length}.`,
    };
  }
  if (!test.every(isQuestion)) {
    return { ok: false, code: "malformedAttachment", message: "A test question is malformed." };
  }

  const attachments: StoredAttachments = {
    recall: input.recall,
    test,
    createdAt: now,
  };
  if (new TextEncoder().encode(JSON.stringify(attachments)).length > MAX_ATTACHMENT_BYTES) {
    return { ok: false, code: "requestTooLarge", message: "That's too large." };
  }
  return { ok: true, attachments };
}

export async function readAttachments(
  kv: KVNamespace,
  identity: LessonIdentity,
  now: number,
): Promise<StoredAttachments | null> {
  const stored = await kv.get<StoredAttachments>(attachmentsKey(identity), "json");
  if (!stored) return null;
  // Same rule as a lesson body: an entry we cannot date is one we cannot
  // promise anything about, and an attachment outliving its lesson would be a
  // test about words nobody can read any more.
  if (!Number.isFinite(stored.createdAt) || now - stored.createdAt > MAX_CACHE_AGE_MS) {
    return null;
  }
  return stored;
}

export async function writeAttachments(
  kv: KVNamespace,
  identity: LessonIdentity,
  attachments: StoredAttachments,
): Promise<void> {
  await kv.put(attachmentsKey(identity), JSON.stringify(attachments), {
    expirationTtl: CACHE_TTL_SECONDS,
  });
}

export async function recordGenerator(
  kv: KVNamespace,
  identity: LessonIdentity,
  deviceId: string,
): Promise<void> {
  await kv.put(generatorKey(identity), deviceId, { expirationTtl: CACHE_TTL_SECONDS });
}

export async function isGenerator(
  kv: KVNamespace,
  identity: LessonIdentity,
  deviceId: string,
): Promise<boolean> {
  const stored = await kv.get(generatorKey(identity), "text");
  return stored !== null && stored === deviceId;
}
