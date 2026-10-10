# 03 · Information architecture and usability heuristics

Scope: OpenStrap Edge `main` at `2b1c8510` (worktree `edge-main-check`). Read-only code walk of
`lib/app.dart`, `lib/ui2/**`, `lib/l10n/app_en.arb`. No device session, no user telemetry; tap
counts are from navigation code, not observed. Paths below are relative to `lib/`.

Method: each journey traced from the route gate (`app.dart:242-268`) through the push calls,
scored against Nielsen's 10 (H1 visibility of status … H10 help/docs) and the norms WHOOP, Oura
and Apple Health have trained users on.

---

## 1. Journey maps

### J1. First launch → onboarding (3 screens, then shell)
Route order is fixed in `app.dart:213-226`: Welcome → device picker → "About you" → shell.

| Step | Screen | Friction |
|---|---|---|
| 1 | Welcome `ui2/onboarding/welcome.dart:589-627` | Headline "Your band, decoded here" and "computed on this phone from the raw signal" speak to builders, not to someone who wants to know if they slept well. Second CTA "Bring my history first" sits at equal visual weight (BigButton, soft) to the main one, plus a 3-line footnote about baselines and overwrite rules (`welcomeImportFooterNote`). H8. |
| 2 | Device picker `ui2/pairing/device_picker.dart:252-254, 336-415` | Title is "Connect your devices"; a WHOOP owner lands on search + "Browse by category" over ~15 device families (Oura, Polar, Coros, Mi Band, Colmi, Bangle.js…, `:546-606`). The band they bought the app for is one row among many. Blurbs such as "Pairs and connects, nothing it captures is decoded into a number yet" (`:557`) are honest but make the list a support matrix. H8, recognition over recall OK. |
| 2b | Skip | "Skip for now" (`:407`) is fine, but the result is an app where every tab is empty-state copy. No way back to "finish setup" except Home gear → My devices. |
| 3 | About you `ui2/onboarding/profile_setup.dart:140-205` | Fields in ALL CAPS labels (SEX/AGE/HEIGHT/WEIGHT). Asks sex but never offers cycle tracking, which stays off (`state/app_state.dart:1376`, default false). No goals, units or notification permission step; those surface later as surprises. |
| 4 | Shell | Lands on Home with "Nothing derived yet / No band recordings processed yet." (`homeNothingDerivedTitle/Body`) until the first night is scored. No "what happens next" timeline (wear tonight, sync in the morning, baseline in N nights). H1, H10. |

Taps to first useful screen: 3 minimum, but the first *meaningful number* needs a night of wear,
and the app never says that up front.

### J2. Pairing a band (post-onboarding)
Home → gear (`screens/home_screen.dart:1813`) → Profile → "My devices" (`profile/profile.dart:305`)
→ devices screen (3,066 lines, `profile/devices.dart`) → pair. 3 taps to reach pairing.
Friction: the devices area exposes source arbitration ("Which source wins", `devices.dart:384`;
"My sources", `:1581`). This is power-user plumbing living next to "is my band connected".

### J3. First sync and every sync after
- Pull-to-refresh on Home calls `_load` (`home_screen.dart:2003-2004` → `:1507`), which re-reads
  the local DB. It does not start a band sync. In WHOOP and Oura, pull means "sync now". H2
  (match real world), H1.
- The sync/derive progress cards ("Syncing with your band", "Crunching last night's numbers",
  `:1578-1598`) render only on a bare day (`:1617`, `:1691`). On a normal morning, yesterday's
  rings sit on screen during a sync with no spinner; the only signal is the grey caption
  "Synced through 07:12" (`:1775`, `syncedThroughLabel` `:213-222`). H1.
- An explicit "Sync the band" button exists only inside empty-state cards (`:1630`, `:1697`,
  `health_screen.dart:1234`) and "Sync now" deep in devices (`app_en.arb devicesSyncNow`).
- Copy during sync is good plain language ("this can take a few minutes on a full backlog").
- Copy after a stale rollup is not: "The last rollup was built over a week ago, which is too old
  to stand behind." (`homeInsightsStaleOverWeek`, card at `home_screen.dart:548-560`).

