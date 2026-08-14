# Spare

A time-first micro-learning iOS app. You tell it how long you have — 3, 10, 15, or 45 minutes — and it finds you something worth learning. **Time is the input; topic is the output.** That inversion is the product.

**Status: Phase 1.** Scaffold, models, generation logic, mock provider, and tests. No UI beyond a placeholder Home.

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

**3. Chaptered formats work one chapter ahead.** For the 45-minute mini-course, while the reader is in chapter N, chapter N+1 is being **drafted and revised**. `nextChapterToGenerate` prioritises any chapter at or behind the reader over prefetching, so the reader's own chapter is never the one that's missing.

**4. Text already shown is immutable.** Displayed text only ever grows, and only by appending. A candidate update that would rewrite shown text is **rejected and counted** (`appendOnlyViolations`) rather than applied — so "never mutate text already scrolled past" is structural, not aspirational.

Because the reader is looking at pass-2 output as it streams, the revision prompt is explicitly told to revise front-to-back and never reorder sections.

The earlier design — stream the draft immediately, swap in the revision later — was **wrong** and has been removed: it showed every first-time reader unrevised output, which defeats the point of paying for two passes.

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

- **`core`** — ubuntu-latest in a `swift:6.1` container: the banned-import check, the FoundationNetworking guard check, then `swift build` and `swift test`.
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

### Cost control

A 45-minute mini-course is an outline call plus two calls per chapter — 13 requests if fully generated. Three things keep that honest:

1. **Lazy chapters.** Generation blocks on `ChapterDemand` before each chapter. The Reader advances it as the reader scrolls, so a reader who stops at chapter 2 triggers 5 calls, not 13. Leaving the Reader cancels the stream outright.
2. **Cached prefix**, above.
3. **`UsageLedger`.** Every call — success *or* billed failure — writes token counts and an estimated cost, surfaced as a running monthly total in Settings.

### Retry rules

Retryable: network drops, 429, 5xx, truncated streams, malformed JSON. Not retryable: refusals (a decision, not a glitch) and auth failures.

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

## Known deviations

- **Toolbar button shadow — confirmed unfixable without abandoning `.toolbar`.** Toolbar items render with a soft shadow under a circular background the theme doesn't specify. Three fixes were tried and verified against CI screenshots, and all three left it unchanged:
  1. `.buttonStyle(.plain)` on the buttons — it isn't button styling.
  2. `.toolbarBackground(.hidden, for: .navigationBar)` — it isn't the bar background.
  3. `NavigationBarChrome.flatten()`: a `UINavigationBarAppearance` with a transparent background and cleared `shadowColor`/`shadowImage`, applied to `standardAppearance`, `scrollEdgeAppearance`, `compactAppearance`, and `compactScrollEdgeAppearance`.

  That eliminates the bar as the source: it is iOS 26's per-item "glass" treatment on toolbar buttons, which has no SwiftUI-level override. Removing it would mean hand-rolling a header row instead of `.toolbar`, giving up native back-swipe and VoiceOver behaviour to delete a shadow. Not worth it. Both fixes are kept anyway — they're harmless and correct in intent.

## Roadmap

1. ✅ Scaffold, core package split, models, `MockProvider`, tests, CI
2. ✅ Onboarding, Home, Suggestions, Reader, Completion, Library — all on `MockProvider`
3. ✅ `AnthropicDirectProvider`: Keychain, streaming, two-pass pipeline, lazy chapters, usage ledger
4. Recall system, scheduling, notifications
5. StoreKit 2, `EntitlementService`, paywall
6. Widget, App Intents, share card, markdown export, accessibility pass
