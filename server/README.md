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

## One lesson is one charge, however many requests it takes

A lesson is two HTTP requests: a draft and a revision. A 30-minute course is
nine: an outline, then four chapters twice over. The meter counted requests.

That is not a rounding error, it is two separate product failures. A free user's
whole daily allowance went on the draft pass, and the revision came back `402
dailyLimitReached` — so the free tier could not finish a single lesson through
the proxy, ever. And one course counted nine against a cap of twelve a month, so
a premium subscriber got one course and a bit rather than twelve.

`ProxyProviderTests` had asserted the contract from the client side since the
endpoints were written, in as many words: *"two passes are one lesson to the
reader and must be one unit to the meter."* The client honoured it. Nothing on
this side implemented it, and nothing on this side tested it.

The charge is now keyed on the lesson. The key is the cache key — window, format,
and topic — which the proxy already derives for its own reasons, and every
request belonging to one lesson carries the same one. A device's charged keys for
the day are stored alongside its counters and roll over with them.

The obvious alternative was a `pass` field on the envelope, so the client could
say "this is only the revision, don't charge it". That is a free-generation
switch for anyone who reads one request. Deriving the unit from facts the proxy
needs anyway is the only version that does not depend on the client being honest.

The charge covers a bounded number of requests — sixteen — and not an unlimited
number, which is the part that stops the fix being worse than the bug it fixes.
Once a lesson is paid for its later requests are free, so without a ceiling a
free device could send one topic all day and generate every time. Spoofing the
device id already resets the allowance, but that costs a reinstall; repeating a
request costs nothing. Sixteen is out of reach for an honest client — a course is
nine requests and the retry policy allows three attempts a call — and finite for
a dishonest one.

### The outline needs its own endpoint

`applyPolicy` sets `stream` from the endpoint and never from what the client
sent, because a client-supplied flag deciding server control flow is not
somewhere that decision belongs. Every generation call streams — except the
course outline, which is a small structured plan and comes back as JSON.

The outline was routed to `/v1/lesson`, on the reasoning that an outline is part
of starting a lesson and should be what the course cap counts. So the policy
turned a non-streaming request into a streaming one, and **every 30-minute
course ever requested through the proxy failed on its first call.**

Neither test suite could see it. The client's tests use fixtures that answer
whatever they are asked, so a streaming response to a non-streaming call is
whatever the fixture says it is. The server's tests build their own request
bodies, so they never sent the one the client actually sends. Each half was
correct alone; the contract between them was untested.

`/v1/outline` is metered like the rest — it is what starts a course, so it is
what the course cap counts — but it is not cached, because the cache holds SSE,
and it is capped at 4,000 tokens rather than inheriting a lesson's 24,000. The
mirror is now asserted from both ends: `ProxyRoute.streamingPaths` in SpareCore,
and a test there that every request the pipeline sends streams if and only if
its endpoint does.

## The reverse trial

Seven days of premium with no card and no account, bounded at **10 lessons of
which at most 2 may be 30-minute courses**. A course counts against both
ceilings. Whichever ceiling arrives first ends the trial.

```
POST /v1/trial/start    claims this device's one trial; idempotent
POST /v1/trial/status   reads it
```

Both are answered before the policy layer, like attachments: neither carries a
model request.

**The server is the authority and the client is a mirror.** Trial state lives
in the same `UsageCounter` Durable Object as the device's metering, under a
`trial` key, so the trial caps and the daily limit share one serialisation
point. A client that decided whether its own trial was live would be the same
hole as a client that picked its own model, and this one hands out Opus.

`startedAt` is both the clock and the once-per-device flag. There is no
separate "has used a trial" boolean, because two fields that must agree are two
fields that can disagree, and the one that would win is the one that hands out
Opus. Starting a trial on a device that already has one -- running or long
finished -- returns the existing state with `started: false` and writes
nothing.

A device with a live subscription is refused with `alreadySubscribed` rather
than started. It has nothing to gain, and consuming its one trial while it is
already paying would quietly take something away from a customer.

### Where the caps are enforced, and why the earlier read is safe

The router reads trial state before it can pick a pool and a model. That read
is *not* atomic with the claim. It does not need to be: the counters move only
inside `UsageCounter.consume`, and the worst a race can do is route a request
to Opus and then refuse it there, before a single token is generated. A
refusal, not a leak.