### J4. Understanding today (Home)
Vertical order (`home_screen.dart:1738-1960`): illness observation (conditional) → greeting, date,
"Synced through", battery → coach and gear icons → day switcher → 3 rings + "Why?" drivers →
DetectedActivitiesCard → CommunityNudge (Discord/Sponsor asks, `ui2/nudges.dart:1-16`) → stale
card → "At a glance" (RHR, steps, active energy, alarm; 2-col tiles) → stacked absence cards for
every missing metric (`:2132`) → "Today's plan" (steps left, strain target, sleep need) →
"Breakdown of your day" link.

Count on a normal day: 3 ring values + 3 ring subs + up to 3 drivers + 4 tiles with subs + 3 plan
rows ≈ 12-16 numbers. That is lower than WHOOP's 2025 home and not the main problem. The problems:
- Missing data is loud. Each absent metric becomes its own StatusCard (`:2132`, `:1878-1893`);
  a partial night can stack 2-4 cards that each explain a gap. The app reads as broken (H8, H9).
- Labels collide: the ring says **Recovery** (`homeRingRecovery`), the card when absent says
  **Readiness is not scored today**, the tap target is the **Readiness** screen
  (`readinessDetailTitle`), and the tier words are "Good to go / Steady / Take it easy / Rest
  today" (`:740-751`). Four names for one score. H4.
- Promotional nudges sit directly under the rings (`:1899`), the most valuable slot on the screen.
- Coach entry is hidden unless an AI model was configured (`:1786-1810`, `coachReady`
  `screens/coach.dart:50`). A new user never learns there is a coach.

### J5. Checking sleep
No Sleep tab. Entry points, all different: Home sleep ring → SleepDetail (2 taps); Health →
Overview "Sleep" row → MetricDetail (generic chart, not SleepDetail); Health → Deep dives;
Wellness → Recovery sub-tab holds sleep *need*, debt, target bedtime/wake
(`wellness_screen.dart:491-549`); Settings holds the smart alarm. Sleep is the #1 reason people
wear a WHOOP, and here it is spread across three tabs plus Settings. H6 (recognition), H4.
SleepDetail itself (`screens/sleep_detail.dart:497-536`) is sensible: hero total sleep, hypnogram,
stages, vs usual, overnight signals, tonight. It has no single sleep score or sleep-performance %,
so there is no one-glance verdict the way WHOOP (Sleep %) and Oura (Sleep score) give.

### J6. Checking recovery / readiness
Home ring → ReadinessDetail (1 tap). Separately, Wellness has a sub-tab literally named
**Recovery** (`wellness_screen.dart:241`) that contains stress last night and sleep need, not the
recovery score. A user who taps Wellness → Recovery looking for their score finds bedtime targets.
Absence path is good: "See what was missing" opens the same screen with the per-input diagnostic
(`home_screen.dart:1891`). Calibration state shows the word "Calibrating" (`homeCalibrating`) with
no count of nights left on Home.

### J7. A workout
Workout tab → quick-start tile or Activities → ActivitySetup → Start (`activity/setup.dart:282`).
3 taps, comparable to Apple Workout. Live session survives app exit via the pinned bar
(`app.dart:640-735`), which is solid H3/H5 work. Friction:
- The Workout tab talks **Training load**, **TRIMP**, **Mechanical load**, **Fatigue / Form**
  (`workout_screen.dart:204, 248, 343-344, 381-404`); Home talks **Strain** and "Strain target
  met" (`home_screen.dart:2172`). Two vocabularies for one idea of "how hard was today". H4.
- Bar strings "Session running — tap to finish" are hard-coded English (`app.dart:687, 725`).

### J8. Settings, export, devices, cycle, alarm
Everything personal lives behind one 40 pt gear on Home only (`home_screen.dart:1813`). Other four
tabs have no way into Profile. Paths:

| Goal | Path | Taps |
|---|---|---|
| Devices | Home → gear → My devices | 3 (plus tab switch if elsewhere) |
| Export CSV | Home → gear → More settings → Export, backup, import → Export as spreadsheets | 5 |
| Turn on cycle tracking | Home → gear → More settings → Preferences/Cycle tracking → back ×2 → Wellness → Cycle | 7 |
| Smart alarm | Home → gear → More settings → The band/Alarm (or Home glance tile if one is set) | 4 |
| Coach setup | Home → gear → AI coach → pick provider, Base URL, API "Responses / Chat Completions" (`screens/coach.dart:990-1110`) | 3 + form |

