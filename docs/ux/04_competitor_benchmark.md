# 04 · Competitor UX benchmark (wearable health apps, 2025-2026)

Research date: 2026-10-10. Read-only web research; no repo edited. No screenshots were viewed;
nothing below describes pixels I did not see described in a source.

## 0. Evidence key and method

- **[O] observed**: stated in a page I fetched and read (publisher, vendor blog, or review).
- **[S] search-only**: came from a search-engine result summary; the page itself was not fetched
  (usually because it returned 403/410). Treat as likely but unverified.
- **[I] inferred**: my reasoning from the observed facts. Not a claim about the product.

whoop.com blocks automated fetches (403 / Cloudflare challenge, tried WebFetch and curl), so
every WHOOP detail is [S] or from third-party reviews. Oura's own blog fetched fine.
Quotes are only reproduced where a fetched page (or a quoted search snippet, labelled) gave them.

---

## 1. Per-app benchmark

### 1.1 WHOOP (5.0 / MG, app redesign shipped with 5.0 on 2025-05-08)

- **Home/Today**: three separate dials at the top (Sleep, Recovery, Strain), each opening a
  "deep dive" page that shows what contributes to the score. Weekly Plan on Home. [S, whoop.com
  "the all new whoop home screen"; date of three-dial home = 5.0 launch per the5krunner, O]
- Below the dials: a coaching panel ("Three circular dials... A coaching panel beneath", as
  paraphrased from the lawsuit in the5krunner). [O]
- **Trends**: HRV/RHR ranges for last 30 or 90 days ("Data Highlights"); 30-day and 180-day
  change for respiratory rate and RHR in Health Monitor. [S]
- **Score explanation**: Recovery from HRV, RHR, sleep performance, respiratory rate (plus
  SpO2/skin temp displayed). HRV framed as relative to *your* baseline, not population. [S]
- **Provisional data**: first ~4 days the recovery score is **greyed out** while WHOOP learns
  your range; full baseline ~30 days; Healthspan needs 21 logged recoveries/sleeps in month one,
  fully calibrated at 90 days. [S, WHOOP community + podcast]
- **Long-horizon**: Healthspan (WHOOP Age, Pace of Aging, weekly). AI Coach. [O, plunge.com]
- **Criticism**: 2023 home redesign was "a sleek and useful improvement" but "new users of WHOOP
  may find the amount of information on the screen daunting" and "navigating to more detailed
  insights is not always intuitive". [O, the5krunner 2023]. 2025 backlash was about upgrade
  fees, not UI [O, plunge.com]. Promotional content alongside health data was a noted
  complaint [S].

### 1.2 Oura (app redesign announced 2025-10-20, rolling from Oct 16)

- **Structure**: five tabs condensed to three: Today, Vitals, My Health. [O, ouraring.com blog]
- **Today**: shortcuts to Sleep, Readiness, Activity scores at the top, plus heart rate,
  Daytime Stress, Cycle Insights; a "Daily highlight" chosen by time of day; a Timeline of the
  day where you add tags/activities. Press framed it as "One Big Thing". [O]
- **Color as state**: parts of the app "change color depending on biometrics". [O, 9to5google]
- **Vitals**: all key metrics on one screen with **baseline ranges** so you "know what's normal
  for you and when your metrics start to shift"; down-arrow reveals top contributors, side-arrow
  opens metric detail. [O, Oura blog]
- **My Health**: slow metrics (Cardiovascular Age, Stress Resilience) as graphs; weekly,
  quarterly, yearly reports with shareable versions for clinicians. [O]
- **Score explanation**: Readiness = seven contributors in sleep / activity / body-stress
  pillars. Each contributor has a plain-language question, e.g. Sleep Balance: "Have I been
  getting enough sleep in the last 2 weeks?". Contributor bars are colour-coded; "Pay attention"
  contributors get a red bar; Optimal = 85-100, Pay attention = 0-59. [S, Oura support/blog]
- Contributors compare a 14-day weighted average (last 2-5 days weighted more) to a ~2-month
  long-term average. [O, Oura support]
- **Criticism of the redesign**: App Store review analysis (Kimola) summarised as confusing UI
  that "obscures important data"; quoted reviews: "You cannot pull or view any previous day in
  any type of user friendly way" and reports "replaced with convoluted ads and 'conversation
  topics'". [S, page now 410]. Separately, a 2026 bug left Sleep/Readiness **blank** while HR
  data existed (fixed in 7.18.2). [O, gadgetsandwearables headline/summary, S for detail]

