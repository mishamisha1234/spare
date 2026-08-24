# Spare — tier, caching and duration specification

Replaces the existing free/premium structure, duration set, and cache policy.
Written to be handed to Claude Code as a single change.

---

## 1. The commercial shape

Two content pools, not one.

**Free pool** — generated with `claude-sonnet-5`, cached, served to free users.
**Premium pool** — generated with `claude-opus-5`, cached, served to premium
users and matched to their stated interests.

A premium user may be served a cached premium-pool lesson written for another
premium user with the same interests. That is intended. What premium buys is
the better pool plus interest matching, not authorship.

Cache serving applies to **both** tiers. Generation happens only on a miss.

**The pitch, in the user's words:**

> Free — a lesson a day, 3 or 7 minutes, from Spare's library.
> Premium — lessons written by our most capable model and matched to what
> you're curious about, the 1-minute and 15-minute lengths, the 30-minute
> course, a test after every lesson, and go-deeper on anything.

---

## 2. Durations

Five, replacing the current four.

| Length | Format | Words | Tier |
|---|---|---|---|
| 1 min | One Thing | 200 | **Premium** |
| 3 min | One Thing | 500–650 | Free |
| 7 min | Explainer | 1,100–1,400 | Free |
| 15 min | Lesson | 2,400–3,000 | **Premium** |
| 30 min | Course, 4 chapters | 6,000–6,400 | **Premium** |

The 10-minute window is removed. Existing stored lessons at 10 minutes must
migrate to 7 — add a migration and a test, because a rename that silently
decodes to a wrong default has already nearly shipped once in this project.

### Home screen layout

The 1-minute circle sits **above** the 2×2 grid, as a separate element — it
is a different kind of thing, not a fifth size. Small, roughly 56pt.

The 2×2 grid below holds 3 / 7 / 15 / 30, sized proportionally as now.

Locked circles (1, 15, 30 for free users) use the existing locked treatment:
solid hairline border, lock glyph beneath, no accent fill. They must be
**visible** to free users — a hidden premium length converts nobody, and the
1-minute circle in particular is a conversion hook precisely because "the
shortest one is the paid one" is counterintuitive.

---

## 3. Tests

Question counts, fixed by duration:

| Length | Questions |
|---|---|
| 1 min | 2 |
| 3 min | 3 |
| 7 min | 4 |
| 15 min | 5 |
| 30 min | 10 |

**Premium users get a test on every length, including 3 and 7.**

### The cache constraint — read carefully

A cached lesson carries exactly one attached test. It cannot carry a test for
one tier and not the other, and generating a test per reader would cost more
than the lesson: a 30-minute course read by 200 users at ~$0.20 of test
generation each is $40 of tests on a $1.40 lesson.

The two pools resolve this:

- **Every premium-pool lesson is generated WITH its test**, in the same
  operation, and stored with it. Premium users always have a test because
  their pool always has one.
- **Free-pool lessons are generated without a test.** Free users don't get one.

No per-reader test generation anywhere, at any tier.

### Next-day recall stays free

One recall question the following day, for every user, free and premium. It
is generated with the lesson and cached alongside it, so it costs nothing per
read. It is the mechanism that proves the product works, and a free user who
experiences "I actually remembered that" is the best conversion candidate
there is. Do not gate it.

---

## 4. Cache design

- Cache key includes: topic, duration, **and pool** (free/premium). The pools
  never share entries — different models, different attached artifacts.
- Premium pool entries are additionally tagged with the interest category
  they were generated under, so retrieval can match a reader's stated
  interests.
- A cached lesson is never served twice to the same device.
- Cached entries expire at 30 days for freshness, as already implemented.
- A cache hit consumes the reader's daily allowance exactly as a generation
  does — already decided, keep it.
- On a miss: generate, serve, and write the result into the appropriate pool
  with its test (premium) or without (free).

---

## 5. Pre-launch seed

Generate **150 free-pool lessons** on Sonnet before launch: 3 and 7 minutes,
spread across the interest categories. Roughly $15–20.

Do not pre-generate the premium pool. It fills organically from the first
premium users, and the spend is better made once there's revenue against it.

Be clear about what the seed buys: not cache economics — 150 lessons across
20 categories × 2 durations is under four per combination, and a daily reader
exhausts a category in a week. What it buys is that a day-one user taps a
circle and the lesson is **already there**, rather than streaming in over 90
seconds. First impression, not cost saving.

---

## 6. Word budget enforcement — fix this at the same time

The last batch showed budgets collapsing as duration rises:

    3 min:  6 of 6 in budget
    10 min: 1 of 6 in budget
    15 min: 1 of 5 in budget — 2,644 / 2,051 / 1,753 / 1,555

A 1,555-word lesson sold as 15 minutes is about 8 minutes of reading. Time is
this product's entire promise and it is being broken at exactly the lengths
people pay for.

The cause is the editorial revision — "under-budget and tight beats on-budget
and thin", plus one-argument-per-lesson, plus section caps. The model is
obeying and landing short.

1. Replace that line in `editorialSystemPrompt` with:

   > Do not pad. But the word budget is a promise about the reader's time,
   > not a ceiling to undershoot — a lesson materially under the floor has
   > failed, not succeeded.

2. Make "under the floor" a `LessonQualityCheck` **failure**, not a finding.
   Below 90% of the floor is treated like a truncated generation: not written
   to the cache, not served, retried.

3. One argument per lesson stays. A lesson that can't fill its budget on one
   argument needs more depth — more evidence, more scene, more consequence —
   not a second argument.

4. Leave the section caps. The 15-minute lesson that hit budget used five
   sections; the one at 1,555 words used six and still came up short, so
   sections are not the constraint.

---

## 7. Model routing

- Premium pool lesson generation: `claude-opus-5`
- Premium pool **tests**: `claude-opus-5`, attached at generation. Tests are
  premium-only, so Sonnet never generates one.
- Free pool lesson generation: `claude-sonnet-5`
- **Recall questions**: the same model as the lesson they attach to — Opus for
  premium-pool lessons, Sonnet for free-pool lessons. Recall is free for every
  user (section 3), so *both* pools need one. Keeping recall on the lesson's
  own model matters: a question written by a stronger model than the one that
  wrote the lesson can probe something the lesson never quite establishes,
  producing questions that are fair on the subject but not on the page.
- Topic suggestions: `claude-opus-5` — the call is ~$0.01 and it is where
  personalization actually lives

`claude-haiku-4-5` is **not used anywhere**. Confirmed by blind comparison
across three durations and six topics: all three Haiku lessons contained
confident fabrications, including an invented 1884 act of Congress and an
entirely invented archival document.

Sonnet is accurate but thinner. One factual error across six lessons (it
asserted standard time was "never once put to a vote" when Detroit held a
referendum on precisely that). It therefore needs the **same** quality
checking as Opus, not less — a wrong lesson damages the product whether the
reader paid or not.

---

## 8. Paywall copy

Must be built from `EntitlementRules`, not written out, and pinned by
`PaywallCopyTests` as already implemented. No hedging words. State the caps.

Trigger points: tapping a locked duration (1, 15, 30), requesting a second
lesson in a day, or tapping the locked "Take the test" on a completed lesson.
