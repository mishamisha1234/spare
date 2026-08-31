# Spare

A time-first micro-learning iOS app. You tell it how long you have — 1, 3, 7, 15, or 30 minutes — and it finds you something worth learning. **Time is the input; topic is the output.** That inversion is the product.

**Status: all six phases complete.** Six screens, live generation, recall and scheduling, points and stats, StoreKit purchasing, widget, export, and an accessibility pass. What remains before this could ship is listed under Known deviations and Before launch.

---

## Repository layout

The codebase is split so that most of it can be compiled and tested without a Mac.

```
SpareCore/     Swift package. Platform-agnostic: no SwiftUI, SwiftData,
               StoreKit, UIKit, WidgetKit, AppIntents. Builds and tests with
               `swift test` on Linux and Windows.
Spare/         The iOS app. SwiftUI, SwiftData, StoreKit, WidgetKit, Keychain.
SpareTests/    iOS-side tests: SwiftData ↔ SpareCore value-type conversion.
```

### What lives in SpareCore

`TimeWindow` and lesson formats · `RecallScheduler` (spaced repetition) · `LessonProvider` + `MockProvider` · all DTOs and JSON coding · `Prompts` (prompt construction) · `Schemas` (structured-output JSON schemas) · `SSEParser` and Anthropic stream decoding · `RevisionGate` (the streaming/revision ordering state machine) · `ReadingTime` (word and reading-time math) · `CostEstimator` · `EntitlementRules` (gating as pure functions) · `SuggestionValidator` · `LessonQualityCheck` · `HTTPTransport` (protocol plus a URLSession implementation).

CI enforces the boundary with a grep check, so an Apple-only import can't quietly land in the package and take the Linux test job with it.

### What lives in the app

SwiftUI screens, the SwiftData `Stored*` models, StoreKit 2, the widget, and Keychain storage for the API key. Each `Stored*` model converts to and from a SpareCore value type (`ProfileSnapshot`, `Lesson`, `RecallQuestion`, `EntitlementSnapshot`, …). **`@Model` classes never cross into generation logic** — Swift 6 strict concurrency forbids it, and value snapshots make provider code testable.

### Cross-platform networking