### 1.3 Bevel (Apple Watch / Health data, no hardware)

- **Home**: Strain, Recovery, Sleep as "visual circles" at a glance; users can **edit home
  screen cards**. [O, screensdesign teardown]. Five headline metrics in 2026: Recovery, Sleep,
  Strain, Stress, Energy Bank. [O, kiledjian 2026-07]
- **Explanations**: "Informational overlays and 'Learn More' sections... providing context
  without cluttering the main UI". [O, screensdesign]
- **Onboarding**: 34 steps; it "doesn't just ask what you want to improve but immediately shows
  how it will help", paywall at the end. [O, screensdesign]
- **Praise**: "polished, easy to scan and more actionable than Apple Health alone";
  consolidation of many domains. Light/dark plus illustrative or minimal backgrounds; playful
  morphing mood slider. [O]
- **Criticism**: tries too much ("ambitious"); AI coaching mixed ("generic advice, slow
  responses... occasional inaccuracies"). [O, kiledjian]
- **Legal**: WHOOP sued Bevel (Finerpoint) 2026-03-17, D. Del. 1:2026cv00289, Lanham Act trade
  dress + patent + copyright, over "nearly identical dashboards". Bevel cites its own
  three-circle layout posted 2023-12-29, ~17 months before WHOOP 5.0. Pre-trial. [O/S, the5krunner,
  wearablexp; docket on Justia, S]. See §5.

### 1.4 Apple (Fitness, Health, Vitals on watchOS 11+; iOS 27 Health redesign)

- **Fitness Trends**: one arrow per metric (up/down), each in its own colour, comparing last 90
  days with last 365 days. Needs 180 days of data before it shows. Macworld: "It's incredibly
  simple, and that's the whole point." [S, Apple support + Macworld via search]
- **Vitals app**: overnight HR, respiratory rate, wrist temp, SpO2, sleep duration. Each marked
  **Typical** or **Outlier** against your own recent range; one gentle notification only when
  2+ vitals are outliers; may suggest causes (alcohol, elevation, illness). [S, multiple]
- **iOS 27 Health redesign** (announced, in 27.2 testing, per MacRumors 2026-10-06): Insights
  tab with AI summaries ("your latest sleep metrics or a new peak in VO2 max"), Longevity tab,
  Readiness score on a 0-10 scale with recovery guidance, Health Age, Vitals with overnight and
  daytime breakdowns. [O, MacRumors]. Not shipped to general release at time of writing; I have
  not seen its visuals.

### 1.5 Garmin Connect (Today / My Day, redesign from Jan 2024, still current)

- **Structure**: Today's Activity (done + scheduled workouts) at top; **In Focus**: up to five
  swipeable panels for chosen topics (Training Status, Stress...); **At a Glance**: up to 8
  small metric cards; "Edit Home" at the bottom to pin/remove. [O, DC Rainmaker walk-through]
- **Praise**: answers the old "cluttered and full of confusion" complaint; "simpler and more
  clear" with "quick-links to a deeper look". [O, DC Rainmaker]
- **Criticism**: simplification hid numbers power users wanted; Training Status lost "the actual
  training load #" in favour of generic words. [O, DC Rainmaker]
- **Missing data**: Body Battery / stress timeline colours rest blue, stress orange, and **grey
  for "too active to determine"** stress, i.e. unknown is drawn as its own state, not as zero
  or as a gap. [S, Garmin manuals]

### 1.6 Ultrahuman (Emerald update, July 2026; first full redesign in four years)

- **Home**: UltraSphere "decision engine" at the centre, turning data into 60+ suggested actions
  (e.g. "getting outside for morning light") adapted to location, weather, circadian phase. [O]
- **Tabs**: Jade AI gets its own tab; Longevity tab (UltraAge, Pulse Age, Blood Age, Brain
  Age); a **Windows** view puts time-sensitive items (caffeine timing, circadian phases) on one
  daily timeline; Sleep Screener combines sleep metrics into "one nightly view". [O,
  gadgetsandwearables]
- **Offline / on-device**: sleep, recovery, movement scores calculate on the phone with no
  internet; live HR, stress, steps and recommendations stay available offline. [O]
- Light and dark modes added. [S]

### 1.7 Athlytic (Apple Watch)

- **Home**: four metrics: Recovery, Exertion, Sleep, Energy Burned. Tapping Exertion shows the
  current level plus activities that would reach the target. [O, ibikerun review]
- **Baseline**: recovery is HRV-first against a 60-day personal rolling baseline. [S]
- **Criticism**: suggestion "run for 50 minutes" without saying steady or intervals; recovery
  read as full after hard climbing ("70% of the way there"). Design described as dated;
  "gradients work against the data and add visual noise". [O for ibikerun; S for design quotes]
- **Praise**: glanceable, readiness checked in under 10 seconds (vendor/review claim). [S]

### 1.8 Gentler Streak (2024 Apple Design Award, Social Impact)

- **Activity Path**: a green horizontal band with your workload trend line inside it; too-hard
  days push the line out of the top, too-easy days below the bottom. Goal is to stay in the
  band, not to max out. [S, iMore/Yahoo summaries]
- **Redesign**: four tabs to three; "Streak" screen with the Activity Path at top and today's
  logged activities above it; a "For You" section that "takes the lead in the morning" with
  wellbeing, sleep and cycle cards that users toggle on/off. [O, BGR]
- **Go Gentler**: five ranked suggestions, typed by activity, duration, intensity, drawn from
  your own workout history; sometimes the top suggestion is rest. [S]
- Tone: encouraging, no insistent reminders (ADA citation). [S, Apple ADA 2024]

### 1.9 Rise (sleep debt + energy)

- **Energy Schedule**: a wavy curve across the day showing grogginess, peak, dip, evening peak,
  melatonin window; built from personal sleep need, not a generic goal. [S, Sleepopolis / Bustle]
- Progress tab splits Sleep Times, Sleep Debt, Sleep Quality. [S]
- Praised for clean, intuitive metrics. [S]

---

## 2. Cross-cutting comparison

| Dimension | WHOOP | Oura | Bevel | Apple | Garmin | Ultrahuman | Gentler |
|---|---|---|---|---|---|---|---|
| Hero on Today | 3 dials | 3 score shortcuts + 1 highlight | 3 circles (editable cards) | rings; iOS27 Readiness 0-10 | today's workouts + panels | action engine | Activity Path band |
| Count of headline numbers | 3 | 3 (+HR, stress) | 3-5 | 3 rings | user-chosen, up to 8 cards | few; actions first | 1 band + cards |
| Baseline shown as | 30/90-day ranges [S] | baseline range per vital [O] | n/a found | Typical/Outlier label [S] | colour-coded status words | n/a found | band = your normal |
| Score explanation | deep dive per dial | 7 contributor bars + plain questions | overlays / Learn More | cause hints on outliers | links to detail pages | actions, not reasons | suggestion list |
| Provisional data | greyed score ~4 days [S] | (not verified) | (not verified) | Trends need 180 days | grey "unknown" bars | (not verified) | (not verified) |
| Customisable home | (not verified) | dynamic by time of day | yes | rings fixed | yes, Edit Home | n/a found | toggle cards |

"(not verified)" means I found no source either way. Do not fill these in from memory.

---

## 3. Transferable design patterns (14)

Each: who uses it, why it works, when not to use it. "Why" lines are [I] unless marked.

**P1. Three-score hero, everything else one tap down.**
WHOOP (dials), Oura (score shortcuts), Bevel (circles), Apple (rings). A morning check needs
three answers: did I sleep, can I push, how much have I done. More than ~3 hero numbers is what
reviewers called "daunting" on WHOOP's denser 2023 home [O]. Not for: users whose job is a
specific metric (glucose, AFib); give them a pinned card instead. Note §5 on layout copying.

**P2. Personal baseline band behind every trend.**
Oura Vitals baseline ranges [O], WHOOP 30/90-day HRV/RHR ranges [S], Gentler Streak Activity
Path [S]. A shaded "your normal" band turns a wiggly line into a yes/no question: inside or
outside. Not for: metrics with under ~2 weeks of history; show a dashed "learning" band or none.

**P3. Typical / Outlier label instead of a number to interpret.**
Apple Vitals [S]. Word labels beat raw ms/bpm for most users and keep alerts rare (Apple only
notifies when 2+ vitals are outliers). Not for: the detail screen, where athletes want the value.

**P4. Contributors with plain-language questions.**
Oura Readiness: each contributor phrased as a question ("Have I been getting enough sleep in the
last 2 weeks?") with a coloured bar [S]. Answers "why is my score low" without a stats lecture.
Not for: contributors you cannot measure reliably; hide the bar rather than fake it.

**P5. Rank contributors by impact, show the top one or two.**
Oura Vitals "top contributors" behind a disclosure arrow [O]; WHOOP deep dives [S]. Users want
the reason, not seven equal bars. Not for: score breakdown audits; keep the full list one tap down.

**P6. Greyed / provisional state with a countdown.**
WHOOP greys recovery for ~4 days and unlocks Healthspan at 21 logged nights [S]; Apple Trends
waits for 180 days [S]. Honest about calibration and sets an expectation ("3 more nights").
Not for: hiding a real data gap; that needs P7.

**P7. Unknown is its own colour, never zero.**
Garmin draws "too active to determine" stress as grey bars [S]. A gap rendered as 0 or a
straight interpolated line reads as a measured value. Counter-example: Oura's 2026 bug left
scores blank with no reason while HR existed [O/S]. Not for: tiny gaps under the chart's
resolution; just don't draw them.

**P8. One daily highlight / One Big Thing.**
Oura Today "Daily highlight" by time of day [O]; Gentler "For You" leads in the morning [O];
Apple iOS 27 Insights [O]. Gives the screen a single sentence to read. Not for: generic tips
that ignore the user's data; Bevel's AI layer was called "generic" [O].

**P9. Action, not just a score.**
Ultrahuman UltraSphere actions [O], Gentler Go Gentler ranked suggestions incl. rest [S],
WHOOP Strain target / Weekly Plan [S], Athlytic exertion suggestions [O]. Must be specific:
Athlytic was criticised for "run for 50 minutes" without intensity [O]. Not for: when
confidence is low; say so instead.

**P10. Day timeline that carries context (tags, workouts, windows).**
Oura Today Timeline with tags [O], Ultrahuman Windows (caffeine, circadian) [O], Garmin Body
Battery colour-coded timeline [S], Rise energy curve [S]. Lets a user connect "I had wine" to
"HRV dipped" without a correlation engine. Not for: users who never tag; don't nag.

**P11. Short horizon vs long horizon, separate surfaces.**
Oura Today / Vitals / My Health [O]; Apple iOS 27 Longevity tab [O]; Ultrahuman Longevity
tab [O]; Apple Trends 90 vs 365 days as a single arrow [S]. Keeps daily noise off the slow
metrics. Not for: a 4-tab app that only has 3 tabs' worth of content; Oura and Gentler both
cut tab counts [O].

**P12. Direction arrow for slow trends.**
Apple Fitness Trends: one arrow per metric, 90-day vs 365-day [S]. Readable at a glance on any
phone width. Not for: noisy daily metrics; arrows flip daily and erode trust.

**P13. User-editable Today cards.**
Garmin Edit Home + In Focus [O], Bevel editable cards [O], Gentler toggles [O]. Lets each user
remove the metric they don't care about rather than the app guessing. Not for: first run; ship a
good default, offer editing later.

**P14. Works offline / on-device, and says so.**
Ultrahuman Emerald computes scores on the phone with no connection [O]. For OpenStrap this is
the native position (local-first); surfacing it ("computed on this phone") is a trust signal
competitors are only now adding [I].

---

## 4. Anti-patterns users complain about

| Anti-pattern | Evidence | Fix (pattern) |
|---|---|---|
| Too many numbers on Home for a new user | WHOOP 2023 home "daunting" [O] | P1, P13 |
| Redesign that buries history / previous days | Oura 2025 reviews: "cannot pull or view any previous day" [S] | Keep a day picker / swipe-back on every score screen |
| Promo, ads or "conversation topics" mixed into health data | Oura reviews [S]; WHOOP promos [S] | Health data first; promos never above the fold |
| Blank score with no reason | Oura 2026 missing-night bug [O/S] | P6, P7: say "no sleep detected" / "sync pending" |
| Simplifying away the number power users wanted | Garmin removed training load # [O] | Word label on Home, raw number on detail |
| Vague coaching | Athlytic "run for 50 minutes" [O]; Bevel AI "generic" [O] | P9 with type, duration, intensity |
| Decorative gradients over data | Athlytic "gradients work against the data" [S] | Flat fills; colour encodes state only |
| Red-score morning anxiety / orthosomnia | ~18% of users more worried about sleep after tracking; "one red score can hijack your morning" [S, Sahha / Plunge] | Neutral language, baseline framing (P2/P3), no red for single-night dips |
| One app trying to do everything | Bevel "ambitious" [O] | Stay narrow; link out |

---

## 5. Legal caution: layout trade dress

WHOOP v. Finerpoint (Bevel), D. Del. 1:2026cv00289, filed 2026-03-17, pre-trial. Claims
include Lanham Act trade dress over the cumulative look of "three circular dials: strain,
recovery, sleep. A coaching panel beneath" [O, the5krunner paraphrase]. The case is about the
overall presentation, not individual labels [O]. Outcome unknown.

[I] For OpenStrap, which reads WHOOP hardware: do not clone WHOOP's dial trio, colour mapping
and terms as a package. P1 can be met with different forms (Oura-style score shortcuts, a
single band like Gentler, word labels like Apple). This is a design risk note, not legal advice.

---

## 6. Gaps and unverified items

- Phone graph readability (scrub gestures, axis density, y-axis zero handling): I found no
  fetched source describing how any of these apps implements it. Apple's HIG "Charting data"
  page did not render via fetch. Needs hands-on review or the HIG read in a browser.
- WHOOP deep-dive layout details: whoop.com blocked; everything WHOOP-specific is [S] except
  the lawsuit paraphrase and the 2023 the5krunner review.
- Missing-data handling for Bevel, Ultrahuman, Gentler, Athlytic: not found.
- iOS 27 Health visuals: announced, not seen.
- Oura contributor colour ranges (Optimal 85-100, Pay attention 0-59) are [S]; confirm in app.

---

## 7. Sources

WHOOP
- https://www.whoop.com/us/en/thelocker/the-all-new-whoop-home-screen/ (blocked; search summary only)
- https://www.whoop.com/us/en/thelocker/everything-whoop-launched-in-2025/ (blocked; search summary)
- https://the5krunner.com/2023/03/28/new-whoop-home-screen-looks-pretty-but-is-it-as-intuitive/
- https://plunge.com/blogs/blog/whoop-launches-5-0-and-mg-devices
- https://community.whoop.com/t/how-long-does-it-take-for-whoop-to-learn-your-baseline-metrics/359 (search)
- https://www.whoop.com/za/en/thelocker/10-whoop-features-you-need-to-know (blocked; search)

Oura
- https://ouraring.com/blog/new-oura-app-experience/
- https://9to5google.com/2025/10/20/oura-app-redesign/
- https://support.ouraring.com/hc/en-us/articles/360025589793
- https://kimola.com/reports/unlock-insights-oura-app-feedback-analysis-report-app-store-us-154501 (410; search snippet)
- https://gadgetsandwearables.com/2026/07/13/oura-missing-sleep-readiness-data-fix/ (search)

Bevel / lawsuit
- https://screensdesign.com/showcase/bevel-health-performance
- https://kiledjian.com/2026/07/07/bevel-turns-apple-watch-data.html
- https://the5krunner.com/2026/04/04/whoop-sues-bevel/
- https://wearablexp.com/news/whoop-vs-bevel-lawsuit-explained/
- https://dockets.justia.com/docket/delaware/dedce/1:2026cv00289/92454 (search)

Apple
- https://macrumors.com/guide/ios-27-health-app-new-features
- https://www.macworld.com/article/233093/ios-13-and-apple-watch-activity-trends-give-you-the-big-picture.html (search)
- https://www.wareable.com/apple/how-vitals-app-finally-makes-apple-watch-a-wellness-powerhouse (403; search)

Garmin
- https://www.dcrainmaker.com/2024/01/garmin-connect-mobile-revamp-walk-through.html
- https://www8.garmin.com/manuals/webhelp/GUID-A298EB1C-21D9-430F-8D06-A2CC74E5D5E9/EN-US/GUID-EB7EF8CB-F93E-4477-B03F-E6B181B33D19.html (search)

Ultrahuman
- https://gadgetsandwearables.com/2026/07/23/ultrahuman-emerald-app-update/
- https://www.androidcentral.com/wearables/ultrahuman/ultrahuman-emerald-update-is-massive-ultrasphere-decision-engine-is-the-star-for-us (body did not load)

Athlytic
- https://ibikerun.substack.com/p/athlytic-app-review-iosapple-watch
- https://neura.health/insight/athlytic-app-in-depth-review (search)

Gentler Streak
- https://bgr.com/tech/gentler-streak-gets-a-major-redesign-focused-on-your-wellbeing/
- https://developer.apple.com/design/awards/2024 (search)
- https://www.imore.com/apps/health-fitness-apps/want-to-hit-your-2023-fitness-goals-drop-apples-rings-and-try-gentler-streak-instead (search)

Rise
- https://sleepopolis.com/sleep-accessories/rise-sleep-and-energy-app-review/ (search)
- https://www.bustle.com/wellness/rise-sleep-tracking-app-review (search)

Score anxiety
- https://sahha.ai/blog/orthosomnia-sleep-tracker-anxiety/ (search)
- https://plunge.com/blogs/blog/is-your-recovery-score-lying-to-you (search)
