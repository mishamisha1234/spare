# First run on a Mac

Everything in Spare has been written on Windows and verified by CI, which
compiles the code and runs every test on a simulator. What CI cannot do is put
the app on a phone. This is the checklist for the first time it goes there.

Written for a few hours on a borrowed or rented Mac, assuming you are not a
developer. Every command is meant to be copied whole.

---

## Read this part before you book the Mac

**Two of the checks below cannot pass on a free Apple ID**, and knowing which
ones saves you the afternoon.

Signing an app on a free "personal team" costs nothing and takes two minutes.
But Apple only grants a limited set of *capabilities* to a free team, and
**App Groups is not one of them**. Spare's widget reads the app's library
through an App Group. Without it the widget runs, looks correct, and shows
nothing — so **check 5 (widget) and the shared-storage half of check 1 will
fail on a free team, and that is not a bug.**

The same applies to **StoreKit sandbox**: a true sandbox purchase needs a paid
membership and an App Store Connect record. What you *can* do on a free team is
the local StoreKit configuration in this repo, which exercises the real
StoreKit 2 code path — purchase, entitlement, restore — against fake products.
That is check 3, and it is worth doing.

So there are two useful sessions, not one:

| | Free personal team (today) | After enrolment (~$99/yr) |
|---|---|---|
| Checks 1–4, 6, 7 | Yes | Yes |
| Check 5 (widget) | No — expect "Unavailable" | Yes |
| Real sandbox purchase | No | Yes |

If enrolment is already done by the time you get the Mac, do everything. If not,
do the free-team session anyway: six of seven checks are real, and they are the
ones most likely to find something.

**How long:** installing takes 30–60 minutes, mostly Xcode downloading. The
checks take about an hour. Budget three hours for a first session.

---

## Part 1 — Install

You need macOS 14 or later. Check: `` menu → About This Mac.

**1. Xcode.** Open the App Store, search Xcode, install. It is roughly 10 GB and
is the slow part — start it first and do step 2 while it downloads.

When it finishes, open Xcode once and accept the licence. Then in Terminal:

```
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
```

**2. Homebrew and XcodeGen.** Terminal (⌘-Space, type "Terminal"):

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Follow its instructions at the end — it prints two lines to run that add it to
your PATH. Then:

```
brew install xcodegen
```

**3. The code.**

```
git clone https://github.com/mishamisha1234/spare.git ~/Spare
cd ~/Spare
```

**4. Generate the Xcode project.** There is no `.xcodeproj` in the repo; it is
generated from `project.yml`, which is why the two never disagree.

```
cd ~/Spare
./bootstrap.sh
```

That installs XcodeGen if missing, generates `Spare.xcodeproj`, and opens it.

---

## Part 2 — Prove it builds before you touch signing

Run the whole test suite on a simulator first. No signing, no device, no Apple
ID. If this fails, stop and send me the output — nothing below will work
either.

```
cd ~/Spare
xcodebuild test -project Spare.xcodeproj -scheme Spare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 2>&1 | tail -40
```

If it complains that iPhone 16 does not exist, list what you have and use one
of those names:

```
xcrun simctl list devices available
```

**Expected:** `** TEST SUCCEEDED **` near the end. Takes 10–15 minutes.

---

## Part 3 — Sign with a free personal team

1. In Xcode, if the project is not open: `open ~/Spare/Spare.xcodeproj`
2. Xcode → Settings → Accounts → **+** → Apple ID → sign in with your ordinary
   Apple ID. No payment, no enrolment. Close Settings.
3. Click **Spare** at the very top of the left sidebar (the blue icon), then in
   the main panel pick the **Spare** target → **Signing & Capabilities** tab.
4. Tick **Automatically manage signing**. In **Team**, choose
   *"Your Name (Personal Team)"*.
5. **Bundle Identifier** is `app.spare.ios`. If Xcode says it is unavailable,
   change it to something unique — `app.spare.ios.yourname` — and do the same
   for the widget in step 6, using `app.spare.ios.yourname.widget`.
6. Repeat 3–5 for the **SpareWidget** target.

