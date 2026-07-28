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
- **Structured outputs** (`output_config.format` with a JSON schema) constrain suggestions, chapters, and recall questions. Malformed JSON stops being a failure mode; counts and word limits are then enforced by `SuggestionValidator`.
- **No assistant prefill, no `temperature`/`top_p`/`top_k`, no `thinking.budget_tokens`** — all rejected on current models. `AnthropicWireTests` asserts the request body never contains them.
- **The system prompt is cached** (`cache_control: ephemeral`); it is byte-identical across lessons.
- **Validation is layered:** prompts ask, schemas constrain, `SuggestionValidator` and `LessonQualityCheck` verify. Quality findings are advisory — they can trigger one retry but never block a lesson from being read.

## API key handling

Lessons are generated by calling the Anthropic API **directly from the device**. This is a deliberate v1 tradeoff with a real risk: a key in an app binary is extractable.

So: the key is never hardcoded, never in `Info.plist`, never committed. It is entered in Settings and stored in the **Keychain** (Phase 3). `.gitignore` guards against accidental commits. Every network call sits behind `LessonProvider`, so moving to a server proxy later is one new conformance and one line changed at the injection site.

## Roadmap

1. ✅ Scaffold, core package split, models, `MockProvider`, tests, CI
2. Onboarding, Home, Suggestions, Reader, Completion, Library — all on `MockProvider`
3. `AnthropicDirectProvider`: Keychain, streaming, two-pass pipeline, lazy chapters
4. Recall system, scheduling, notifications
5. StoreKit 2, `EntitlementService`, paywall
6. Widget, App Intents, share card, markdown export, accessibility pass