Labelling problems: Profile has a group "Your data" holding *Storage* and *More settings*
(`profile/profile.dart:338-357`); More settings has a second, different "Your data" group holding
export and Health write (`profile/settings.dart:721-738`). "More settings" is a junk drawer named
for its position, not its content; its own subtitle has to list "Import, export, backup, units,
privacy, reset" to be findable (`profile.dart:353`). H6, H4.

### J9. Coach
Invisible until configured (above). Once configured: sparkles icon beside the gear on Home only.
Setup asks for developer concepts (base URL `http://localhost:11434/v1`, API wire format). Starter
prompts ("How recovered am I today, and why?", `coachStarterRecovery`) are good. Error copy leaks
internals: "aggregate with AVG/MIN/MAX/COUNT instead of selecting every row" (arb, coach size-limit
string). H2, H9.

---

## 2. Heuristic scorecard (Nielsen 10)

| # | Heuristic | Grade | Evidence |
|---|---|---|---|
| H1 | Visibility of status | Weak | No sync indicator on non-bare days; pull-to-refresh is not sync; "Calibrating" has no progress. |
| H2 | Match real world | Weak | RMSSD, TRIMP, rollup, derived, nocturnal, percentile, PRV in user copy (section 3). |
| H3 | Control and freedom | Good | Undo on rejected sleep window, live-session bar, dismissible nudges. |
| H4 | Consistency | Poor | Recovery/Readiness, Strain/Load, two "Your data" groups, "Recovery" sub-tab ≠ recovery score. |
| H5 | Error prevention | Good | Import never overwrites measured days; passphrase confirm. |
| H6 | Recognition over recall | Weak | Sleep across 3 tabs + Settings; Profile only on Home; cycle hidden in Settings. |
| H7 | Flexibility | OK | Day switcher, deep dives for experts, Tasker/Shortcuts. Experts are served better than novices. |
| H8 | Minimalist design | Weak | Stacked absence cards; 124 strings >150 chars, 20 >250 chars in `app_en.arb`. |
| H9 | Error recovery | Mixed | Every empty state names a cause and a fix (strong). Some causes are internal ("no version stamp"). |
| H10 | Help | Weak | No first-week explainer; no glossary; methodology lives in the copy itself instead. |

Accessibility is the strongest area and should be kept as-is: `Pressable` enforces 44 pt minimum
(`ui2/grammar.dart` Pressable `BoxConstraints(minWidth: S.tap, minHeight: S.tap)`), contrast test
sweeps every accent × surface at 4.5:1 (`ui2/README.md`, `test/ui2_contrast_test.dart`), goldens
at up to 3.1× text, rings collapse to rows at large text (`home_screen.dart` `bigText`), rings
carry spoken labels (`r.spoken`). Gaps: tab labels are 11 pt (`F.over`, `app_shell.dart:238`),
`ui2/charts.dart` has no `Semantics` wrapper on any painter, and ~14 hard-coded English strings
remain (e.g. `home_screen.dart:1611` "No data for this day", `live_hr.dart:206`).

---

## 3. Jargon list → plain language

Counts are hits in English values of `app_en.arb` (2,974 strings). Keep the technical term on the
"How this is measured" sheet / Investigate screens; replace it everywhere a first-week user lands.