Any file touching `URLSession` needs the Linux/Windows shim, which CI also checks:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```

---

## The two-pass content pipeline, and the ordering rules

Lessons are generated twice: **pass 1 drafts, pass 2 revises against the editorial rubric.** The second pass is where slop dies, so the reader must never be shown pass-1 output. That constraint drives the whole streaming design, which lives in `RevisionGate` and is enforced by four invariants:

**1. Revision always stays ahead of the reader.** Lead is measured in words and reported as `Pacing`: `.ahead`, `.tight` (inside the 150-word minimum), `.starved` (the reader has reached the end of revised text), or `.complete`. A starved reader gets a waiting state — never unrevised prose.

**2. Display is held until revision covers the opening.** Nothing renders until pass 2 has produced roughly 250 words, or has finished outright for a body shorter than that. `holdProgress` drives a determinate indicator so the wait is legible rather than a spinner.

**3. Chaptered formats work one chapter ahead.** For the 30-minute course, while the reader is in chapter N, chapter N+1 is being **drafted and revised**. `nextChapterToGenerate` prioritises any chapter at or behind the reader over prefetching, so the reader's own chapter is never the one that's missing.

**4. Text already shown is immutable.** Displayed text only ever grows, and only by appending. A candidate update that would rewrite shown text is **rejected and counted** (`appendOnlyViolations`) rather than applied — so "never mutate text already scrolled past" is structural, not aspirational.

Because the reader is looking at pass-2 output as it streams, the revision prompt is explicitly told to revise front-to-back and never reorder sections.

The earlier design — stream the draft immediately, swap in the revision later — was **wrong** and has been removed: it showed every first-time reader unrevised output, which defeats the point of paying for two passes.

---

## A failed read is not an answer

**Anywhere the app cannot reach the proxy, it shows nothing — not a default, not a last-known value dressed up as fresh, and above all not a state nobody reported.** A lookup that failed carries no information, and encoding it as one is how a screen ends up making a confident claim out of a network error.

This is a standing rule because it was broken, in the worst available way. `TrialStore.status()` used to answer `TrialMirror.unavailable`, defined as `status: .ended`, on any failure — reasoned at the time as "the free tier is the state that always works". It is not a neutral state: `.ended` is the one that fires the day-7 summary. So on any launch with no network — a plane, a captive portal, a Worker that predated the endpoint — a reader who had never had a trial was shown *"Your week with Premium"*, and because there was no `startedAt` to count from, the summary totalled their entire library and presented it as that week. Plausible, specific, and invented.

The shape of the fix, which is the shape to copy:

- The store returns `TrialMirror?`. Nil means "I could not ask", which is different from every answer the server can give.
- `refreshTrial()` applies only a non-nil answer. A failed read leaves the cached mirror exactly as it was.
- An unrecognised status **throws** rather than falling back, so an unparseable answer becomes nil too.
- `hasEnded` requires `startedAt != nil`. A trial that ended has a start; anything else is noise that reached the property.
- Server side, `readTrial` and `readFunnel` return null rather than a manufactured `ended` or five zeros, and `/v1/trial/status` answers 503 rather than inventing a state.

### Every other place a failed read could become a state

Audited in full when the rule was written. Nothing else in this class is outstanding.

| Site | Behaviour | Verdict |
|---|---|---|
| `hasSeenLesson` catch → `true` | Falls through to generation | **Kept.** Costs a regeneration and serves a correct lesson; the failure is money, not a false statement to the reader. |
| `readCourseGrant` catch → `null` | No grant, so refuse | **Kept.** Fail-closed: denies rather than grants. |
| `bumpFunnelNow` / `recordConversion` catch → nothing | A dropped counter | **Kept.** A slightly wrong marketing number, never a reader-visible failure. |
| `verifyEntitlement` failure → 503 | Retryable, no downgrade | **Kept.** This is the good example — it refuses to answer rather than answering "free". |
| `isCompleteMessage`, `upstreamErrorType`, `bodyWordCount`, `decodeUnverifiedPayload` catches | `false` / `"unreadable"` / `null` | **Kept.** Parse failures of a body we already hold, reported as the absences they are. |
| `StoredEntitlement.tier` → `?? .free` on an unknown raw value | Downgrade | **Kept, with a legacy map and a test.** Not a failed read — a stored value this build cannot interpret — and granting on an unknown tier is the worse direction to be wrong in. |
| `loadCachedSnapshot` → `?? .free`, `trialJSON` → `?? .eligible` | Empty store reads as a fresh install | **Kept.** A genuine absence: nothing has been written yet. Neither grants anything. |

---

## Requirements

- **SpareCore:** any Swift 6 toolchain (Linux, macOS, Windows).
- **iOS app:** macOS with Xcode 16+, plus Homebrew for XcodeGen.

## Building and testing

Core, anywhere:

```bash
swift test --package-path SpareCore
```

iOS app, on macOS:

```bash
./bootstrap.sh
```

```bash
xcodebuild test -project Spare.xcodeproj -scheme Spare -destination 'platform=iOS Simulator,name=iPhone 16'
```

`Spare.xcodeproj` is generated and gitignored. Edit `project.yml` and re-run `xcodegen generate`; never edit the project file directly. `xcrun simctl list devices available` shows which simulators you can target.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and on manual dispatch:

- **`core`** — ubuntu-latest in a `swift:6.1` container: the banned-import check, the FoundationNetworking guard check, the persisted-key check, then `swift build` and `swift test`.

The persisted-key check is worth naming, because it exists for a class of bug rather than an instance. `AppSettingsKey` is a `CaseIterable` enum and `-UITEST_RESET_STATE` clears `allCases`, so a declared key is resettable by construction. The guard is the other half: `@AppStorage("…")` and `forKey: "…"` string literals are banned in the app target, and every `forKey:` must name the registry — so a key cannot be persisted that the reset does not know about, by literal or by indirection. `DeviceIdentity` is the one exclusion, and deliberately: its identifier is not a preference, and clearing it would hand every UI-test launch a new device and a fresh free allowance.

It is a grep and not a Swift test because nothing can enumerate every `@AppStorage` key in a module at runtime — `AppStorage` does not expose its key, and `Mirror` would need an instance of every view that declares one. `AppSettingsKeyTests` proves the half that is testable: reset clears everything the registry declares. What made both necessary: the trial's four flags went straight into `@AppStorage` and never reached the then-hand-written reset list, so the second and third launches of a UI test ran on the first one's leftovers, and it surfaced as three unrelated-looking flakes.
- **`ios`** — macos-latest, gated on `core` passing: prints `xcrun simctl list devices available`, installs XcodeGen, generates the project, resolves a real simulator UDID from the runner's device list, and runs `xcodebuild test`. The `.xcresult` bundle is uploaded on failure as well as success.

---

## Notes on the generation layer

- **Model:** `claude-opus-5`, pinned in `AnthropicAPI.model`. Lesson quality is the product, so this is the most capable generally available model rather than the cheapest.
- **Structured outputs** (`output_config.format` with a JSON schema) constrain suggestions, outlines, chapters, and recall questions. Malformed JSON stops being a failure mode; counts and word limits are then enforced by `SuggestionValidator`.
- **No assistant prefill, no `temperature`/`top_p`/`top_k`, no `thinking.budget_tokens`** — all rejected on current models. `AnthropicWireTests` asserts the request body never contains them.
- **Validation is layered:** prompts ask, schemas constrain, `SuggestionValidator` and `LessonQualityCheck` verify. Quality findings are advisory — they can trigger one retry but never block a lesson from being read.

### Streaming a structured output

Structured outputs and progressive display pull in opposite directions: the model returns one JSON object, but the reader needs `bodyMarkdown` on screen while the rest of that object is still arriving. `StreamingJSONFieldExtractor` resolves it — a minimal streaming JSON scanner that decodes one top-level string field as its characters land, unescaping (including `\uXXXX` and surrogate pairs) on the way. It tracks nesting depth and key/value position rather than searching for a substring, so a field name appearing inside another value can't false-positive.

### Prompt caching

Prompt text lives entirely in [`Prompts.swift`](SpareCore/Sources/SpareCore/Prompts.swift) as plain constants with `{{placeholder}}` tokens — no Swift interpolation inside prompt bodies, so wording can be rewritten without touching code.

They come in two kinds, and the split is what makes caching work:

- **`*SystemPrompt`** — byte-identical on every call (the editorial rules, the revision checklist, the suggestion rules). Sent as the system block with `cache_control: ephemeral`, so after the first call this bulk is billed at cache-read rates.
- **`*TaskTemplate`** — the per-call detail (topic, budget, reader context). Sent as the user message, *after* the cached prefix.

A test asserts the system prompts contain no placeholders, because one byte of per-lesson detail leaking into that prefix silently destroys caching on every subsequent call.

### Two content pools

**Free pool** — written by `claude-sonnet-5`, cached, served to free readers.
**Premium pool** — written by `claude-opus-5`, cached, tagged with the interest
category it was generated under, and served to premium readers.

The pools never share an entry: different models, different attached artifacts,
different readers. Both tiers read the cache, and generation happens only on a
miss. A premium reader may well be served a lesson written for another premium
reader with the same interests — what premium buys is the better pool plus
interest matching, not authorship.

Which pool a request belongs to is decided by the entitlement the server
verified with Apple, never by anything the client said. The model follows from
the pool and **overwrites** whatever the client named. Overwrites rather than
refuses: a 400 saying "you may not ask for Opus" names the boundary for anyone
probing it and breaks every reader on a stale build the day the pool models
change, whereas a perfectly good Sonnet lesson says nothing at all. The one
exception is the operator batch tool, which names its own model because
comparing models is why it exists.

`claude-haiku-4-5` is on no path and is not on the allowlist. A blind comparison
across three durations and six topics found confident fabrications in all three
of its lessons, including an invented 1884 act of Congress and an entirely
invented archival document.

**What the pre-launch seed does and does not buy.** The 150-lesson seed is
Sonnet-written and therefore lands in the **free** pool only, at 3 and 7
minutes. Premium readers get nothing from it. Every premium miss — including a
premium reader picking the 3-minute circle, which the free pool has covered —
is an Opus lesson plus an Opus test plus an Opus recall question, generated
fresh. That is the intended shape, but it means the first month's spend will
not look like the seed cost suggests, and the premium pool fills at premium
prices from the first paying reader.

### Tests and recall questions travel with the lesson

A lesson is written once and read by many people, so its recall question and
its test are properties of the lesson, not of the reader. Both are generated
once — by whichever device generated the lesson — and stored beside it via
`POST /v1/attach`; every later reader gets them from `POST /v1/attachments`,
which generates nothing, ever.

This is a cost cliff rather than a preference. A 30-minute course read by two
hundred premium users, at roughly $0.20 of test generation each, would be $40
of tests on a lesson that cost $1.40 to write. `PostLessonTestViewModel` holds
no provider at all for the same reason: a screen with a provider on it is a
screen that can grow a "generate one" path.

`/v1/attach` is the only route by which bytes a client chose reach a pool other
readers are served from — lesson bodies are Anthropic's own, forwarded — so it
is guarded twice: only the device recorded as the lesson's generator may write,
and the test's question count must match the length exactly (2/3/4/5/10 by
duration). A course's test attaches when the reader finishes it; one who stops
at chapter two leaves none behind, which is correct — they have not finished.

The recall question is not gated. It is free for every reader, both pools carry
one, and it is written by the same model that wrote the lesson: a question from
a stronger model than the lesson's can probe something the text never quite
establishes, which is fair on the subject and unfair on the page.

### Cost control

A 30-minute course is an outline call plus two calls per chapter — 9 requests if fully generated. Three things keep that honest:

1. **Lazy chapters.** Generation blocks on `ChapterDemand` before each chapter. The Reader advances it as the reader scrolls, so a reader who stops at chapter 2 triggers 5 calls, not 13. Leaving the Reader cancels the stream outright.
2. **Cached prefix**, above.
3. **`UsageLedger`.** Every call — success *or* billed failure — writes token counts and an estimated cost, surfaced as a running monthly total in Settings.

### Retry rules

Retryable: network drops, 429, 5xx, truncated streams, malformed JSON. Not retryable: refusals (a decision, not a glitch) and auth failures.

Two checks can spend a retry: a pass under the word floor, and a pass carrying the negated-scope pivot (`LessonQualityCheck.negatedScopePivot`). They share **one** counter, `Configuration.qualityRetries`, rather than getting one each. That is a hard constraint, not tidiness: a budget apiece would put a 30-minute course's worst case at 1 outline + 4 chapters x (3 drafts + 3 revisions) = 25 calls, past `MAX_REQUESTS_PER_LESSON`'s 24, turning a style problem into a 402 halfway through chapter three. Shared, the worst case stays at the 17 that bound was raised to cover.

Because they share, a construction retry rolls the word count again and could hand back something shorter. So attempts are ranked and the floor dominates: a pass that met the floor beats one that merely avoids the construction. The construction check can never make length worse than it found it. On exhaustion the floor still blocks and the construction never does — a lesson carrying it is still a lesson.

One rule is subtler: **a revision pass is never retried once it has emitted text.** Those deltas are already on the reader's screen, and `RevisionGate` is append-only — re-running the pass would append a second copy rather than replace the first. Draft passes, which are never displayed, retry freely.

## API key handling

Lessons are generated by calling the Anthropic API **directly from the device**. This is a deliberate v1 tradeoff with a real risk: a key on a device is extractable by someone with that device.

The key is never hardcoded, never in `Info.plist`, never in `UserDefaults`, never committed. It is entered in Settings and stored in the **Keychain** with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — deliberately *not* synced to iCloud Keychain, since a key that syncs is a key on more devices than the user thinks. `.gitignore` guards against accidental commits, and CI greps for key-shaped strings.

With no key stored, `KeyGatedProvider` routes to `MockProvider`, so the app runs end to end offline rather than showing an error.

**Migration path off it:** every call goes through `LessonProvider`, and every byte over the wire goes through `HTTPTransport`. Moving to a server proxy is one new conformance plus one line at the injection site in `SpareApp`.

## Testing policy: CI never calls the real API

There is no API key in CI secrets, and no CI job makes a real request. Not for cost, and not only for flakiness — a key in CI is a key in a place nobody is watching.

Everything is driven from recorded wire fixtures in [`HTTPFixtures.swift`](SpareCore/Tests/SpareCoreTests/HTTPFixtures.swift), replayed through a `FixtureTransport` that also counts requests. Covered: success, truncated stream, malformed JSON, rate limit, network drop, refusal, auth failure, and mid-stream drop after emission. Request *counts* are asserted too, because "generated chapters nobody asked for" is a cost bug that produces perfectly correct-looking output.

Verification against the real API is a manual step on a Mac with a key in Settings.

## Recall, points, and the share card

**Recall.** A `RecallQuestion` is generated once, at lesson completion, and stored as a `StoredRecallItem` with its own schedule (`RecallScheduler`'s five-stage spaced-repetition curve). Home shows at most one due item per app session — pinned in local `@State` the first time Home appears, so answering it (or a new item becoming due mid-session) never bumps a second card in front of the reader. Answering is immediate: tap, see the right answer and the stored explanation right there, no round trip.

**Points.** [`Points.swift`](SpareCore/Sources/SpareCore/Points.swift) is the one rule: retention outweighs consumption. A finished lesson earns 10/20/30/60 by length; a correctly answered recall question earns a flat 30, the same whether it followed a 3-minute piece or a 30-minute course. [`PointsLedger.swift`](SpareCore/Sources/SpareCore/PointsLedger.swift) logs *every* recall attempt, correct or not, at 0 points when wrong — so retention rate, and anything else a future feature wants from the full history, is always computable from the ledger itself rather than a separately maintained counter. [`Level.swift`](SpareCore/Sources/SpareCore/Level.swift) turns cumulative points into a level on a square-root curve: each additional level costs meaningfully more than the last. [`Achievement.swift`](SpareCore/Sources/SpareCore/Achievement.swift) evaluates counts, breadth (all 24 canonical domains), depth (mini-courses), retention, and consistency (distinct active days, not an unbroken streak) as pure functions over the ledger and the library — nothing is ever "awarded" and stored.

Every screen respects one aesthetic rule: no confetti, no trophy icons, no badges, no mascots, no "on fire" copy. Achievements are a single quiet line of text in Library. Points live on the Stats screen the user chooses to visit, never a counter shown elsewhere.

**Post-lesson test.** Premium users can take an immediate, optional 3-question test right after a lesson, in addition to the single next-day recall question. It's a separate structured-output call (`generatePostLessonTest`, one request for all 3 questions) and, unlike the daily item, entirely ephemeral — answered on the spot, nothing persisted as a schedule.

**Notifications.** One local notification, naming the specific lesson ("You read about *{title}*. One question."), at a Settings-configurable time, fired only on a day something is actually due. This is a locally computed schedule-ahead approximation, not a live check-at-fire-time system: [`NotificationScheduler.swift`](Spare/Recall/NotificationScheduler.swift) cancels and re-schedules the single pending request whenever recall state changes or the app returns to the foreground, rather than verifying freshness at the moment of delivery. A fully exact system would need either a server or a Notification Service Extension; both are out of scope for this offline-first v1. In the ordinary flow this doesn't bite — answering a recall item requires opening the app, which is exactly when the schedule gets recomputed.

**Share card.** `ShareCardView` renders at a fixed 9:16 size via `ImageRenderer`, always against the theme's dark palette regardless of the app's own appearance setting — this is an artifact meant to travel outside the app, not a themed screen. Tapping Share on Stats renders it into a preview sheet with a native `ShareLink` — that preview step is also the only way this screen is reviewable from CI, since a rendered bitmap has no view hierarchy of its own to screenshot otherwise.

## Entitlements and purchasing

**One gate, one place.** `EntitlementService` is the only thing in the app that answers "is this allowed?". Views never read a tier and never call `EntitlementRules` themselves — they ask for an `AccessDecision` and render it. A grep for `EntitlementRules` or `StoredEntitlement` outside that service returns nothing but its own persistence.

**A fair-use cap is not a paywall, and the types enforce that.** `AccessDecision` has three cases: `allowed`, `denied(PaywallTrigger)`, and `capped(UsageCap)`. The 12-courses-a-month limit applies to people who already pay, so it returns `capped`, and `capped.trigger` is `nil`. "Route any denial to the paywall" therefore cannot be written by accident — a subscriber at the limit gets a plain explanation and the reset date. A test asserts this specific property.

**Free** is 1 lesson/day, the 3- and 7-minute lengths, no go-deeper, no post-lesson test. **Premium** is every length, unlimited go-deeper, and post-lesson tests, with 50 lessons a month of which up to 8 may be mini-courses. The remaining count appears on the paywall and in Settings before the cap bites. The library is uncapped on both: free limits how many new entries arrive, not how much of your own library you may read back. It used to show free readers only their last 10 entries — that cap is gone, and not only for the obvious reason. The selling model is loss aversion at the end of a free week, so truncating the library at the moment the trial ends would take away the thing the reader is being asked to keep.

Locked premium features render as **visibly locked rows that open the paywall**, never hidden — a feature nobody can see sells nothing. Home's duration circles carry a lock glyph *beneath* the circle rather than inside it, so size stays the only thing meaning anything within the circle itself and the state is still legible before the tap. The 1-minute circle matters most here: it is premium, it sits above the grid on its own, and "the shortest one is the paid one" is counterintuitive enough to be the conversion hook. Hiding it would convert nobody.

**Free-tier counting is local and therefore spoofable.** Accepted for v1, with no anti-tamper by design; it moves server-side later.

### StoreKit

`Transaction.currentEntitlements` is the authority on what someone owns — already OS-validated, already excluding expired and refunded purchases, and it survives a reinstall without a restore. The tier cached in SwiftData exists only so a cold launch knows the answer before StoreKit replies. `ProductCatalog.resolvedTier` takes the *strongest* of several owned identifiers, because an annual subscriber who previously paid monthly still has that transaction in `currentEntitlements` until it lapses and must not be downgraded. The withdrawn lifetime identifier still resolves, to yearly: Apple's records are not ours to edit, and answering "free" to somebody holding a transaction is wrong in the direction that takes something away.

Purchases go through a `PurchaseStore` protocol, the same shape as `LessonProvider`: `StoreKitPurchaseStore` for real, `StubPurchaseStore` for UI tests and previews. CI screenshots the entire paywall and purchase flow with **no StoreKit configuration, no sandbox account, and no way to trigger a real charge**. `Products.storekit` is wired into the scheme's run action for local testing on a Mac only.

### Paywall

Priced claims are computed from the two real StoreKit prices, never hardcoded: `PricingSummary` derives the per-month equivalent and the saving percentage, **rounds the saving down**, and returns nothing at all when there is no honest claim to make (no baseline, yearly not actually cheaper, under 1%). An overstated saving is a false advertisement, not a rounding bug.

No countdown, no "limited time", no strike-through on a price that was never charged, no framing that implies the reader is failing at something. The screen is built entirely from `Theme` — every colour, font, radius, and spacing value — because a paywall that looks like a different app is the usual tell that the design system was abandoned exactly where it mattered.

## Widget, export, accessibility

**Widget.** Small and lock-screen show the duration picker (or a course's resume position); medium shows the finished-lesson count. Both read the app's SwiftData store through an App Group.

The group identifier lives in [one file compiled into both targets](Shared/AppGroup.swift) and both entitlements name it, so the app and the extension can't drift apart by a typo. Two consequences are handled rather than assumed:

- `containerURL` is `nil` whenever the entitlement isn't in effect — which includes every unsigned build, so CI. The store falls back to the app's own container so the app keeps working, and the widget renders *"Open Spare once to set this up"* rather than a `0`. An unreachable store is a claim about the app; a zero is a claim about the reader.
- Moving the store into the group container would otherwise silently empty every existing library. `migrateLegacyStoreIfNeeded` copies the old store across on first launch, including the `-wal` and `-shm` sidecars, which have to travel or the copy opens as corrupt.

Widget taps are URLs, not App Intents: opening the app at a destination is what a URL does, and it survives the widget process being terminated between render and tap. The app re-checks the destination against the live entitlement rather than trusting it, since a timeline can be an hour stale — someone who bought Premium since the last refresh gets their lesson, not a paywall for something they own.

**Export.** The whole library as one Markdown file via the share sheet. It exports everything, not the free-tier-visible slice: the 10-entry cap hides entries, it doesn't unmake them, and an export that silently dropped older lessons would be a data-loss trap dressed as a limit. Shared as a real `.md` file rather than a string, because "Save to Files" and "Open in…" are the point.

**Accessibility.** Controls use `minHeight`, so they grow with their text. At `.isAccessibilitySize` Home swaps its circles for full-width rows — two 160pt circles already fill the screen, so they cannot grow, and size-as-meaning does not survive an accessibility text size; a legible list beats an illegible diagram. Identifiers and spoken labels are identical in both layouts. The share card is pinned to `.large` because it is a fixed 9:16 artifact leaving the app, not a screen being read.

Contrast is **measured, not eyeballed** — [`ThemeContrastTests`](SpareTests/ThemeContrastTests.swift) recomputes every pair from the palette, so a future tweak fails a test rather than reaching a screenshot. That check found a real defect: light mode's amber was 3.03:1 and its secondary text 3.53:1, both below the 4.5:1 AA needs for body-size text and both in use at body size. Darkened along the same hue to `0xA06525` and `0x78716A`. Dark mode already passed everywhere.

**Empty and error states** come from one place. [`ProviderErrorCopy`](SpareCore/Sources/SpareCore/ProviderErrorCopy.swift) maps each `LessonProviderError` to a title, a message, whether retrying could help, and whether the fix is in Settings. Before it, three screens each had their own "Couldn't load…" string and being offline read identically to being rate limited — which matters, since one resolves by reconnecting and the other by waiting. "Try again" is offered only where it can work: an action that cannot help implies the failure is the reader's for not trying hard enough. A test asserts the copy's retryability agrees with the provider's own retry policy.

## Known deviations

- **A rejected lesson can stay in the pool for thirty days.** The pivot check runs on the device; the server knows nothing about it. The server caches on its own criteria — complete, final pass, at or above `hardWordFloor` — so when a first attempt carries the construction but is long enough, it is written to the pool and marked seen. If the retry then comes back clean *but under the server's floor*, the server declines to overwrite, and the pool keeps the pivot-carrying first attempt while the reader who triggered the retry sees the clean one. Every other reader asking that question gets the rejected version for the next thirty days.

  Not a key collision: `cacheKey` is derived from pool, window, format, topic and interest, none of which a regeneration changes, so the retry writes to exactly the same key. It is a *write-policy* divergence — the client and the server disagree about what "good enough to cache" means, and the server owns the pool. Ranking makes it rarer, since the floor-passing attempt usually wins, but does not remove it.

  Fixing it properly means teaching the server the same check, which duplicates an editorial rule across Swift and TypeScript — the thing `policy.ts` exists to avoid. Documented rather than fixed.

  Worth knowing that one accident holds this together: `markSeen` runs on the same condition as the cache write, and `handleGeneration` suppresses a hit for a device that has already seen the entry. Without that, a retry would be served the cached first attempt straight back and the whole gate would be a no-op. It is load-bearing for a reason it was not built for.

- **Toolbar button shadow — confirmed unfixable without abandoning `.toolbar`.** Toolbar items render with a soft shadow under a circular background the theme doesn't specify. Three fixes were tried and verified against CI screenshots, and all three left it unchanged:
  1. `.buttonStyle(.plain)` on the buttons — it isn't button styling.
  2. `.toolbarBackground(.hidden, for: .navigationBar)` — it isn't the bar background.
  3. `NavigationBarChrome.flatten()`: a `UINavigationBarAppearance` with a transparent background and cleared `shadowColor`/`shadowImage`, applied to `standardAppearance`, `scrollEdgeAppearance`, `compactAppearance`, and `compactScrollEdgeAppearance`.

  That eliminates the bar as the source: it is iOS 26's per-item "glass" treatment on toolbar buttons, which has no SwiftUI-level override. Removing it would mean hand-rolling a header row instead of `.toolbar`, giving up native back-swipe and VoiceOver behaviour to delete a shadow. Not worth it. Both fixes are kept anyway — they're harmless and correct in intent.

  **Accepted permanently for navigation toolbars.** A design review asked for the chips and shadows to go, on the strength of the project's own "no shadows" rule. That rule was written before iOS 26 rendered toolbar items with glass chrome, and the only way to honour it now is to give up swipe-back and the stack's VoiceOver semantics for a cosmetic gain. The rule yields here.

  **But not for sheets.** A sheet's Close button carries no navigation semantics — no back gesture, no stack behind it — so it was never buying anything from `ToolbarItem`. The Paywall and Share card sheets now render their own header row with a plain `Button`, fully styled from `Theme`. This is the exception to the "don't hand-roll chrome" rule, and it is narrow on purpose: the moment a control has real navigation behaviour attached to it, it goes back in the toolbar.

- **Notification scheduling is schedule-ahead, not verified-at-fire-time. Fix before launch.** See "Notifications" above. A notification that fires for an already-answered item is a real bug, not a cosmetic one; it just can't be fully closed without either a server or a Notification Service Extension. This doesn't arise in the ordinary flow, since answering a recall item requires opening the app, which is exactly when the schedule gets recomputed — but it is not the guarantee a verified push would give, and it is on the pre-launch list rather than accepted permanently.

- **`light.textOnAccent` clears WCAG AA by 0.02, and that is the whole margin.** Near-white `#FAF8F5` on the light accent `#A06525` measures **4.5199:1** against the 4.5 threshold the 17pt button labels need. It passes, but nothing about that is comfortable — **any change to the light accent almost certainly breaks it**, and `ThemeContrastTests.testTightestPairStillClearsAA` exists to fail loudly when it does.

  **The underlying cause is that the accent does double duty.** It is both a fill colour (button backgrounds, the in-progress course circle, share-card numerals) and a text colour on the page (the "View the lesson" link). Those pull in opposite directions: a fill wants to be light enough for dark ink, text-on-background wants to be dark enough to read. The one amber has to sit where both are barely satisfied, which is why the margin is 0.02 rather than comfortable. If this ever needs real headroom, the fix is to stop using the accent as a text colour — then it can lighten and take dark ink cleanly. That is a larger change than a token swap and has not been made.

  Recorded because a design review proposed the opposite fix and its arithmetic was right about a palette that no longer exists. Flipping the ink to `#1A1A1A` gives 5.41:1 against `#C87F2E`, the accent at the time those screenshots were taken; against the current `#A06525` it gives **3.63:1**, which is worse than what is already there. The two goals cannot both be met by one accent — dark ink on the accent needs luminance ≥ 0.223, the accent used as text on the background needs ≤ 0.172 — so the choice is which side to satisfy, and keeping the ink light satisfies both at 4.52. A second test asserts the dark-ink alternative still fails, so it can't be re-applied from the review document later without someone noticing.

