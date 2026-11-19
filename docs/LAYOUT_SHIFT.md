# Layout shift budget (design note)

Owner request 2026-10-17. A tunable layout-shift scorer for `lib/ui2`, the
Flutter counterpart of the web's Cumulative Layout Shift (CLS) with extra
rules for focus, controls, colour, motion and launch brightness.

## Why custom

Prebuilt CLS tooling (web-vitals, Lighthouse, Chrome's Layout Instability
API) measures browsers only. Flutter has no layout-shift metric, and no
analyzer plugin knows which widget combinations move content after the first
frame. So the parts that are generic are borrowed (the web CLS impact formula:
impact fraction × distance fraction) and the rest is ours:

- `lib/layout_shift/` — pure Dart, no Flutter import. Policy, model, scorer,
  launch and motion checks. Deterministic: every time is an explicit
  millisecond offset; nothing reads a clock.
- `test/support/layout_shift_probe.dart` — widget-test probe that snapshots the
  render tree each pumped frame into the model, so a widget test can score a
  real screen and fail on `error` findings.
- `test/layout_shift/` — scorer law/example tests, probe tests, and a guard
  that the native launch backgrounds stay dark.

## Model (`lib/layout_shift/shift_model.dart`)

All times are ms since the scenario start. Rects are logical pixels.

- `ShiftRect(left, top, width, height)` with `area`, `center`, `intersect`,
  `union` bounds, `distanceTo(other)` (centre to centre).
- `ElementRole { paragraph, input, control, media, decorative, other }`.
- `ElementSnapshot(id, rect, role, colorArgb, focusable, focused, enabled)`.
- `Frame(atMs, elements)` — one painted frame.
- `Interaction(atMs, sourceId, intentTargetId?)` — a user action. `sourceId`
  is the element acted on (the copy button); `intentTargetId` is the element
  the action is meant to affect (the copied text). Together they form an
  action + intent pair.
- `FocusEvent(atMs, elementId)` — focus history (not just current focus).
- `AnimationSpan(startMs, endMs, elementId?, chainId?)` — an animation; spans
  sharing a `chainId` form a chain.
- `Scenario(viewport, frames, interactions, focus, animations)`.

## Policy (`lib/layout_shift/shift_policy.dart`)

Immutable, `copyWith`, three presets: `ShiftPolicy.standard`,
`ShiftPolicy.strict`, `ShiftPolicy.lenient`. Defaults (`standard`):