**What you will see, and it is expected:** a red error on both targets saying
personal teams do not support the App Groups capability. Leave it. The app
still builds and runs; only the widget's view of the library is affected, which
is check 5.

> If you re-run `./bootstrap.sh` at any point, the project is regenerated and
> steps 3–6 must be done again. That is the cost of not committing a
> `.xcodeproj`, and it is deliberate.

**Put it on the phone.** Plug in your iPhone with a cable. Unlock it and tap
Trust. In Xcode's toolbar, choose your phone from the device menu (next to the
Spare scheme), then press **▶**.

The first run fails with "Untrusted Developer". On the phone: Settings →
General → VPN & Device Management → tap your Apple ID → Trust. Press ▶ again.

> A free-team app stops launching after **7 days**. Re-press ▶ to renew it.

---

## Part 4 — The checks

Do them in order; later ones depend on earlier ones. For each, I have said what
"wrong" looks like, because several of these fail *quietly* — the screen looks
fine and the content is subtly not what it should be.

**Before you start**, in the app: Settings → make sure the proxy is reachable by
generating one lesson. If every generation fails with a network error, the
Worker is down or the URL in `Spare/Info.plist` is stale — send me the error
text from the reader screen and stop.

---

### Check 1 — App Group / shared storage

**Do:** open the app → **Settings** → scroll to **Widget**.

**Pass (paid team):** Shared storage says **Available**.

**Pass (free team):** it says **Unavailable**, with the explanation underneath.
That is the correct result for a free team and confirms the diagnostic works.

**Wrong:** the Widget section is missing entirely, or it says Available on a
free team (which would mean the entitlement check is lying).

**Send me:** the two lines under "Widget", verbatim.

---

### Check 2 — One lesson at each of the five durations

This is the main event: the first time the real prompts, the real pipeline and
the live proxy run against a real phone.

**Do:** from Home, tap each circle in turn — **1, 3, 7, 15, 30** — pick any
suggestion, and read to the end. The 1-minute and 15-minute circles are premium
and will open the paywall; do check 3 first if you want to get past them, or
just confirm the paywall appears and come back.

For each one, note the **reading time shown at the top of the reader** and
whether the text stops abruptly.

**Pass:** five lessons, each roughly the length its circle promised:

| Circle | Expect roughly | Definitely wrong if |
|---|---|---|
| 1 min | 180–240 words | under 160 |
| 3 min | 500–650 | under 450 |
| 7 min | 1,100–1,400 | under 990 |
| 15 min | 2,400–3,000 | under 2,160 |
| 30 min | 4 chapters, 6,000–6,400 total | any chapter under 1,350 |

**Wrong, and the most important thing to catch:** a lesson that is *much*
shorter than its circle. The whole word-floor mechanism exists to make that
impossible — under 90% of the floor should be refused and retried, not served.
If you see one, that mechanism is not working on the live path.

Also wrong: text that stops mid-sentence (truncation), or a course where two
chapters say the same thing (a cache-key fault).

**Send me:** for each of the five, the circle, the lesson title, and the reading
time shown. If any looked short, the first and last sentence too.

---

### Check 3 — StoreKit purchase and restore

The scheme is already wired to `Products.storekit`, so pressing ▶ from Xcode
gives you two fake products with no account and no charge: monthly £12.99 and
yearly £89.00. The yearly carries an introductory first year at £44.50, which
a fresh install is eligible for — so the row should read *"£44.50 for your
first year, then £89.00"* and the button should quote £44.50, not £89.00. If
it quotes £89.00 on a device that has never subscribed, the eligibility check
is reading the wrong way round and that is worth telling me about.

**Do:**
1. Trigger the paywall — tap the **1-minute** circle, or **Take the test** on a
   finished lesson.
2. Buy **Yearly**. Confirm with the fake sheet.
3. The paywall should dismiss itself.
4. Go to **Settings** → the plan row should say you are on Premium.
5. Force-quit the app (swipe up) and reopen. Still Premium?
6. In Settings, use **Restore purchases**.

**Pass:** paywall dismisses on purchase; Settings shows Premium; it survives a
relaunch; restore leaves you Premium and does not error.