Cache hits count against the trial, for the same reason they count against the
free daily limit: a reader cannot tell a cached lesson from a generated one, so
a cap that only counted generations would be a cap nobody could describe.

Every response to a trialing device carries `x-spare-trial`, a JSON mirror of
the current state. A header rather than a body field because the lesson path is
SSE and has no JSON body to put it in. It rides refusals too, so a client whose
mirror has gone stale learns the week is over from the same response that
refused it, rather than showing a paywall for a length it believes it owns.

### A trialist is not a payer

`hasPremiumAccess("trialing")` is true; `isPaying("trialing")` is false. The
second is the load-bearing one: the global spend ceiling is lifted for funded
requests only, so a trialist stops at the ceiling like a free device does. That
is also what bounds the device-spoofing exposure below, which the trial makes
worth roughly $8 a reset instead of one lesson a day.

### A started course finishes

A course is an outline and four chapters, read over days. Start one on day 6,
open chapter 3 on day 8, and the entitlement that paid for it is gone: the last
thing the product would do before asking for money is break a feature the
reader was enjoying. `chargedKeys` almost covers this and rolls over with the
UTC day, so it only helps inside twenty-four hours.

So charging a chaptered lesson also records a **course grant**: the course's
identity, the pool it was written into, and a timestamp. For thirty days
afterwards that course's remaining chapters are allowed whatever the tier, and
are read from the pool they were generated in -- serving chapter 3 out of the
free pool would drop a Sonnet chapter into an Opus course and miss the cached
outline entirely. The grant key deliberately excludes the pool, because the
pool is the thing that changes when the entitlement does.

Recorded for every tier, not just the trial: a monthly subscription lapsing
mid-course has exactly the same shape. Bounded by `MAX_REQUESTS_PER_LESSON`,
because a grant that outlives the day would otherwise be a generate-forever
loop on one topic.

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

### The operator bypass

A request carrying `x-spare-admin: $ADMIN_TOKEN` skips the per-device limits and
the cache, so every request generates. It exists to produce a batch of lessons to
read and judge (see `batch-lessons.ps1`), which the daily limit otherwise makes
impossible.

What it deliberately does **not** skip is the spend ceiling or the request
policy. Those are what stop a leaked token becoming an unbounded bill, and a
bypass that disabled them would be a worse hole than the one it exists to work
around. Spend is recorded exactly as for any other request, so a batch shows up
in `/v1/status` like everything else.

Same token as the status endpoint, checked by the same constant-time comparison
in one place, so there is a single definition of "is this us".

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

### A cached lesson counts against the daily limit

One lesson a day, whatever its source.

This was not the first design. Cache hits were originally unmetered, on the
reasoning that a hit costs nothing so charging a day's allowance for it would be
punitive. Verifying the deployment showed what that actually produced: one device
read three cached lessons and still had its full generation allowance. The free
tier was not one lesson a day. It was one *generated* lesson a day plus unlimited
cached ones.

It was changed for three reasons, none of them about cost:

**A reader cannot tell the difference.** Nothing in the app distinguishes a
cached lesson from a generated one; that is the point of the cache. So an
allowance that only counts generations is an allowance whose size depends on
something invisible. Two people doing the same thing on the same day get
different limits, and neither can tell why.

**It cannot be described honestly.** "One lesson a day, unless we happen to have
one already, in which case more" is not a sentence that can go on a paywall or in
an App Store listing. The paywall says *one lesson a day*, and copy that is
approximately true is copy that eventually becomes a complaint.

**Conversion pressure decayed as the cache filled.** The more popular Spare got,
the more topics were already cached, so the more a free user could read without
paying. That is a paywall that weakens exactly as the app succeeds, which is the
opposite of how it should behave.

A predictable limit we chose beats a generous one that leaks. The generosity is
still there, in the shape that survives being described: free users get real
lessons on real topics, one a day, and the cache is what makes that cheap enough
to offer at all.

The cost reasoning behind the original design is untouched. A cache hit still
calls nothing and costs nothing; it is simply also a lesson. Past the spend
ceiling free generation stops and the cache still answers, because metering a hit
costs the reader an allowance, not us a payment.

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
