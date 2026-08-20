# Spare proxy

Sits between the app and the Anthropic API so the key never ships in a binary
and tier limits stop being client-enforced.

## Why Cloudflare Workers

- **Streaming is native and unbuffered.** `fetch()` gives a `ReadableStream`
  body; returning it directly forwards SSE bytes without re-framing. That is
  the whole requirement — `RevisionGate`'s ordering invariants are defined
  over the SSE event sequence, so anything that buffers, re-chunks, or
  re-encodes breaks the reader's guarantee that revised text only ever
  appends.
- **Deployable from Windows.** Wrangler is a plain npm CLI; no Docker, no
  Linux-only toolchain, no CI runner needed to ship.
- **Secrets are first-class.** `wrangler secret put` stores values encrypted
  and outside the repo, injected as bindings at runtime.
- **The storage primitives match the consistency each job needs** — see
  below, which is the part that would be wrong on most platforms.

Rejected: a VPS (needs process management and TLS for a service that is
almost entirely I/O), Vercel/Netlify functions (streaming works but there is
no strongly consistent counter primitive, which is the requirement that
actually matters here), and Lambda (cold starts on a streaming path, and
DynamoDB conditional writes would work but cost more setup than Durable
Objects for the same guarantee).

## The consistency decision, which is the one that protects money

**Counters live in Durable Objects. Only the cache lives in KV.**

Workers KV is eventually consistent. A free-tier limit of one lesson per day
implemented on KV loses to a double-tap: two requests read `0`, both pass,
both write `1`. The user gets two lessons and the log shows one. At
per-lesson costs that is a slow leak, and it is invisible because nothing
errors.

A Durable Object serialises all requests for a given key, so
read-check-increment is atomic without a transaction protocol. One object per
device for daily and monthly counters; one global object for the spend
ceiling. The ceiling is a single bottleneck by construction — at this scale
that is a feature, because it is the number that has to be right.

KV is correct for the lesson cache: a stale miss costs one regeneration and a
stale hit serves a slightly older lesson. Neither is a money bug.

## Subscription verification

**We ask Apple rather than verifying Apple's signature ourselves.**

StoreKit 2 hands the app a `jwsRepresentation`, which is JWS with an `x5c`
certificate chain in the header. Verifying it locally means doing X.509 chain
validation up to Apple's root CA. Workers has WebCrypto (so ES256 verify is
available) but no X.509 parser, and hand-rolling certificate chain validation
in the layer that decides who gets paid features is exactly the wrong place
to write novel security code.

So instead:

1. Decode the JWS payload **untrusted**, purely to read `originalTransactionId`.
2. Call the App Store Server API for that id, authenticating with our own
   ES256 JWT signed by the App Store Connect key.
3. Trust the answer because it came from Apple over TLS in response to a
   request Apple authenticated — not because we checked a signature.

That inverts the trust relationship into one the platform already
guarantees. The JWS is treated as an untrusted claim about which
subscription to ask about, which is all it needs to be.

### What the JWT needs

Confirmed against Apple's current documentation rather than assumed:

- Algorithm **ES256** (ECDSA P-256 + SHA-256), signed with the `.p8` private
  key from App Store Connect.
- Header: `alg: ES256`, `typ: JWT`, `kid: <key id>`.
- Payload: `iss` (issuer id), `iat`, `exp`, `aud: "appstoreconnect-v1"`,
  `bid` (bundle id).
- Short lifetime. Sources differ on the ceiling (20 vs 60 minutes), so this
  uses **10 minutes**, which is inside both.

### Hosts

- Production `https://api.storekit.itunes.apple.com`
- Sandbox `https://api.storekit-sandbox.itunes.apple.com`

A TestFlight or sandbox purchase only exists on the sandbox host. The server
tries production first and falls back to sandbox on a not-found, which is the
documented pattern — without it, every internal build looks unsubscribed.

## The honest limit on tier enforcement

Moving limits server-side removes *client* enforcement, not *all* spoofing.
The app has no accounts by design, so identity is a UUID minted on first
launch and kept in the App Group's defaults — not the Keychain, which can
outlive a delete-and-reinstall and would make the free tier feel inescapable to
somebody switching phones. A determined user can clear it and reset their daily
allowance.

That is a real hole and it is not closed here. What it changes: abuse goes
from "edit a boolean in a local database" to "reinstall and lose your
library", which is enough to stop casual abuse and not enough to stop
deliberate abuse.

**The global monthly spend ceiling is the actual protection.** It does not
care who is asking or why — past the ceiling, free generation stops serving
fresh lessons and falls back to the cache. Premium keeps working, because
those requests are paid for and verified. If the ceiling ever trips, that is
the signal that something is wrong; it is not meant to be reached.

Per-IP throttling sits in front of everything as a second, cruder backstop.

`GET /v1/status`, authenticated with `ADMIN_TOKEN`, reports the month's spend
against the ceiling and optionally one device's counters. It exists because that
figure was otherwise unanswerable from outside — the ledger knew it and nothing
exposed it, leaving Anthropic's billing page as the only source, which lags and
cannot separate this Worker's spend from anything else on the same key. Unset
token means the route 404s rather than 401s, so a deploy that never configures it
does not advertise that it exists. Read-only and GET-only: changing a limit stays
a deploy, where it is reviewable.