**Wrong:** the sheet succeeds but the paywall stays open (the entitlement is not
reaching the app); Premium is lost on relaunch (it is not being persisted);
restore throws.

**Send me:** what Settings' plan row says after each of steps 4, 5 and 6.

---

### Check 4 — A purchase made *on the completion screen*

Separate from check 3 on purpose. This is the path that was broken until
recently: buying premium while looking at a finished lesson used to leave that
lesson — the one you had just paid to be tested on — permanently without a test.

**Do:** you must start from a *free* state. Delete the app from the phone and
re-run from Xcode. Then:

1. Read one 3-minute lesson all the way to the completion screen.
2. On that screen, tap **Take a 3-question test**. It is locked, so the paywall
   opens.
3. Buy **Monthly**.
4. The paywall dismisses and you are back on the same completion screen.
5. Wait about five seconds, then tap the test button again.

**Pass:** the test opens with three questions and you can answer them.

**Wrong:** *"No test for this one — this lesson was saved without a test."*
That is the exact bug this check exists for. If you see it, wait ten seconds and
tap once more; if it still says that, it has regressed.

**Send me:** pass/fail, and if it failed, whether a second attempt worked.

---

### Check 5 — Widget on a real home screen

**Skip on a free team.** Check 1 will have told you.

**Do:** long-press the home screen → **+** → search "Spare" → add the medium
widget.

**Pass:** it shows something drawn from your library — a due question, or the
duration chips. Tapping a chip opens the app on that length's suggestions.

**Wrong:** it shows zeroes or an empty state *while the app's library has
lessons in it*. That is the App Group not connecting the two processes, and it
is exactly what check 1 predicts.

**Send me:** a photo of the widget, plus how many lessons your library has.

---

### Check 6 — Notification delivery

**Do:** Settings → **Recall reminder** → tap **Send a test reminder in
10 seconds** (a debug-build-only button). Allow notifications when asked. Then
**lock the phone** — iOS suppresses banners while you are looking at the app.

**Pass:** a Spare notification appears on the lock screen within ~15 seconds.

**Wrong:** nothing arrives. Check Settings → Notifications → Spare on the phone
first; if permission was denied, that is the cause and not a bug.

**Send me:** whether it arrived, and how long it took.

> The real reminder is the next day at a time you choose. This button exists so
> the plumbing can be tested in one sitting.

---

### Check 7 — The library survives a relaunch

**Do:** note how many lessons are in Library. Force-quit, reopen, look again.

**Pass:** the same lessons, same order, still readable offline (turn on
Aeroplane Mode and open one).

**Wrong:** an empty library after a relaunch means the SwiftData store is not
being written where the app looks for it — send me this immediately, it affects
everyone.

---

## What to send back

A single message is fine:

```
Mac session, <date>, <free team | paid team>

Part 2 simulator tests: PASS / FAIL
1  App Group:        Available / Unavailable / section missing
2  Five durations:   1min <title> <N min> ... (all five)
3  StoreKit:         purchase / relaunch / restore — pass or what happened
4  Buy on completion:PASS / FAIL (and whether a retry worked)
5  Widget:           PASS / FAIL / skipped (free team)
6  Notification:     arrived in Ns / did not arrive
7  Library persists: PASS / FAIL

Anything that looked odd but was not on the list:
```

Screenshots of anything that looks wrong are worth more than a description —
especially for check 2, where "short" is the failure and it does not announce
itself.

---

## If something goes badly wrong

- **Build fails after `./bootstrap.sh`** — send the last 40 lines of the Xcode
  error, not a screenshot of the red dot.
- **"No account for team"** — you skipped Part 3 step 2.
- **App will not launch on the phone** — the 7-day free-team profile expired.
  Press ▶ in Xcode again.
- **Everything fails with network errors** — the Worker may be down. From the
  Mac: `curl -s -o /dev/null -w '%{http_code}\n' https://spare-proxy.mishabichashvili1998.workers.dev/v1/lesson -X POST` should print
  `400` (it refuses an empty body). Anything else, or a hang, means the Worker
  is the problem and not the app.
