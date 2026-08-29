<title>Spare Proxy Deployment</title>

# Deploying the Spare proxy

A step-by-step guide for Windows. Every command goes in **PowerShell**. After
each step there's a "you should see" — if you see something else, stop there
rather than continuing, because most later steps depend on the earlier ones
having worked.

Nothing here can be done for you: every step needs an account only you can log
into.

> **The proxy has to go live before the app does, and two switches exist for
> that window.** `POST /v1/trial/start` is public and unauthenticated by design
> — there are no accounts — so a Worker carrying it with no client in the world
> is a free-Opus endpoint for anyone who finds it. `wrangler.toml` ships with
> `TRIAL_START_ENABLED = "false"`, which 404s it, and Step 4b sets
> `SPARE_CLIENT_TOKEN`, which 404s everything except `/v1/status` for a caller
> without the header. Both are off switches for a period, not a design: turn
> the trial on in the deploy that accompanies the first TestFlight build, and
> read **"The client token expires"** below before that date.
>
> **Already deployed?** The Worker running right now predates two fixes it needs.
> Until you redeploy, the free tier cannot finish a single lesson (a lesson's
> revision pass is refused as if it were a second lesson) and every 30-minute
> course fails on its first call. Both are server-side, so redeploying is the
> whole fix: `cd server`, then `npx wrangler deploy`. Nothing else in this guide
> needs redoing — your secrets, KV namespace, and URL all survive a redeploy.

You can do this in two sittings. **Part 1 gets free lessons working.** Part 2 adds
subscriptions. The proxy is designed to run correctly with only Part 1 done, so
there's no rush between them.

---

## What you'll need before you start

