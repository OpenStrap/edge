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
- `ElementRole { paragraph, input, control, media, decorative, other,
  placeholder }`. `placeholder` is a loading stand-in (a skeleton, an
  `InlineLoading`) that holds the space its content will fill.
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
| `appearWeight` | 0.5 (strict .75, lenient .3) | cost of content appearing after the initial paint, per viewport fraction it takes, at full `loadCurve` lateness, × the element's `roleWeight` |
| `appearCoveredFree` | 0.9 | an appearing element at least this fraction covered by the union of placeholders that vanished in the same frame (a placeholder replaced in place) is free |
| `animationGraceWindowMs` | 100 | an animation starting within this many ms of the interaction earns… |
| `animationGraceMs` | 100 | …this many extra free ms (curve evaluated at `t − grace`) |
| `interactionWindowMs` | 500 | shifts later than this after the last interaction are out of window |
| `outOfWindowCost` | 1.0 | latency multiplier for out-of-window shifts |
| `chainRangeMs` | 75..2000 | a chain qualifies if it starts ≥75 ms… and ends ≤2000 ms after the interaction |
| `chainCycleMs` | 200..400 | …and every span in it lasts within this range |
| `chainDiscount` | 0.5 | multiplier on shifts during a qualifying chain |
| `roleWeight` | paragraph 2, input 3, control 1.5, media 1, decorative .5, other 1, placeholder .5 | |
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
| `consistencyWeight` | 1.0 (strict 1.5, lenient .6) | multiplier on every `consistency` finding's area formula (not on its drift floor) |
| `consistencyTolerancePx` | 1.0 | `consistency`: a move or size change up to this many px is free |
| `consistencyMoveScore` | 0.1 (strict .15, lenient .06) | `consistency` drift floor: minimum score of a real element that moved or resized a full `consistencyRefPx` |
| `consistencyRefPx` | 8 (strict 6, lenient 12) | drift at or past this earns the full `consistencyMoveScore` |
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

## Appearing content

Load time charges only for how long the screen changed, so a bare spinner
followed by content scored the same as a skeleton the content fills in place.
The `appear` rule charges content that lands in space nothing reserved for it.

For each interaction, take the frames after the first frame at/after the
interaction (that first frame is the initial paint and is free) and before the
next interaction. An element present in frame i but absent (by id) in frame
i-1 appears at `t` = frame i's `atMs`:

- `visible` = the element's rect clipped to the viewport (nothing visible ⇒ no
  finding).
- `uncovered = visible.area − area(⋃ intersect(visible, v))` over the
  elements `v` with role `placeholder` that were in frame i-1 and are gone in
  frame i (the placeholder it replaced). The union, not the sum: a skeleton
  line inside its own skeleton card covers nothing twice. Computed exactly
  (the rects are axis-aligned: split on every edge, add the covered cells),
  independent of element order. Only placeholders cover: a real card
  replaced in place by a different real card (the first-launch card swap) is a
  swap, not a fill, and is charged in full.
- Free when `uncovered / visible.area ≤ 1 − appearCoveredFree` (at the default,
  ≥ 90% covered by a vanished placeholder).
- score = `appearWeight × roleWeight × uncovered / viewportArea × loadCurve(t − interaction)`,
  `roleWeight` of the appearing element, as for a shift (a placeholder
  landing late costs half, a paragraph double).
  At the defaults a 400 × 300 card (role `other`, weight 1) landing at 3 s in
  a 400 × 800 viewport where only a 22 × 22 spinner (a placeholder) stood
  scores .5 × 1 × 119516 / 320000 × .8 ≈ .149 (warning); the same card
  filling a same-size skeleton scores 0.
- Finding: rule `appear`, `elementId` = the element's id, `atMs` = `t`; it
  counts in `ShiftReport.total` alongside the `load` finding. No interactions ⇒
  no appear findings.

## Layout consistency

The other rules score one scenario in time. `consistency` compares two
settled layouts the user holds side by side in their head, and charges the
same element sitting somewhere else:

```dart
compareLayouts(Frame a, Frame b, ShiftPolicy p,
    {required ShiftRect viewport, bool Function(String id)? only})
```

`viewport` is required: a `Frame` carries none, and guessing it from the
elements would make the score depend on what is on screen. A viewport with
no area (width or height ≤ 0) throws `ArgumentError`, as does `score` for a
`Scenario` whose viewport has none: every score is a viewport fraction, and
an empty report would let a broken probe pass. `only` limits the
comparison to the ids it accepts. There is no latency or curve: a layout that
differs from the remembered one is wrong whenever it shows up.

- **In both**, with `d` = centre distance and `s` = max(|Δwidth|, |Δheight|);
  a `d` or `s` up to `consistencyTolerancePx` is free (both free ⇒ no
  finding):
  `base = min(1, seen(union) / vpArea × d / vpSide + |seen(a) − seen(b)| / vpArea) × roleWeight × consistencyWeight`,
  where `seen(r)` is the area of `r` clipped to the viewport (as for the
  one-sided term: what the user never saw, they cannot remember). An
  element off screen in both layouts is not charged at all. The `min(1, …)`
  caps the area part at one viewport, so one finding never scores more than
  `max(roleWeight × consistencyWeight, drift floor)` (≤ 3 at the defaults,
  input).
- **Drift floor**, every role except `placeholder`:
  `score = max(base, consistencyMoveScore × min(1, x / consistencyRefPx))`
  with `x` = `d` for a move, `s` for a resize, the larger floor when both. Not
  multiplied by `consistencyWeight`. The area formula alone makes a few px on
  an avatar or a title worth nothing, and that drift is the polish bug. At
  the defaults 4 px scores .05 (warning), 8 px or more .1.
- **In one only**: `visible area / vpArea × consistencyWeight` (no floor) —
  a card that exists in one state and not the other.
- Finding: rule `consistency`, `elementId`, `atMs` = `b.atMs`; severity from
  `warnAt` / `errorAt`.

Uses:

- **Cross-screen**: settled frames of two screens, `only: shared:*`. Mark a
  thing shared on every screen with `SharedSlot('avatar', child: …)`
  (`lib/ui2/shared_slot.dart`), which keys its child `shared:avatar`; one id
  per shared thing.
- **Revisit**: visit 1 vs visit 2 of one screen, all ids. Charged even if a
  sync landed between visits: only small things (text inside a fixed box) may
  change with the data.
- **Empty vs loaded**: first launch with no data vs loaded, only card-level
  ids. The same cards in the same places; what is inside them may differ.

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