| Term (key example) | Hits | Where users meet it | Plain replacement |
|---|---|---|---|
| RMSSD (`beatsRmssdTitle`, `investigateRmssd`) | 15 | Beats, Investigate, metric blurbs | "HRV" on cards; "RMSSD" only in the method sheet |
| TRIMP / Banister (`workoutTrimpUnit`, `dayStrainInputsBase`) | 3 | Workout "Daily load" unit, Strain inputs | Drop the unit; "Load: how hard your heart worked, by minutes in each zone" |
| SDNN, pNN50, coefficient of variation (`healthBlurbHrvCv`, `investigatePnn50`) | 6 | Health blurbs, Investigate | "How steady your HRV was overnight" |
| PRV, "pulse-derived" (`devicesTierWristOpticalDetail`) | 3 | Device tiers, HRV blurb | "Measured from your pulse at the wrist, not a chest strap" |
| derived / Nothing derived yet (`homeNothingDerivedTitle`) | 23 | Home first run, Coach, Beats | "No nights scored yet. Wear the band tonight and open the app in the morning." |
| rollup / version stamp (`homeInsightsStaleOverWeek`, `homeInsightsNoVersionStamp`, `homeNoPlanWhyStale`) | 6 | Home cards | "Your trends are being updated. This takes a minute after a sync." |
| baseline (`healthIllnessBodyNoZ`) | 23 | Illness watch, imports | "your normal range" |
| nocturnal (`homeIllness*`) | 9 | Illness watch on Home | "overnight" |
| percentile / ordinal (`metricDetailPercentileTodayBand`) | 5 | Metric detail | "Higher than 8 of your last 10 days" |
| Autonomic tension, Baevsky (`wellnessAutonomicTension`) | 4 | Wellness → Recovery | "Stress last night" (already the section title; drop the second label) |
| Chronotype, social jetlag, regularity (`healthChronotypeLabel`) | 5 | Health → Body clock | "Natural bedtime", "Weekend shift", "Sleep schedule consistency" |
| Lipponen–Tarvainen, artefact-free window, 1 Hz / 100 Hz | 5 | metric explanations | Move to the method sheet only |
| Keytel 2005 · Harris–Benedict / Mifflin | 1 | energy explanation | "Estimated from heart rate, age, weight and sex" |
| AN-2554 pedometer, HealthKit / Health Connect | 1 | step source | "Band" / "Phone" (Home already does this, `homeStepSensor*`) |
| MET, VO2max (est.) | 9 | activity setup/summary | "Effort level"; "Fitness estimate (VO₂max)" with a one-line tooltip |
| Calibrating (`homeCalibrating`) | 1 | Home ring | "Learning your normal: 3 of 7 nights" |
| Base URL, Responses / Chat Completions (`coach.dart:1102-1106`) | — | Coach setup | Provider presets first; hide URL/API under "Advanced" |
| AVG/MIN/MAX/COUNT in an error | 1 | Coach error | "That question pulled too much data. Try a shorter time range." |

Tone note: much copy explains *why the app is honest* rather than *what the user should do*
(e.g. `welcomeImportFooterNote`, `healthIllnessBodyNoZ` "It names a pattern, not a cause").
Rule of thumb for rewrite: lead with the answer, one line of action, push method to a "How is
this measured?" link.

---

## 4. IA problems (ranked)

1. **Sleep has no home.** Split across Home ring, Health row (to a generic chart), Wellness →
   Recovery (need/debt/bedtime), Health → Body clock, and Settings (alarm).
2. **Profile/settings reachable only from Home** (`home_screen.dart:1813`). Four tabs out of five
   are dead ends for devices, battery, export, settings.
3. **One score, four names**: Recovery (ring), Readiness (screen, empty card), tier words,
   plus a Wellness sub-tab called Recovery that is about sleep planning.
4. **Strain vs Load**: Home and Day Strain say Strain; Workout says Training load / TRIMP /
   Fatigue / Form.
5. **Health tab is five sub-tabs** (Overview, Explore, Trends, Vitals, Labs,
   `health_screen.dart:486-490`) with overlap: Explore (metric catalogue), Trends, Vitals and Deep
   dives → Investigate all answer "show me a chart of X".
6. **Wellness mixes four unrelated jobs** (breathing, sleep planning, habits, medication, cycle).
   It is a catch-all, as its own header admits ("where the app explains itself",
   `wellness_screen.dart:4`).
7. **Hidden features**: cycle tracking off, opt-in only in More settings; coach invisible until
   configured; smart alarm only in Settings; Labs buried as Health's fifth sub-tab.
8. **Nutrition is a top-level tab** for a band that measures nothing about food. It takes a
   primary slot that WHOOP and Oura give to Sleep or Coach.
9. **Legacy tab mapping**: notification payloads carrying the old tab indexes 1, 2 and 3 all
   collapse to Health (`app.dart:381-385`). Worth checking which notices still send a bare index;
   any that mean "sleep" or "recovery" land one level too high.
10. **"More settings" junk drawer** and duplicate "Your data" groups (J8).

---

## 5. Competitor comparison (top level and Home)