- **The recall reminder's time picker is a system `DatePicker(.compact)`.** Its popover chrome can't be re-themed any further than a `.tint()` — same accepted-platform-chrome category as the toolbar shadow above, not worth hand-rolling a custom time wheel to fully theme.

- ~~"Take the test" is hidden entirely for free-tier users~~ — **fixed in Phase 5.** It is now a visibly locked row that opens the paywall, along with go-deeper.

## Before launch

Things this codebase cannot verify about itself, and which need a signed run on a Mac or a decision:

1. **The App Group has never actually been exercised.** Entitlements aren't applied to unsigned builds, so CI proves the widget compiles and its views render, not that it can read the app's store. This is the single most likely thing to be quietly broken.
2. **The store migration has never run against a real pre-App-Group store.** Same reason. Worth testing with a populated library before shipping, because the failure mode is someone's whole library appearing to vanish.
3. **Notification fire-time verification** (see Known deviations) — a notification firing for an already-answered item is a real bug.
4. **Prompt quality has been measured once.** Every provider test runs against recorded fixtures; `spare-batch` (below) is the only thing that puts the real prompts in front of the real API. The first batch of twelve produced a full editorial read, and the rules that came out of it are in `Prompts.swift` now. What is not yet known is whether they worked — the second batch is the check. Read the output before deciding the prompts are done.
5. **StoreKit has only run against `StubPurchaseStore`.** The real purchase, restore, and lapse paths need a sandbox account.
6. **Month one will cost more than the seed estimate implies.** Every trialist is a premium-pool generator for a week: the trial routes to Opus, and the 150-lesson Sonnet seed does nothing for them. The premium pool fills from whoever reads first, so the cost curve is front-loaded and the seed's arithmetic describes the free tier only. The trial's own ceiling bounds a single device near $8; the global monthly spend ceiling is what bounds the month, and a trialist stops at it because `isPaying("trialing")` is false.
7. **A device reset is worth ~$8 to a reader and far more to an attacker.** The device identifier is a UUID in app-group storage, deliberately not the Keychain, so a delete-and-reinstall gets a fresh trial. That was already true of the free tier; the trial raises what it is worth. The reverse trial also makes reinstalling more costly to the reader — they lose the library the whole pitch is built on wanting to keep. The $8 is what an enthusiastic trialist costs, not what a scripted device costs: ten charge keys at `MAX_REQUESTS_PER_LESSON` each is 240 upstream calls, and at a lesson's 24,000-token Opus ceiling that is roughly $144. The spend ceiling is the backstop either way, and it is a budget rather than an abuse control — see "what a fake device is worth" in `server/README.md`.
8. **Before the first TestFlight install, the pre-release gate has to be replaced by real controls.** `SPARE_CLIENT_TOKEN` is what keeps the proxy closed while no client exists, and it stops working the moment a binary is in somebody's hands. Cloudflare rate limiting on the Worker's route, and an admission-controlled spend ceiling that reserves before generating rather than recording afterwards, both need to land before that date. The list is in `server/DEPLOY.md`.
9. **The introductory offer has only been seen through `StubPurchaseStore`.** `isEligibleForIntroOffer` is a real network-backed lookup against the subscription group, and the stub always answers yes. What a *returning* subscriber sees — the standard £89.00 with no first-year claim anywhere on the sheet — has never been rendered on a device.