### Known limitation: a reinstall loses the library permanently

There are no accounts, so there is no copy of anything anywhere but the phone.
Deleting the app, replacing the phone, or resetting it loses the whole library:
every lesson read, the recall schedule, the points, the stats. There is no
restore, and support cannot recover it, because nothing was ever sent to a
server to recover.

Subscriptions survive — those live with Apple and come back with a restore — so
somebody who pays does not lose what they paid for. What they lose is everything
they read.

This is the accepted cost of having no accounts: no sign-up screen, no password,
no email address collected, nothing about what anyone reads stored off their own
device. That trade is the right one for this app, and it is not being changed
now. It is written down here so it is a known limitation rather than something
discovered by the first person it happens to.

The same fact is what makes the free tier enforceable at all: the device
identifier is a UUID in the App Group, and clearing it means clearing the
library with it.

If this is ever revisited, the smallest honest version is an export the reader
initiates — the Markdown export already exists — not an account.

## Lesson cache

The single biggest cost lever: a free user who generates every lesson costs
roughly $2/month, and most free users ask about overlapping topics.

Cache key is `format + window + normalised topic`, where normalising
lowercases, strips punctuation and stopwords, and sorts the remaining
significant words — so "Why bridges hum" and "why do bridges hum?" collide on
purpose.

### Free and premium get different content freshness

This is a deliberate product decision, not an implementation detail, and it is
the one thing in this file most likely to be mistaken for a bug later.

**Premium always generates fresh.** Every request goes to the model. Nobody who
pays is ever handed a lesson written for somebody else.

**Free may be served from the cache**, subject to three rules:

1. **Nothing older than 30 days.** Enforced twice — as a KV TTL, and as an age
   check when the entry is read. The TTL alone would make the rule true most of
   the time, because KV expiry is not instantaneous, and "true most of the time"
   is not the promise.
2. **Never the same lesson twice to the same device.** Each device records the
   cache keys it has been served, including ones it generated itself, and the
   cache declines a repeat. Without this, asking about bridges twice in a week
   would return identical words, which reads as the app being broken rather than
   as a cache working. A device remembers its last 400 lessons, which at one a
   day is more than a year.
3. **A generated lesson counts as read by whoever generated it.** Otherwise a
   free reader's own lesson would come back to them from the cache the next day.

What a free user therefore experiences: their lessons are always new *to them*,
but on a popular topic the words may have been written for someone else within
the last month. What they do not get is Premium's guarantee that the model wrote
this one, now, for them.

Stated plainly because the two tiers differ in something a reader can notice, and
that should be a choice on the record rather than a surprise.

## Deploying from Windows

**Step-by-step instructions are in [DEPLOY.md](DEPLOY.md)**, written for someone
who is not a developer: every command, what each one prompts for, and what
working looks like at each step. The summary below is for someone who has done it
before.


Needs Node 22 or newer — wrangler 4 and miniflare 5 both require it.

```powershell
cd server
npm install
npx wrangler login
```

Create the cache namespace and put its id in `wrangler.toml`, replacing
`REPLACE_WITH_KV_ID`. This is the one step that has to happen before the first
deploy; a Worker with an unresolvable KV binding will not start.

```powershell
npx wrangler kv namespace create LESSONS
```

Then the secrets. Each command prompts for the value, so nothing is typed on a
command line that a shell history would keep:

```powershell
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put APPSTORE_PRIVATE_KEY   # the whole .p8, BEGIN/END lines included
npx wrangler secret put APPSTORE_KEY_ID
npx wrangler secret put APPSTORE_ISSUER_ID
npx wrangler deploy
```

Deploy prints the Worker's URL. Put that in `project.yml` as `SPProxyBaseURL`
and regenerate the Xcode project; the app reads it from `Info.plist` rather than
from a constant so a redeploy elsewhere needs no code change.

Nothing above is committed. `wrangler.toml` holds only non-secret bindings, and
CI fails the build if anything shaped like a key or a PEM body reaches the repo.

## Testing

`npm test` runs Vitest against recorded fixtures through
`@cloudflare/vitest-pool-workers`, so the Worker runs in the real workerd
runtime with real Durable Objects rather than a mock. No test makes a network
call: the Anthropic and Apple hosts are both replaced by fixture handlers, and
`fixtureFetch` throws on any request it has no recording for, so a test that
reaches the internet fails instead of passing.

**Storage is isolated per test file, not per test.** Without accounting for that,
every test in a file shares one free-tier counter and one lesson cache, and they
feed each other — a streaming assertion ends up comparing against a cached
replay from the test above it, and a test named for the daily limit passes its
first assertion because its request was an unmetered cache hit. `harness.ts`
derives each test's device and topic from the running test's name so tests start
independent; the cache tests, which are about sharing, state theirs explicitly
and opt back in.