| App | Bottom bar | Home / Today |
|---|---|---|
| WHOOP (2025 redesign) | Home, Health, Community-style tabs, central Action button, Coach in the bar's right corner, labelled tabs | Scrollable home with Sleep, Recovery, Strain dials up top in that order; new Health tab gathers Healthspan, Health Monitor, Hormonal Insights, Stress Monitor |
| Oura (Oct 2025 redesign) | Three tabs: Today, Vitals, My Health (down from five: Home, Readiness, Sleep, Activity, Resilience) | Sleep, Readiness, Activity scores on top; shortcuts to HR, stress, Cycle Insights (if opted in); Advisor (AI) in My Health |
| Bevel | Per-domain pages around Sleep, Strain, Recovery, Nutrition scores plus a coach | Summary of the four scores |
| Apple Health | Summary, Sharing, Browse | Pinned favourites the user picks; Browse is the catalogue |
| OpenStrap Edge | Home, Health, Nutrition, Workout, Wellness; Profile and Coach are icons on Home only | Recovery, Strain, Sleep rings; glance tiles; plan; absence cards |

What the leaders converged on: fewer tabs (3-4), score-first Today, sleep given a first-class
place, the AI coach in the bar rather than buried, catalogue/"browse" separated from "today".
Edge already has the score-first Home; it lacks the consolidation.

Sources: [WHOOP: the all-new home screen](https://www.whoop.com/us/en/thelocker/the-all-new-whoop-home-screen/),
[the5krunner on the WHOOP revamp](https://the5krunner.com/2025/10/15/whoop-homescreen-gets-a-revamp),
[Oura: new app experience](https://ouraring.com/blog/fr/new-oura-app-experience/),
[9to5Google on the Oura redesign](https://9to5google.com/2025/10/20/oura-app-redesign/),
[Bevel App Store listing](https://apps.apple.com/us/app/bevel-all-in-one-health-app/id6456176249).
Bevel's exact bar was not confirmed from a primary source; treat that row as approximate.

---

## 6. Proposed simplified IA

Four tabs plus a persistent avatar. Same `ShellDomain` mechanism (`app_shell.dart:20-26`); the
change is which domains exist and what they own.

| Tab | Owns | Moves in from |
|---|---|---|
| **Today** | Recovery, Strain, Sleep rings (one name each); one "what to do today" plan; sync status line with a real spinner; at most one combined "some data is missing" card; Coach prompt chip | Home (unchanged core), Wellness → Recovery "sleep need tonight" folds into the plan |
| **Sleep** | Last night (SleepDetail as the tab root), sleep need/debt, target bedtime/wake, naps, smart alarm, body clock | Home ring target, Wellness → Recovery, Health → Body clock, Settings → Alarm |
| **Activity** | Start a workout, history, strain/load (one vocabulary: "Strain" daily, "Training load" only as the 7/28-day trend), steps, nutrition logging as a section | Workout tab, Home glance steps/energy, Nutrition tab (demoted to a section; a toggle can promote it back) |
| **Health** | Trends and vitals (one catalogue: merge Overview + Explore + Trends + Vitals into "Overview" + "All metrics"), illness watch, Labs, cycle (shown when sex = female or opted in), medication, habits, breathing | Health, Wellness (Mind, Habits, Medication, Cycle) |
| Avatar (top-right on every tab) | Profile, Devices + battery, Settings (flattened, no "More settings"), Export, Coach setup | Home gear |
| Coach | Floating chip on Today and a header action on every tab once set up; when not set up, one card on Today: "Ask questions about your data. Set up." | Home-only sparkles icon |

Settings regrouped: *Band* (devices, alarm, gestures, zone alert, notifications on the band),
*App* (units, appearance, language, notifications), *Data* (export, backup, import, Apple Health /
Health Connect), *Privacy*, *Advanced* (source priority, Tasker, developer, reset).

Onboarding: Welcome (one CTA "Set up my WHOOP band", import as a text link) → pair (WHOOP
first, "Other devices" collapsed) → About you (add cycle-tracking toggle and units) → a
"Your first week" card on Today: wear tonight → first sleep tomorrow → recovery after 4 nights →
full baseline after 7 (verify the exact night counts against the readiness gate before shipping).

Migration cost is mostly routing: `domainForRoute` / `domainForTab` (`app.dart:381-427`), the
shell builder (`app.dart:610-616`), Prefs `shellTab` restore index, and the arb tab keys.
Screens themselves mostly move, not change.