| knob | default | meaning |
|---|---|---|
| `latencyCurve` | (100,0) (200,.1) (300,.3) (400,.5) (500,1) | cost multiplier by ms after the last interaction; piecewise linear, 0 before the first point, 1 after the last |
| `loadCurve` | (100,0) (400,.1) (1000,.3) (2000,.6) (4000,1) | cost multiplier by settle time (ms from interaction until the screen stopped changing); same shape rules as `latencyCurve` |
| `loadWeight` | 0.25 (strict .4, lenient .15) | max cost of one load: a 4 s load is .25 = error at the default `errorAt` |
| `animationGraceWindowMs` | 100 | an animation starting within this many ms of the interaction earns… |
| `animationGraceMs` | 100 | …this many extra free ms (curve evaluated at `t − grace`) |
| `interactionWindowMs` | 500 | shifts later than this after the last interaction are out of window |
| `outOfWindowCost` | 1.0 | latency multiplier for out-of-window shifts |
| `chainRangeMs` | 75..2000 | a chain qualifies if it starts ≥75 ms… and ends ≤2000 ms after the interaction |
| `chainCycleMs` | 200..400 | …and every span in it lasts within this range |
| `chainDiscount` | 0.5 | multiplier on shifts during a qualifying chain |
| `roleWeight` | paragraph 2, input 3, control 1.5, media 1, decorative .5, other 1 | |
| `colorWeight` | 0.5 | colour change counts as a shift of `area × colorDelta × colorWeight` |
| `focusDistanceWeight` | 1.0 | `× (1 + w × d)`; d = recency-weighted normalised distance from focus history |
| `focusHalfLifeMs` | 2000 | focus history recency decay |
| `pairedDiscount` | 0.5 | shift of the interaction's own intent target |
| `pairDistanceWeight` | 0.5 | `× (1 + w × d)`; d = normalised source↔intent distance |
| `coverCost` | 1.0 | base cost of covering a focusable element (fraction covered ≥ `coverMinFraction` .25) |
| `focusedMultiplier` | 2.0 | covered or shifted element is focused |
| `denseGapPx` | 8 | controls closer than this are tightly packed |
| `denseMultiplier` | 3.0 | relative shift between tightly packed controls |
| `sourceShiftFloor` | 0.5 (strict .75, lenient .3) | minimum latency multiplier for the interaction's source, or a control within `denseGapPx` of it |
| `focusShiftFloor` | 0.5 (strict .75, lenient .3) | …for an element focused before/after the frame, or with focus history of recency weight ≥ .5 |
| `denseShiftFloor` | 0.3 (strict .5, lenient .15) | …for a control that receives `denseMultiplier` |
| `disabledShieldMs` | 400..1000 | a shifted focused control visibly disabled for this long… |
| `disabledDiscount` | 0.8 | …earns this multiplier (small benefit) |
| `controlMoveScore` | 0.1 (strict .15, lenient .06) | minimum score of a control with a hazard (source, packed sibling of source, focused or recently focused, dense) that moved a full `controlMoveRefPx` |
| `controlMoveRefPx` | 48 (strict 40, lenient 64) | one touch target; displacement at or past it earns the full `controlMoveScore` |
| `warnAt` / `errorAt` | 0.05 / 0.25 | per-finding severity thresholds |
| `firstPaintMaxMs` / `firstPaintMaxArgb` | 20 / 0xFF222222 | launch: first paint by 20 ms, no brighter than #222 (relative luminance) |
| `reducedMaxAnimationMs` | 150 | reduced motion: animations ≤150 ms or none |
| `reducedChainCycleMs` | 750..2000 | reduced motion: chain cycles in this range |

## Scoring (`lib/layout_shift/shift_scorer.dart`)

`ShiftReport score(Scenario s, ShiftPolicy p)` compares each consecutive frame
pair by element id. Per moved/resized/recoloured element:

1. **base** = `(union(before, after).area / viewport.area) × (distance / max(viewport.w, viewport.h))`
   + `area/viewport.area × colorDelta × colorWeight` (colorDelta = max RGB
   channel delta / 255).
2. **× roleWeight**.
3. **× latency** (raised to the hazard floor, below): curve at `t = frame.atMs − lastInteraction.atMs` (with the
   animation grace shift), or `outOfWindowCost` beyond the window / with no
   prior interaction.
4. **× chainDiscount** if inside a qualifying chain.
5. **focus**: element is the last interaction's intent target ⇒ `× pairedDiscount`
   and `× (1 + pairDistanceWeight × d(source, intent))`; otherwise
   `× (1 + focusDistanceWeight × dFocus)`. Focused ⇒ `× focusedMultiplier`.
6. **dense**: two controls within `denseGapPx` before the frame whose relative
   offset changed ⇒ `× denseMultiplier` on both; a focused control disabled for
   a span inside `disabledShieldMs` covering the shift ⇒ `× disabledDiscount`.

**Hazard floor.** The 100 ms free window is about response timing: the screen
may react to a tap that quickly. It says nothing about where things land. A
control that moves under the finger or focus (the one just tapped, its packed
neighbours, the focused or recently focused element, controls shifting against
packed neighbours) risks a wrong press, and doing it instantly is no better, so
step 3 uses `max(latency, floor)` where floor is the largest applicable of
`sourceShiftFloor`, `focusShiftFloor`, `denseShiftFloor`. It applies only inside
the interaction window, raises and never lowers (out of window is already 1),
and combines with the other multipliers like the latency did, so the disabled
shield still discounts. The intent target of the last interaction gets no
floor: its own content changing is the expected response. Covering gets the same
floor when the covered element is the source or focused.

