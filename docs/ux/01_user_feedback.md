# 01 — What real users say about OpenStrap Edge UX

Researched 2026-10-10. Read-only. Nothing posted anywhere.

## Sources and coverage

| Source | Reached? | Volume |
|---|---|---|
| GitHub OpenStrap/edge issues (open + closed), all comments | yes | 124 issues |
| GitHub OpenStrap/edge discussions + replies (GraphQL) | yes | 33 discussions |
| GitHub PR titles (414) + bodies of 8 UX PRs (#146 #151 #253 #373 #510 #513 #540 #542) | yes | |
| Hackaday article + 13 comments | yes | 0 UX comments (all about WHOOP subscription / firmware) |
| TechRadar, Android Authority, Android Police, Yahoo Tech press | blocked (403 / Cloudflare / 404) or launch-coverage only | 0 usable UX quotes |
| Reddit (r/OpenStrap exists per search; r/whoop) | NOT reachable: WebFetch refuses reddit.com, reddit JSON API returns HTML wall, Chrome extension blocks reddit | 0 |
| Discord (maintainer routes users there repeatedly: issues #14, discussion #264) | not reachable (no access) | 0 |
| App Store / Play / F-Droid | no listing exists (TestFlight + GitHub APK/IPA only; F-Droid is an open request, #461) | 0 |

**Gap to flag up front.** The owner's premise "people are hating graphs" does not show up as a direct
quote in any reachable public source. GitHub has graph complaints (below) but they are about
inconsistency, missing axes, scrubbing bugs and charts that contradict the headline number, not "I hate
graphs". The likely home of that sentiment is Discord or r/OpenStrap, which I could not read. Someone
with Discord access should export the #feedback / #bugs channels and run the same tagging.

**Staleness caveat.** Most issues below are CLOSED as "fixed in latest release". A closed issue is
evidence of what users hit, not proof the current build is clean. Several were closed by the
maintainer without the reporter confirming. Pair this file with the code-audit agents' findings.

## Legend

- Text in `> quote` blocks is copied verbatim from the source (typos kept).
- Lines starting **Interpretation:** are mine.
- **Users** = distinct GitHub accounts raising the same point (maintainer `abdulsaheel` excluded unless he
  is relaying a user). Contributors filing on behalf of a reporter are noted.

## Complaint catalogue, part A (graphs, numbers, trust)

### A1. Graphs: same data drawn differently, no axes, scrub bugs, charts that contradict the headline
Users: 4 (localhoop, cb0806151, markpiggott-ctrl, DropTabl) + 1 contributor PR (highdeftant #373 added a selection cursor)
> Heart rate HR graph is different in 3 different places [...] I think there is little reason to have different graphs showing exactly the same thing in such slightly different ways.
— localhoop, https://github.com/OpenStrap/edge/issues/102
> the through the day graph is totally useless? No scale on X nor on y.
— localhoop, #102 (split out as https://github.com/OpenStrap/edge/issues/148)
> when I pass my finger the dots do not align at all with the graph and the granularity is totally different too. Also the legend appears only when you pass your finger which makes the graph takes more height and is trippy
— localhoop, #102 (split out as https://github.com/OpenStrap/edge/issues/141)
> That's definitely a bug, it shouldn't be showing 0.6 strain on a workout and then a flat line on the chart.
— cb0806151, https://github.com/OpenStrap/edge/issues/471
> the message below the strain chart indicates the chart only accumulates and yet it clearly deteriorates over the course of the day
— cb0806151, https://github.com/OpenStrap/edge/issues/296
> Three vertical lines in most of the charts? These are technically update/recalculation lines but that doesn't make sense
— cb0806151, https://github.com/OpenStrap/edge/discussions/500
> A day whose timeline is entirely Z1 can have its bar chart report Z2.
— DropTabl (contributor), https://github.com/OpenStrap/edge/issues/333
**Interpretation:** the graph complaint on record is "charts disagree with each other and with the big number, and I can't read them" (no axes, unexplained marks, layout jumping on touch). That is a consistency and labelling problem more than a chart-type problem.

### A2. Confident numbers on too little data; inconsistent empty states ("—" vs 0 vs 100)
Users: 4 (localhoop, dannymcc, gerageragarza-prog, ramishroshan)
> After like 10minutes of data the app shows readiness 100. That sounds like BS
— localhoop, #102
> The app cannot make up its mind between how to show too little data situations. Sometimes it shows garbage data (too little window confidence), sometimes "-", sometimes 0, etc.
— localhoop, #102
> The ring shows **100** for a moment, then updates to the real score.
— dannymcc, https://github.com/OpenStrap/edge/issues/117
> Day Strain already showed 7.3 (of 21) despite not having done any physical activity yet today.
— gerageragarza-prog, https://github.com/OpenStrap/edge/issues/226 ("Same for me. it must be a bug." — ramishroshan)
> with only like 20 mins of data it already claims irregular pattern. I recommend you try to cut down a lot of claims when lacking data, otherwise it looks sloppy.
— localhoop, #102

### A3. Scores vanish, flicker or change during the day; morning numbers wrong until sync catches up
Users: 5 (davidfleischmann, cb0806151, user "RR" relayed by dannymcc, gentbot, DropTabl)
> The readiness figure on the home screen keeps going blank for no reason
— davidfleischmann, https://github.com/OpenStrap/edge/issues/106
> within an hour the app will remove it and act like it's still calculating
— cb0806151, https://github.com/OpenStrap/edge/discussions/167
> in the morning my readiness score was 49, now it changed to 45.
— user RR quoted by dannymcc, https://github.com/OpenStrap/edge/issues/128
> Almost every day I'm fighting with sync times for an accurate sleep record/recovery score [...] (which in some cases is 4-5 hours after I wake up)
— cb0806151, https://github.com/OpenStrap/edge/issues/448
> the explanation was either a raw debug string or "Nothing recorded says why".
— gentbot (PR author, describing the "not scored" state), https://github.com/OpenStrap/edge/pull/510
Also: DropTabl #303/#305 (Recovery permanently "Not scored", blank after crossing the baseline threshold).
**Interpretation:** the most-repeated daily-use frustration. Users want a clear "still syncing, final score at X" state rather than a number that moves or disappears.

### A4. Strain does not behave like WHOOP strain (drops during day, shows 0 after workouts)
Users: 3 (cb0806151, markpiggott-ctrl, gerageragarza-prog via #226)
> I'm used to the whoop app where strain builds throughout the day and never goes down.
— cb0806151, #471
> Confused how strain can be 0 when I've done activities and workouts ?
— markpiggott-ctrl, #471 (still OPEN)
**Interpretation:** a deliberate model choice (PR #308) that users read as a bug. Either the metric needs a different name or the copy has to explain it on the card itself.

### A5. Recovery score feels wrong / doesn't move; users can't see why
Users: 2 (ramishroshan, gerageragarza-prog)
> The recovery algorithm yields a mid-range score (56/100) that contradicts the underlying physiological data.
— ramishroshan, https://github.com/OpenStrap/edge/issues/250
> Edge's Recovery score almost always stays in the ~50 range or lower, regardless of how I actually feel or how I'm training.
— gerageragarza-prog, https://github.com/OpenStrap/edge/issues/543 (OPEN)
**Interpretation:** partly algorithmic, but the UX part is that the screen doesn't show which input pulled the score down.

### A6. Jargon, mislabelled or unexplained metrics
Users: 4 (localhoop, ramishroshan, flexagoon, cb0806151)
> I am confused at total calories claim. [...] (Update: the number changed so it is not static, I have no idea what it means)
— localhoop, #102
> Why is calories under training _load_? That makes no sense
— localhoop, #102
> We have no idea what unit it is in or what it represents and trying to show that is wrong.
— localhoop on the Oxygen metric, #102
> OpenStrap Edge App (Overnight HRV - RMSSD, asleep): ~96 ms [vs] Bevel App (Resting HRV ...): ~197.3 ms
— ramishroshan, https://github.com/OpenStrap/edge/issues/315 (OPEN)
> are the metrics (eg. sleep score, recovery/strain, body age, ...) are computed with the same algorithms as in NOOP
— flexagoon, https://github.com/OpenStrap/edge/discussions/220
Maintainer's own PR #146 confirms shipped issues: two different "baseline" labels on one screen, LF/HF shown at 6 decimal places, a literal "null" for oxygen dips.
**Interpretation:** the app exposes research terms (RMSSD, LF/HF, SD1/SD2, TRIMP-derived load) without plain-language framing, and users compare numbers against other apps without knowing what's measured.

## Complaint catalogue, part B (navigation, onboarding, control, notifications)

### B1. Can't find features that exist (discoverability after the UI rebuild)
Users: 6 (bmwagner18, aurashutt-ship-it, egoran2, alsenanA, gerageragarza-prog, highdeftant)
> The new UI doesn't appear to have the same functionality as the old UI around adding custom items for tracking in the journal.
— bmwagner18, https://github.com/OpenStrap/edge/issues/273
> now it seems to have been completely removed.
— aurashutt-ship-it on period tracking, https://github.com/OpenStrap/edge/issues/449; reply from mikenrafter: "It's in settings, labeled "Cycle Tracking". It's disabled by default now."
> How can I manually add a nap?
— egoran2, https://github.com/OpenStrap/edge/discussions/203; maintainer: "bottom of sleep screen btw" (same answer to alsenanA, https://github.com/OpenStrap/edge/discussions/215)
> Target strain is there under body tab.
— ramishroshan answering gerageragarza-prog, who had asked for exactly that, #226
> Doesn't this already exist in the top left section?
— gentbot answering highdeftant's battery-on-Home request, https://github.com/OpenStrap/edge/issues/376
> Am I missing the option to delete a workout after it was stopped?
— bmwagner18, https://github.com/OpenStrap/edge/discussions/272
**Interpretation:** strong signal. At least 6 requests were for things already in the app, buried at the bottom of a screen, behind a settings toggle, or in small header text.

### B2. History / trends: can't page back through past days or see a metric over time
Users: 5 (alsenanA, ngr7340, cb0806151, saschajan, markpiggott-ctrl)
> I should be able to see my previous days, week, month steps instead.
— alsenanA, https://github.com/OpenStrap/edge/issues/21
> It would be very helpful when you can see past days lookback data for each day.
— ngr7340, https://github.com/OpenStrap/edge/issues/112
> if this day switcher could be added to all the data pages that'd be awesome
— cb0806151, https://github.com/OpenStrap/edge/issues/161
> What was my score yesterday, on Friday, or last week?
— saschajan, https://github.com/OpenStrap/edge/discussions/229
> a screen that shows all the recorded HR data, and be able to filter by day / time.
— markpiggott-ctrl, https://github.com/OpenStrap/edge/issues/546 (OPEN)

### B3. First run / onboarding: meaningless copy, dead ends, lock-outs, no feedback
Users: 5 (localhoop, rube-de, cb0806151, saschajan, Brackyt)
> "543 raw data collected". This means nothing to the user.
— localhoop, #102 (fixed per #139)
> "Good afternoon your morning briefing will appear here". What morning briefing if I just put the strap on [...] unclear to me if this features requires an AI key
— localhoop, #102
> No matter how many times I click this "sync the band >" nothing happens
— cb0806151, https://github.com/OpenStrap/edge/issues/270; saschajan: "I miss the loading indicator from the previous version." and "My home screen is mostly empty, no data is shown"
> no way past it except a successful live BLE bond
— rube-de on the pairing screen, https://github.com/OpenStrap/edge/issues/252
> Was hard to get it to connect.
— Brackyt, https://github.com/OpenStrap/edge/discussions/178

### B4. Error and status messages with no next step
Users: 4 (cb0806151, dannymcc, gentbot, saschajan)
> I have no directions as to what to do about it (no link to report it, no troubleshooting guide
— cb0806151 on the Rhythm warning and wear-time message, #161
> There doesn't seem to be a way of now changing the model and I don't know which model is acceptable.
— dannymcc, https://github.com/OpenStrap/edge/issues/94
> is there a reason for that time delay?
— cb0806151 on sync lag, https://github.com/OpenStrap/edge/discussions/331

### B5. Can't correct the app when it's wrong (sleep, naps, workouts)
Users: 8 (rube-de, alsenanA, egoran2, epyonavenger, bmwagner18, abdulsaheel-relayed #147, localhoop, TheHangMan97)
> There is no way to tell the app it got it wrong.
— rube-de, desk work logged as a nap, https://github.com/OpenStrap/edge/issues/248
> it seems to think I am taking a bunch of naps, instead of sleep
— epyonavenger (night-shift worker), https://github.com/OpenStrap/edge/discussions/364
> I got it triggered by just walking a bit lol). Consider an option to disable autodetection.
— localhoop, #102 → #149
> the only reachable action on it was **delete**.
— #147 (can't stop a workout after restart)
Still OPEN: TheHangMan97, "Not sleep" correction not applied after full reanalysis, https://github.com/OpenStrap/edge/issues/566

### B6. Notifications: repeat, wrong, or don't open the right screen
Users: 3 (davidfleischmann, markpiggott-ctrl, dannymcc); 7 issues
> I am constantly getting notifications about irregular heart rhythm.
— davidfleischmann, https://github.com/OpenStrap/edge/issues/136 (also #138 low readiness, #179 "band is on the charger")
> selecting the notification doesnt take the user to the page where the automatically detected activity can logged or adjusted.
— davidfleischmann, https://github.com/OpenStrap/edge/issues/113 (same ask: markpiggott-ctrl #465)
> Edge will send a notification during the workout that says nothing above resting effort has been recorded, even when you are exercising.
— markpiggott-ctrl, https://github.com/OpenStrap/edge/issues/466

### B7. Home screen: wants a single at-a-glance summary; clutter and duplicates
Users: 5 (gerageragarza-prog relaying a non-GitHub user, saschajan, davidfleischmann, MatteoFari, highdeftant)
> This would give users a single glance at strain/recovery/sleep status without navigating to separate tabs
— gerageragarza-prog, rings proposal, https://github.com/OpenStrap/edge/issues/236
> There is multiple duplicates on the briefing page with Morning Briefing and User Safety being mentioned twice
— davidfleischmann, https://github.com/OpenStrap/edge/issues/107
Also #470 (MatteoFari, next alarm on Home), #376 (battery on Home), PR #540 (Home card said "nothing to review" every day).

### B8. Smaller items (1 user each unless noted)
- Nutrition tab "a bit hard to use": no search over past meals, can't backdate or edit entries, protein target not shown for today — andigandhi, https://github.com/OpenStrap/edge/issues/559 (OPEN).
- Visual: > Black icons do not have a lot of "health" vibe. — localhoop, #102. Same post: workout screen has "a little bit too many animations", finish button overlaps the Android nav bar, "Data History select days text looks clickable but isn't", companion URL overflows.
- Lookback icon is misleading: > Lookback icon shows a hearth and a HR graph, but clicking it leads to a general recap page. — localhoop, #102. Recap chips "look like a graph legend", not buttons.
- Android Back left the app instead of returning to the previous tab — MatteoFari, PR #542.
- Language: i18n asked for by 3 users (victorargento, julien-ZR-GTH, gerageragarza-prog), https://github.com/OpenStrap/edge/discussions/243. Tab labels were hardcoded English until PR #513.
- No strain target guidance: > the Day Strain card just shows the current number with no guidance — gerageragarza-prog, #226.
- 24h clock (andigandhi #476, shipped).

### Positive feedback (for balance)
> I like this app appearance more than the other open source project (though the other option is more stable)!
— alsenanA, #21
> The app looks amazing on iOS!
— alsenanA, https://github.com/OpenStrap/edge/issues/6
> New build 0.9.27 looks really cool I like design updates
— julien-ZR-GTH, discussion #243
> overall the vibe and visual coherence of the app is quite solid.
— localhoop, #102
**Interpretation:** the visual style is liked; complaints are about meaning, trust and findability.

## Ranked top 10 pain points (frequency x severity)

Severity (my judgment): 3 = makes users distrust the core numbers or blocks use; 2 = recurring friction; 1 = polish.
Frequency = distinct users from the catalogue above. Score = users x severity. Status reflects GitHub state, not a re-test.

| # | Pain point | Users | Sev | Score | Status on GitHub |
|---|---|---|---|---|---|
| 1 | Can't correct the app when it's wrong (false naps, night shift, noisy auto-workouts, stuck workouts) (B5) | 8 | 2 | 16 | mostly fixed; #566 open |
| 2 | Scores blank out, flicker or shift during the day; morning score wrong until sync catches up (A3) | 5 | 3 | 15 | partly fixed; #448 closed w/o confirmation |
| 3 | Features exist but users can't find them (B1) | 6 | 2 | 12 | structural, not tracked as an issue |
| 4 | Graphs disagree with each other and the headline; missing axes; scrub/legend jumps; unexplained marks (A1) | 4 | 3 | 12 | #141/#148 closed; #471 open |
| 5 | Confident numbers on too little data; mixed "—"/0/100 empty states (A2) | 4 | 3 | 12 | fixed per maintainer |
| 6 | No history / day-paging / trend view for metrics (B2) | 5 | 2 | 10 | day switcher shipped (#382); #546 open |
| 7 | First run: meaningless copy, dead sync button, empty Home, pairing lock-out (B3) | 5 | 2 | 10 | fixed per maintainer |
| 8 | Strain goes down / reads 0 after workouts, unlike WHOOP (A4) | 3 | 3 | 9 | #471 open; behaviour is by design (#308) |
| 9 | Jargon and unexplained metrics (RMSSD vs other apps, calories, oxygen units, baselines) (A6) | 4 | 2 | 8 | #315 open |
| 10 | Errors and warnings with no next step (B4) | 4 | 2 | 8 | partly addressed by PR #510 |

Just below the cut: notifications repeating / not deep-linking (B6, 3 users, score 6) and Home at-a-glance + duplicates (B7, 5 users, sev 1, score 5).

**Interpretation, overall.** The written record does not say "the graphs are ugly". It says the numbers and charts can't be trusted at a glance: they move, vanish, contradict each other, use terms users can't map to WHOOP, and the app doesn't say why or what to do. Second theme: things are hard to find. Reddit and Discord, where the "hating graphs" sentiment probably lives, were not readable from here.
