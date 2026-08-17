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
launch and kept in the Keychain. A determined user can clear it and reset
their daily allowance.

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

## Lesson cache

The single biggest cost lever: a free user who generates every lesson costs
roughly $2/month, and most free users ask about overlapping topics.

Cache key is `format + window + normalised topic`, where normalising
lowercases, strips punctuation and stopwords, and sorts the remaining
significant words — so "Why bridges hum" and "why do bridges hum?" collide on
purpose.

**Free users can be served a cached lesson. Premium always generates fresh.**
That is a product decision, not only a cost one, and it has a visible
consequence: two free users asking about the same thing get the same words.
Stated here so it is a choice rather than a surprise.

## Deploying from Windows

```powershell
cd server
npm install
npx wrangler login
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put APPSTORE_PRIVATE_KEY   # contents of the .p8
npx wrangler secret put APPSTORE_KEY_ID
npx wrangler secret put APPSTORE_ISSUER_ID
npx wrangler deploy
```

Nothing here is committed. `wrangler.toml` holds only non-secret bindings.

## Testing

`npm test` runs Vitest against recorded fixtures through
`@cloudflare/vitest-pool-workers`, so the Worker runs in the real workerd
runtime with real Durable Objects rather than a mock. No test makes a network
call: the Anthropic and Apple hosts are both replaced by fixture handlers.