| Thing | Where it comes from | Cost |
|---|---|---|
| A Cloudflare account | [dash.cloudflare.com/sign-up](https://dash.cloudflare.com/sign-up) | Free tier is enough to start |
| An Anthropic API key | [console.anthropic.com](https://console.anthropic.com) → API Keys | Pay per use |
| Node.js 22 or newer | Step 0 below | Free |
| An App Store Connect key | Part 2 only | Free, needs a paid Apple Developer account |

**One warning about the Anthropic key.** Whoever holds it can spend your money.
Don't paste it into a chat, an email, a text file, or a screenshot. The only place
it should ever be typed is the `wrangler secret put` prompt in Step 4, which
doesn't echo it to the screen and doesn't put it in your command history.

---

# Part 1 — Free lessons working

## Step 0. Install Node.js

Download the **LTS** installer from [nodejs.org](https://nodejs.org) and run it.
Accept the defaults.

Then **close PowerShell and open a new one** — an installer's changes to your PATH
only apply to windows opened afterwards, which is the single most common reason
this step appears not to have worked.

```powershell
node --version
```

**You should see:** `v22.x.x` or higher (`v24`, `v26` — all fine).

**If you see** `'node' is not recognized`: the new-window step was skipped, or the
install didn't finish. Open a fresh PowerShell and try again.

**If you see** `v20` or lower: the tooling needs 22+. Install the current LTS over
the top; it replaces the old one.

---

## Step 1. Go to the server folder

```powershell
cd C:\Users\misha\Spare\server
```

**You should see:** your prompt now ends in `...\Spare\server>`.

Everything from here on assumes you're in this folder. If you open a new
PowerShell window later, run this command again first.

---

## Step 2. Install the tooling

```powershell
npm install
```

Takes a minute or two and prints a lot of scrolling text.

**You should see:** a final line like `added 180 packages in 25s`.

**If you see** lines beginning `npm warn deprecated`: ignore them. Warnings are
normal and not failures.

**If you see** `npm error`: stop. That's a real failure.

---

## Step 3. Log in to Cloudflare

```powershell
npx wrangler login
```

This opens your web browser.

**You'll be asked:** to sign in to Cloudflare (if you aren't already), then to
authorise "Wrangler" to manage your account. Click **Allow**.

**You should see:** in the browser, a page saying you've successfully logged in.
Back in PowerShell, `Successfully logged in.`

You only ever have to do this once on this computer.

Confirm it took:

```powershell
npx wrangler whoami
```

**You should see:** a small table with your email address and an Account ID.

---

## Step 4. Store the Anthropic key

```powershell
npx wrangler secret put ANTHROPIC_API_KEY
```

**You'll be asked:** `Enter a secret value:`

Paste your Anthropic key (it starts with `sk-ant-`) and press Enter. **Nothing
will appear as you paste** — no dots, no asterisks, nothing. That's deliberate,
not a frozen terminal. Paste once and press Enter.

**You should see:**

```
✨ Success! Uploaded secret ANTHROPIC_API_KEY
```

**If you see** a warning that the Worker doesn't exist yet and an offer to create
it: answer **yes**. That's expected on the very first secret — the Worker gets
created empty and Step 6 fills it in.

The key is now encrypted in Cloudflare. It isn't in the repo, it isn't in your
command history, and it will never be sent back to your phone.

---

## Step 4b. Store the client token

This is the one that keeps the proxy closed while there is no app.

Invent a long random string — anything you can paste twice. It doesn't need to
be memorable and you will not type it again after the app is configured.

```powershell
npx wrangler secret put SPARE_CLIENT_TOKEN
```

**You should see:**

```
✨ Success! Uploaded secret SPARE_CLIENT_TOKEN
```

**Keep your own copy.** Cloudflare secrets are write-only: nothing, including
`wrangler`, can read one back. Losing the value means setting a new one and
updating the app, not recovering it.

**A secret is not a deploy.** `wrangler secret put` stores the value against
the Worker; the code that reads it arrives with `npx wrangler deploy`. Until
that deploy has run, the secret is set and the gate is not up, and
`/v1/status` will keep reporting `clientTokenRequired: false`. That field is
how you tell the two states apart.

From the next deploy onwards, every endpoint except `GET /v1/status` answers
**404** unless the request carries `x-spare-client: <that string>`. The batch
tool doesn't need it — the operator token is accepted on its own, so the probe
works with the gate up and nothing else does.

**The app does not send this header yet, and does not need to.** Nothing on a
phone talks to the proxy during the probe. Sending it is part of the same piece
of work as turning the trial on: the four places that already set
`x-spare-device` (`ProviderRoute`, `Allowance`, `LessonAttachments`, `Funnel`)
would each carry it, from an `Info.plist` key alongside `SPProxyBaseURL`. Do
that, or unset this secret, before a build goes to a tester — with the gate up
and the header missing, every request from the app 404s.

### The client token expires

Not on a date the software knows about. **It stops being a control the day the
first TestFlight tester installs the app**, because the app has to carry the
value, and anyone with the binary can read it out. There is no version of this
that survives shipping.

That is fine for what it is for: it closes the weeks between this deploy and
the first build going out, which is the period when the URL is public and
nothing in the world is a legitimate client. It is not fine as the only
control afterwards.

**Three things have to land before that date, and this is the list:**

| Before the first TestFlight install | Why |
|---|---|
| **Cloudflare rate limiting** on the Worker's route — 30 requests a minute per IP on `/v1/*`. Dashboard only, no code. | The client token is gone; per-IP throttling is what takes over as the crude first backstop. See "Rate limiting" below. |
| **The go-deeper counter** — already deployed, `GO_DEEPER_PER_DAY_CEILING` in `limits.ts`. Confirm it is live. | `/v1/go-deeper` is 24,000 Opus tokens and premium access is all it asks for, which a trial grants. |
| **Reserve-then-settle on the spend ceiling.** Not built. | The ceiling is checked against spend already recorded, and recording happens after a generation finishes — so a burst of concurrent requests all read the same figure and all pass. Overshoot scales with the caller's concurrency. |

Until the third one exists, treat `MONTHLY_SPEND_CEILING_USD` as "roughly where
spending stops", not as a limit.

---

## Step 5. Create the lesson cache

This is the storage that lets two people asking about the same topic share one
generated lesson. It's the single biggest thing keeping your costs down.

```powershell
npx wrangler kv namespace create LESSONS
```

**You should see** something like:

```
🌀 Creating namespace with title "spare-proxy-LESSONS"
✨ Success!
Add the following to your configuration file:
[[kv_namespaces]]
binding = "LESSONS"
id = "a1b2c3d4e5f6789012345678abcdef01"
```

**Copy that long `id` value.** You need it in the next step. It's 32 characters of
letters and numbers. Yours will be different from the example.

### Now paste it into the config

Open the config file:

```powershell
notepad wrangler.toml
```

Find the last two lines:

```toml
[[kv_namespaces]]
binding = "LESSONS"
id = "REPLACE_WITH_KV_ID"
```

Replace `REPLACE_WITH_KV_ID` with your id, keeping the quotation marks:

```toml
id = "a1b2c3d4e5f6789012345678abcdef01"
```

Save (**Ctrl+S**) and close Notepad.

**This step cannot be skipped.** A Worker with a storage binding it can't resolve
won't start at all, and the error message doesn't say why.

---

## Step 6. Deploy

```powershell
npx wrangler deploy
```

**You should see** something like:

```
Total Upload: 42.13 KiB / gzip: 9.87 KiB
Your Worker has access to the following bindings:
- KV Namespaces:
  - LESSONS: a1b2c3d4e5f6789012345678abcdef01
- Durable Objects:
  - USAGE: UsageCounter
  - SPEND: SpendLedger
Uploaded spare-proxy (3.2 sec)
Deployed spare-proxy triggers (0.5 sec)
  https://spare-proxy.your-name.workers.dev
Current Version ID: 1a2b3c4d-...
```

**The URL on the second-to-last line is what you need.** Write it down — it goes
into the app in Step 7. It'll look like
`https://spare-proxy.something.workers.dev`.

**If you see** `KV namespace 'REPLACE_WITH_KV_ID' is not valid`: Step 5's paste
didn't save. Reopen `wrangler.toml` and check.

### Check it's alive

```powershell
curl.exe -i -X POST https://spare-proxy.your-name.workers.dev/v1/lesson
```

Substitute your own URL. Note it's `curl.exe`, with the `.exe` — plain `curl` in
PowerShell is a different, older command that won't work the same way.

**You should see:** `HTTP/1.1 400 Bad Request` and a body mentioning
`missingDevice`.

**That 400 is success.** You sent a request with no device identifier and the
server correctly refused it. It proves the Worker is deployed, running, and
enforcing its rules. A 400 here is the goal.

**If you see** `HTTP/1.1 500`: something is wrong with the deploy. Run
`npx wrangler tail` in one window, repeat the curl in another, and the log will
say what.

**If you see** `Could not resolve host`: the URL is mistyped, or the deploy didn't
finish.

---

## Step 7. Point the app at the proxy

The app reads the proxy's address from a config file, not from code, so this is a
text edit.

```powershell
notepad C:\Users\misha\Spare\project.yml
```

Find this line (it's about 45 lines down):

```yaml
        SPProxyBaseURL: https://spare-proxy.spare.workers.dev
```

Replace the address with your real one from Step 6:

```yaml
        SPProxyBaseURL: https://spare-proxy.your-name.workers.dev
```

Keep the indentation exactly as it is — YAML files fail on changed indentation,
and the error can be confusing. Only change the address itself.

Save and close.

Then commit it, so the build picks it up:

```powershell
cd C:\Users\misha\Spare
git add project.yml
git commit -m "Point the app at the deployed proxy"
git push
```

**You should see:** the push succeeding, and CI starting a new run.

The iOS app is built on a Mac by GitHub Actions, so the change takes effect on
the next build there. Nothing needs regenerating on this machine.

---

## Part 1 is done

Free lessons now run through your proxy. The Anthropic key is in Cloudflare and
nowhere else. Free-tier limits are enforced by the server rather than by the
phone.

**Premium doesn't work yet** — and importantly, it fails *safely*. A subscriber's
request gets "Couldn't confirm your subscription. Try again shortly," which is
retryable and doesn't hand out paid content. It doesn't crash and it doesn't leak.
Part 2 fixes it whenever you're ready.

---

# Part 2 — Subscriptions

Only needed before real subscribers exist. Requires a paid Apple Developer
account.

## Step 8. Create an App Store Connect API key

This is the credential that lets your server ask Apple "is this person actually
subscribed?" — the check that stops a modified app from claiming premium.

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com).
2. **Users and Access** → **Integrations** tab → **In-App Purchase** in the left
   sidebar.
3. Click **+** (Generate In-App Purchase Key).
4. Name it something like `Spare proxy`. Click **Generate**.

Then collect three things from that page:

| What | Looks like | Where |
|---|---|---|
| **Issuer ID** | `57246542-96fe-1a63-e053-0824d011072a` | Near the top of the page. One per account — the same for every key. |
| **Key ID** | `2X9R4HXF34` | The row for the key you just made. |
| **The `.p8` file** | `SubscriptionKey_2X9R4HXF34.p8` | **Download** link on that row. |

**Download the `.p8` now.** Apple lets you download it exactly once and cannot
re-issue it. If you lose it, you revoke the key and make a new one.

Keep the file somewhere you'll find it — not in the Spare folder, so it can never
be committed by accident. Your Documents folder is fine.

> **Use the In-App Purchase key type**, not a general "App Store Connect API" team
> key. Both look plausible in the interface; only the In-App Purchase one is
> accepted by the subscription endpoint this server calls.

---

## Step 9. Store the three App Store secrets

Back in PowerShell:

```powershell
cd C:\Users\misha\Spare\server
```

### The Issuer ID

```powershell
npx wrangler secret put APPSTORE_ISSUER_ID
```

**You'll be asked** for the value. Paste the Issuer ID from Step 8. Enter.

**You should see:** `✨ Success! Uploaded secret APPSTORE_ISSUER_ID`

### The Key ID

```powershell
npx wrangler secret put APPSTORE_KEY_ID
```

Paste the Key ID (the short one, like `2X9R4HXF34`). Enter.

### The private key file

This one is different — it's a multi-line file, and pasting it by hand into a
prompt tends to mangle the line breaks. Pipe the file in instead:

```powershell
Get-Content "$HOME\Documents\SubscriptionKey_2X9R4HXF34.p8" -Raw | npx wrangler secret put APPSTORE_PRIVATE_KEY
```

Change the path and filename to match your actual downloaded file. Keep the
quotation marks.

**You should see:** `✨ Success! Uploaded secret APPSTORE_PRIVATE_KEY` — with no
prompt, because the file was piped in.

**If you see** `Cannot find path`: the filename or folder is wrong. Check with:

```powershell
Get-ChildItem "$HOME\Documents\*.p8"
```

This is the whole reason for the `-Raw` flag: without it PowerShell hands over the
file as separate lines and the key arrives corrupted, which then fails much later
with a confusing signature error.

### Confirm all four are stored

```powershell
npx wrangler secret list
```

**You should see** four entries: `ANTHROPIC_API_KEY`, `APPSTORE_ISSUER_ID`,
`APPSTORE_KEY_ID`, `APPSTORE_PRIVATE_KEY`.

Only the names are shown, never the values. That's true for you as well as for
anyone else — Cloudflare cannot show you a secret after it's stored. If you're
ever unsure a value is right, put it again rather than trying to read it.

---

## Step 10. Redeploy

Secrets take effect immediately, but redeploy so the version history records the
change:

```powershell
npx wrangler deploy
```

**You should see:** the same output as Step 6, and the deploy listing your
bindings.

---

## Step 11. Check a real subscription

This needs the app on a phone, from TestFlight, with a sandbox purchase.

Watch the server live while you use it:

```powershell
npx wrangler tail
```

This prints every request as it arrives. Leave it running, then on the phone buy a
subscription and start a 30-minute course.

**You should see** a line for a request to `/v1/lesson`, and a `200` status.

**If you see** `503` and `verificationUnavailable`: the App Store credentials
aren't right. Most likely causes, in order: the wrong key *type* in Step 8, a
mangled `.p8` from skipping `-Raw`, or the Issuer ID and Key ID swapped.

Press **Ctrl+C** to stop tailing.

---

# Afterwards

## What it costs

The spend ceiling is set to **$15/month** in `wrangler.toml`. Past it, free
generation is served from the cache instead of the model; subscribers keep
working, because their requests are paid for. Nothing breaks — costs stop
climbing.

Fifteen is a pre-release number, sized to the probe rather than to a userbase.
The full 20-lesson batch costs about $3, so a run that retried every lesson
twice — three attempts each — would be about $9 and still clear it. Raise it in
the deploy that turns the trial on, when real subscribers start depending on
free generation not pausing.

To change it, edit `MONTHLY_SPEND_CEILING_USD` in `wrangler.toml` and redeploy.
Treat it as a smoke alarm rather than a budget: if it ever trips, something is
wrong, not busy.

**One caveat on what it guarantees.** The check runs before the model is
called, but against spend that has already been *recorded*, and recording
happens after the response finishes. Requests that start inside that window all
see the same figure and all proceed, so the ceiling can be overshot by roughly
one generation per concurrent caller. It is a budget, not admission control,
and closing that gap is on the list in Step 4b.

## Rate limiting

For a long time there was none, despite `server/README.md` claiming per-IP
throttling as "a second, cruder backstop". There was no code and no
`wrangler.toml` entry behind that sentence. There is now — the Workers binding
described below — and the claim has been rewritten to describe what actually
exists.

**Check which of these two you are on before following either.** Cloudflare's
rate-limiting *rules* — the dashboard ones — are a WAF feature and belong to a
**zone**, which means a domain you have added to Cloudflare. A
`*.workers.dev` URL is not a zone, so if the proxy is still at
`spare-proxy.<account>.workers.dev` those rules are not available to it and
there will be no **Rate limiting** section to find. Open the dashboard and look
before planning around it.

### If the Worker is on a custom domain

1. [dash.cloudflare.com](https://dash.cloudflare.com) → the **domain**, not the
   Worker.
2. **Security** → **WAF** → **Rate limiting rules** → **Create rule**.
3. Match requests where **URI Path** *starts with* `/v1/`.
4. Rate: **30 requests** per **10 seconds** (or per minute, if that is the
   shortest period offered), counted by **IP**.
5. Action: **Block**, for the shortest duration offered — the point is to make
   scripting slow, not to punish anybody.
6. Deploy.

### If the Worker is on workers.dev — this is what is configured today

The **Workers rate-limiting binding**, in `wrangler.toml`:

```toml
[[unsafe.bindings]]
name = "RATE_LIMITER"
type = "ratelimit"
namespace_id = "1001"
simple = { limit = 30, period = 60 }
```

Nothing to click. It takes effect on the next `npx wrangler deploy`, keyed on
`cf-connecting-ip`, which Cloudflare sets at its edge and overwrites if a
caller sends their own — so it cannot be spoofed from outside.

**It is a stopgap, and weaker than the WAF rule it stands in for.** Three ways,
all worth knowing before trusting it:

- **It runs inside the Worker.** A WAF rule refuses a request at Cloudflare's
  edge, before any Worker is invoked. This one is checked after the request has
  been routed and the Worker has started, so a blocked request still costs an
  invocation. It bounds spend on Anthropic, which is the point, but it does not
  bound requests.
- **It counts per location, not globally.** Each Cloudflare colo keeps its own
  counter, so a caller spread across several sees a real ceiling somewhat above
  30 a minute. Approximately 30 is the honest description.
- **`period` accepts only 10 or 60.** 30-per-60 is the requested rate but a
  coarse shape: one caller can spend all thirty in the first second of a
  minute. There is no way to ask for a smoother five-per-ten-seconds.

**Replace it with a WAF rule once the proxy is on a domain**, using the steps
above, and delete the binding in the same change — running both would count the
same request twice.

Putting the proxy on a domain is worth doing for its own sake: a URL containing
the account name is one the app is stuck with for the life of every build that
ships it.

Thirty a minute is far above any reader. A lesson is a handful of requests and
the app is not a thing you can hold down. It is well below what scripting new
device ids needs to be worth doing.

Whichever route: check it took effect by sending 40 quick requests to
`/v1/status` with no token and watching the last of them come back blocked
rather than 401.

## Checking what it has cost

`GET /v1/status` reports the month's spend against the ceiling. It needs a token,
which you invent — any long random string. Set it once:

```powershell
npx wrangler secret put ADMIN_TOKEN
npx wrangler deploy
```

Then:

```powershell
curl.exe -s -H "x-spare-admin: YOUR_TOKEN" https://spare-proxy.mishabichashvili1998.workers.dev/v1/status
```

```json
{
  "month": "2026-08",
  "spentUSD": 0.041233,
  "ceilingUSD": 15,
  "withinCeiling": true,
  "freeGenerationPaused": false,
  "unrecordedReadings": 0,
  "clientTokenRequired": true,
  "trialStartEnabled": false
}
```

Add `?device=<id>` to include that device's daily and monthly counters.

Three states worth recognising, because they look similar and mean different
things:

| Response | Means |
|---|---|
| `405 methodNotAllowed` | The deployed Worker predates this endpoint. Redeploy. |
| `404 unknownEndpoint` | Deployed, but `ADMIN_TOKEN` isn't set. |
| `404 unknownEndpoint` on every *other* endpoint | `SPARE_CLIENT_TOKEN` is set and the caller isn't sending it. Expected before the app ships. |
| `401 unauthorized` | Token set, wrong one presented. |

The endpoint is read-only and GET-only. There is no way through it to reset a
counter or raise the ceiling — a token pasted into a terminal shouldn't be able
to unlock free generation, and changing a limit stays a deploy.

## Watching it

```powershell
npx wrangler tail                 # live requests, as they happen
```

The Cloudflare dashboard (**Workers & Pages** → **spare-proxy**) shows request
counts and error rates over time. Anthropic's own console shows what you've
actually spent — that's the number that matters, and it's the one to check first
if a bill surprises you.

## Deploying a change later

```powershell
cd C:\Users\misha\Spare\server
npx wrangler deploy
```

Secrets and the cache persist. You don't repeat Steps 3, 4, 5, or 9.

## If a deploy goes wrong

```powershell
npx wrangler rollback
```

Reverts to the previous version. Confirm when asked.

## If the Anthropic key is ever exposed

1. Revoke it at [console.anthropic.com](https://console.anthropic.com) → API Keys.
2. Create a new one.
3. `npx wrangler secret put ANTHROPIC_API_KEY` with the new value.

No app update is needed — the key only ever existed on the server, which is the
main reason the proxy exists.