**Control move.** The area-fraction base makes a small control's jump nearly
free: a 40 px jump of a 90x32 chip on a phone is about .01. But a touch target
displaced under the finger is what causes mis-taps, whatever its area. So a
control with a hazard (source, packed sibling of the source, focused or with
focus history, or receiving `denseMultiplier`) scores at least
`controlMoveScore × min(1, displacement / controlMoveRefPx) × denseMultiplier
(if dense) × disabledDiscount (if shielded)`, where displacement is the centre
distance between the before and after rects. The result is `max(existing,
this)`. It applies inside and outside the interaction window (outside, the
existing score is already full latency, and the max still protects small
controls). The intent target of the last interaction is exempt. Defaults: a
40 px jump = .083 (warning); two packed controls moving against each other by
48 px = .3 (error). `controlMoveScore: 0` turns it off.

Coverage: an element appearing (or growing) over a focusable element by at
least `coverMinFraction` of its area adds `coverCost × fraction × latency`
(× focusedMultiplier when focused).

Each contribution is a `ShiftFinding(rule, elementId, atMs, score, severity)`
with severity `none | warning | error` from `warnAt` / `errorAt`.
`ShiftReport.total` sums scores; `errors` / `warnings` filter.

## Load time

Waiting costs too, not only movement. For each interaction, look at the frames
from the interaction up to the next interaction (or the end). Any change
between consecutive frames is activity: an element moved, resized, recoloured,
appeared or disappeared (compared by id). `settleMs` = the last changed
frame's `atMs` minus the interaction's `atMs` (nothing changed ⇒ no finding).

- score = `loadWeight × loadCurve(settleMs)`. Under 100 ms is free; at the
  defaults 400 ms = .025 (none), 1 s = .075 and 2 s = .15 (warning), 4 s = .25
  (error).
- **Unsettled**: if the last captured frame in the range itself changed, the
  screen had not settled when observation ended. Score = `loadWeight` (full
  cost), whatever the curve says, and no discount applies.
- **Chain discount**: a qualifying animation chain (same rules as above) that
  overlaps the load multiplies the score by `chainDiscount`. Animation that
  holds attention beats bare delay.
- **Grace**: an animation span starting within `animationGraceWindowMs` of the
  interaction (a placeholder fading in) shifts the curve by `animationGraceMs`.
- Finding: rule `load`, `elementId` = the interaction's `sourceId`, `atMs` =
  interaction + settle, severity from `warnAt` / `errorAt`; it counts in
  `ShiftReport.total`. No interactions ⇒ no load findings.

## Launch and motion checks

- `checkFirstPaint(atMs, argb, policy)` — error if later than `firstPaintMaxMs`
  or brighter than `firstPaintMaxArgb`. Native launch windows (Android
  `launch_background`, iOS `LaunchBackground` colour set) are the first paint,
  in BOTH light and dark mode; a guard test parses them.
- `checkReducedMotion(animations, policy)` — error per span longer than
  `reducedMaxAnimationMs` unless it belongs to a chain whose cycles sit in
  `reducedChainCycleMs`.

## Not covered (yet)

- A static analyzer rule for risky widget combinations. Needs an analyzer
  plugin (`custom_lint`) and a catalogue built from probe findings first.
- Device-level timing: the probe sees pumped frames in a test, not real
  vsync. First-paint timing on device is checked by the launch colour guard
  (the native window paints before Dart runs), not measured.

## Measured screens (Phase 17)

`test/layout_shift/screens/` measures Home, Health, Readiness detail (open and
the refresh landing after the stored-row paint), Wellness, a route push, and a
scrolled Home reload. No error-level shifts, so there are no Known findings.
Warnings seen (fake pumps, standard policy): Health refresh landing, 2
warnings (top: a card column at 500 ms, 0.06); Readiness refresh landing, 9
warnings (top: a control at 500 ms, 0.16 - the "building" block gives way to
the chart key and breakdown). Phase 18 fixed both: Readiness detail and Health (Last night) hold the landed
layout while the refresh is pending (ring box with a dash, dash rows, no tail
until it lands), and both refresh-landing tests now assert no shift finding.
Route pushes use `ShiftProbe(skipCoveredRoutes:
true)`: the covered page is not scored, because its slide is the framework's
transition.

## Known findings

None.
