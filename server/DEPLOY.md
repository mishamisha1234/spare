<title>Spare Proxy Deployment</title>

# Deploying the Spare proxy

A step-by-step guide for Windows. Every command goes in **PowerShell**. After
each step there's a "you should see" — if you see something else, stop there
rather than continuing, because most later steps depend on the earlier ones
having worked.

Nothing here can be done for you: every step needs an account only you can log
into.

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

The spend ceiling is set to **$50/month** in `wrangler.toml`. Past it, free
generation is served from the cache instead of the model; subscribers keep
working, because their requests are paid for. Nothing breaks — costs stop
climbing.

To change it, edit `MONTHLY_SPEND_CEILING_USD` in `wrangler.toml` and redeploy.
Treat it as a smoke alarm rather than a budget: if it ever trips, something is
wrong, not busy.

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
  "ceilingUSD": 50,
  "withinCeiling": true,
  "freeGenerationPaused": false
}
```

Add `?device=<id>` to include that device's daily and monthly counters.

Three states worth recognising, because they look similar and mean different
things:

| Response | Means |
|---|---|
| `405 methodNotAllowed` | The deployed Worker predates this endpoint. Redeploy. |
| `404 unknownEndpoint` | Deployed, but `ADMIN_TOKEN` isn't set. |
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