## Judging the prompts: `spare-batch`

An executable target in the SpareCore package that generates a batch of lessons
through `ProxyProvider` and writes each to markdown, with words against budget,
`LessonQualityCheck` findings, and real cost per lesson.

It drives the actual pipeline, so it uses `Prompts.swift`, both passes, the real
word budgets, and the chaptered path for a 30-minute course. That is the whole
point: a script that sends its own prompt measures tokens honestly and says
nothing about the writing.

There is no Swift toolchain on the Windows machine this is developed on, so it
runs as a manually dispatched Actions job:

```
gh workflow run "Lesson batch" -f confirm=spend
gh workflow run "Lesson batch" -f confirm=spend -f only=three   # cheap trial
```

Or **Actions → Lesson batch → Run workflow** in the browser. Lessons come back as
the `lessons` artifact: one `.md` per lesson, `summary.csv`, and `batch-log.txt`.

Needs two repository secrets, `SPARE_PROXY_URL` and `SPARE_ADMIN_TOKEN` (the
Worker's `ADMIN_TOKEN`), and the typed confirmation. It is the only workflow here
that makes real API calls or spends money, which is why it is a separate file
from `ci.yml` and cannot be triggered by a commit.

It also needs the Worker to be **current**. The 30-minute lengths call
`/v1/outline`, which only exists after a redeploy; against an older Worker they
fail with a 404 and the run stops before spending anything, which is the
intended behaviour rather than a bug to work around.

Roughly $3 and half an hour for all eight. Two passes per lesson doubles the
obvious cost, and a course is an outline plus four chapters twice over.

### Comparing models blind

Naming more than one model runs the same topics through each of them and blinds
the output:

```
gh workflow run "Lesson batch" -f confirm=spend   -f model=claude-opus-5,claude-sonnet-5   -f per_window=1
```

Leave `per_window` blank for the full set: ten topics through two models is
twenty lessons, roughly $9 and about two hours. `-f per_window=1` cuts it to one
topic per length — ten lessons, roughly $3 — for a cheaper look. Only the two
models on the server's allowlist can be named; Haiku was removed from it for
fabricating, so the comparison cannot quietly include it again.

The lesson files are named by a random six-character id and carry no model, no
cost, and no timing. Runs are shuffled and the log names lessons by id too,
because watching the run is the normal way to use this and a log grouped by
model gives the answer away before a file is opened. Everything withheld is in
`KEY-open-after-reading.md`, alongside a per-model summary.

Cost and elapsed time are withheld rather than dropped for a specific reason:
they identify a model on sight. Haiku is a twentieth of Opus per token and
several times faster, so one glance at a cost figure ends the blind. The
markdown keeps words against budget and the quality findings, which is what
there is to judge.

The blind is enforced by a scatter of conditionals in the writer and cannot be
unit-tested — `spare-batch` is an executable target, so none of it is
importable. Instead the tool reads its own output back at the end of a run and
says so loudly if any lesson file names a model.

One caveat the key file repeats: Claude 4.7 and later use a newer tokenizer that
produces roughly 30% more tokens for the same text. The dollar figures are exact,
because each model is priced at its own published rate against its own reported
usage, but token *counts* compared across models are not comparing like with
like.

### What the first batch changed

Twelve lessons, read as a commissioning editor would read them. The prose was
publishable; the problems were structural, and three of them were tics visible
only across a batch:

- **Every lesson ended the same way**, eight of twelve opening the last
  paragraph with "Next time you…". Now banned in the prompt and on the
  hard-banned list, and `LessonQualityCheck` reads the closing paragraph for it.
- **Eight of twelve built their central analogy out of the reader's own field**,
  because the test profile says logistics. The reader context now says to use it
  sparingly and never twice running.
- **The same pivot phrasing** recurred across unrelated subjects. On the
  advisory list, for the revision pass to judge.

Six structural rules came out of the same read: one argument per lesson with a
second good one demoted to a deeper angle, a section ceiling, analogies capped
at a paragraph, no displayed arithmetic, real space for a named person's fate,
one adjacent thing left unexplained, and a subtitle forbidden from carrying the
surprising claim. Four of those are mechanically checkable and are now findings;
the rest are prompt rules the revision pass has to enforce by judgement.

The second batch is eight fresh subjects, two per length, against the same
reader profile — same profile deliberately, since whether the analogies still
all come from freight is one of the things being tested.

### What the probe rounds did and did not show

Between the first batch and the pivot gate, eight rounds of six lessons each were
run against the live proxy, each changing one thing in the editorial prompt and
each read as evidence that the change had worked or backfired. Most of that
reading was wrong, and the way it went wrong is worth keeping.

The negated-scope pivot appeared in 26 of 57 generated lessons — **about 46%,
95% CI [33%, 58%]**. Round-by-round the counts were 4, 5, 1, 2, 2, 3, 5 out of
six, and each movement got an explanation: the ban failed, the rotation worked,
the confidence-calibration edit regressed it. A dispersion test across the runs
gives chi-square 13.3 on 9 df, p ~ 0.15 — **not distinguishable from pure
sampling noise.** Every round is consistent with one constant rate.

The check that settled it: the round with the worst rate (5/6) was re-run with a
byte-identical prompt and came back **1/6**. Same prompt, same topics, same
devices, same afternoon. There was no regression to explain, and there had
probably been nothing to explain in any of the earlier rounds either.

Three things follow, and they generalise past this construction:

- **A six-lesson run cannot measure a prompt change.** Distinguishing 45% from
  20% at that size needs roughly n=50 per arm. Every single-digit probe here was
  underpowered by an order of magnitude, and the narrative it produced was
  confident and fictional. Replicate before believing a difference.
- **Some prompt changes do work, and look different when they do.** The
  vague-attribution ban was tested the same way and gave 8 hits across 12
  lessons without it against 1 across 12 with it. That is visible at this sample
  size. The pivot never produced a signal like that under any of three
  formulations, which is what eventually justified a code gate instead.
- **Topic dominates prompt.** Across ten runs the same six topics ranged from
  1/10 (mechanical clocks) to 7/10 (sourdough). A fixed six-topic panel where one
  topic almost always fires and another almost never has less discriminating
  power than n=6 already suggests.

The gate's job is to catch the construction when it fires, not to lower the rate.
The rate is not the target, and a probe round after the gate would not be able to
tell you whether it had moved.

## Roadmap

1. ✅ Scaffold, core package split, models, `MockProvider`, tests, CI
2. ✅ Onboarding, Home, Suggestions, Reader, Completion, Library — all on `MockProvider`
3. ✅ `AnthropicDirectProvider`: Keychain, streaming, two-pass pipeline, lazy chapters, usage ledger
4. ✅ Recall system, scheduling, notifications, points, post-lesson test, stats, share card
5. ✅ StoreKit 2, `EntitlementService`, paywall, locked states
6. ✅ Widget, deep links, markdown export, accessibility pass, empty/error states
