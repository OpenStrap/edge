# Layout shift budget (design note)

A tunable layout-shift scorer for `lib/ui2`, the
Flutter counterpart of the web's Cumulative Layout Shift (CLS) with extra
rules for focus, controls, colour, motion and launch brightness.

## Why custom

Prebuilt CLS tooling (web-vitals, Lighthouse, Chrome's Layout Instability
API) measures browsers only. Flutter has no layout-shift metric, and no
analyzer plugin knows which widget combinations move content after the first
frame. So the parts that are generic are borrowed (the web CLS impact formula:
impact fraction × distance fraction) and the rest is ours:

- `test/support/layout_shift/` — pure Dart, no Flutter import. Policy, model, scorer,
  launch and motion checks. Deterministic: every time is an explicit
  millisecond offset; nothing reads a clock.
- `test/layout_shift/` — scorer laws and hand-built example fixtures.

## Model (`test/support/layout_shift/shift_model.dart`)

All times are ms since the scenario start. Rects are logical pixels.

- `ShiftRect(left, top, width, height)` with `area`, `center`, `intersect`,
  `union` bounds, `distanceTo(other)` (centre to centre).
- `ElementRole { paragraph, input, control, media, decorative, other,
  placeholder }`. `placeholder` is a loading stand-in (a skeleton, a
  loading widget) that holds the space its content will fill.
- `ElementSnapshot(id, rect, role, colorArgb, focusable, focused, enabled)`.
- `Frame(atMs, elements)` — one painted frame.
- `Interaction(atMs, sourceId, intentTargetId?, afterFrameIndex?)` — a user action. `sourceId`
  is the element acted on (the copy button); `intentTargetId` is the element
  the action is meant to affect (the copied text). Together they form an
  action + intent pair.
- `FocusEvent(atMs, elementId)` — focus history (not just current focus).
- `AnimationSpan(startMs, endMs, elementId?, chainId?)` — an animation; spans
  sharing a `chainId` form a chain.
- `Scenario(viewport, frames, interactions, focus, animations)`.

## Policy (`test/support/layout_shift/shift_policy.dart`)

`copyWith` and three constant presets: `ShiftPolicy.standard`,
`ShiftPolicy.strict`, `ShiftPolicy.lenient`. Custom policies retain caller-supplied
curve lists and role-weight maps; callers must not mutate those collections.
Defaults (`standard`):

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
| `chainStartMinMs` / `chainEndMaxMs` | 75..2000 | a chain qualifies if it starts ≥75 ms… and ends ≤2000 ms after the interaction |
| `chainCycleMinMs` / `chainCycleMaxMs` | 200..400 | …and every span in it lasts within this range |
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
| `disabledShieldMinMs` / `disabledShieldMaxMs` | 400..1000 | a shifted focused control visibly disabled for this long… |
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
| `reducedChainCycleMinMs` / `reducedChainCycleMaxMs` | 750..2000 | reduced motion: chain cycles in this range |

## Scoring (`test/support/layout_shift/shift_scorer.dart`)

`ShiftReport score(Scenario s, ShiftPolicy p)` compares each consecutive frame
pair by element id. An interaction may supply `afterFrameIndex`, the index of
its last pre-action baseline. Only later frames belong to that interaction:
pre-tap changes keep the preceding interaction even at the same timestamp.
Shift, load and appearance use this boundary consistently. With no boundary,
hand-built scenarios retain timestamp-only attribution. Equal-time interactions
retain their recorded order. Per moved/resized/recoloured element:

1. **base** = `(union(before, after).area / viewport.area) × (distance / max(viewport.w, viewport.h))`
   + `area/viewport.area × colorDelta × colorWeight` (colorDelta = max RGB
   channel delta / 255). Impact and colour areas are clipped to the viewport;
   elements invisible in both frames contribute nothing. Distance is the larger
   of centre displacement and half the largest dimension change when both edges
   are visible. Per axis, use original edge movements for edges inside the
   viewport in either frame: average two visible edges for centre movement and
   take half their difference for resizing; a lone visible edge supplies the
   full movement. Stationary boundary edges anchor a resize; moving boundary
   edges are clipped, so growth hidden below the fold is free. If neither edge
   is visible, retain their common translation (the
   smaller same-direction movement), so a panel covering the viewport can still
   move. Opposite-direction hidden growth contributes nothing. The tests in
   `bot_regressions_test.dart` pin straddling translation, one-pixel exit,
   covering-panel translation and hidden growth.
2. **× roleWeight**.
3. **× latency** (raised to the hazard floor, below): curve at `t = frame.atMs − lastInteraction.atMs` (with the
   animation grace shift), or `outOfWindowCost` beyond the window / with no
   prior interaction.
4. **× chainDiscount** if inside a qualifying chain.
5. **focus**: element is the last interaction's intent target ⇒ `× pairedDiscount`
   and `× (1 + pairDistanceWeight × d(source, intent))`; otherwise
   `× (1 + focusDistanceWeight × dFocus)`. Focused in either frame ⇒ `× focusedMultiplier`.
6. **dense**: two controls within `denseGapPx` before the frame whose relative
   offset changed ⇒ `× denseMultiplier` on both; a focused control disabled for
   a span inside `disabledShieldMinMs` / `disabledShieldMaxMs` covering the shift ⇒ `× disabledDiscount`.

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
(× focusedMultiplier when focused). Ancestor–descendant pairs are excluded
in both directions: a control owns its descendants, and a container does not
occlude its own child.

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
next interaction. With an explicit frame boundary, that baseline replaces the
initial-paint frame and each later frame is eligible. An element present in frame i but absent (by id) in frame
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

- **Cross-screen**: settled frames of two screens, `only: (id) => id.startsWith('shared:')`. Give
  matching elements a `ValueKey<String>` such as `shared:avatar`, and capture
  each element's geometry under that id.
- **Revisit**: visit 1 vs visit 2 of one screen, all ids. Charged even if a
  sync landed between visits: only small things (text inside a fixed box) may
  change with the data.
- **Empty vs loaded**: first launch with no data vs loaded, only card-level
  ids. The same cards in the same places; what is inside them may differ.

## Launch and motion checks

- `checkFirstPaint(atMs, argb, policy)` — error if later than `firstPaintMaxMs`
  or brighter than `firstPaintMaxArgb`. The caller supplies the paint time and colour; this function does not
  measure a device launch.
- `checkReducedMotion(animations, policy)` — error per span longer than
  `reducedMaxAnimationMs` unless it belongs to a chain whose cycles sit in
  `reducedChainCycleMinMs` / `reducedChainCycleMaxMs`.

## Not covered (yet)

- A static analyzer rule for risky widget combinations. Needs an analyzer
  plugin (`custom_lint`) and a catalogue built from probe findings first.
- Device-level timing: the probe sees pumped frames in a test, not real
  vsync. Native launch colours and device timing need separate checks; neither is
  measured by the pure scorer.

## Scorer change checklist

- When changing geometry scoring, run `bot_regressions_test.dart` alongside the
  layout suite: preserve full translation at each viewport edge and on exit,
  covering-panel translation, hidden-growth abstention and anchored-resize cost.

## Widget measurement

`ShiftProbe` in `test/support/layout_shift_probe.dart` captures keyed render
boxes at explicit millisecond offsets. Set `trackUnkeyed: true` to include
text, controls, inputs and card slots. Hidden and clipped content is excluded;
`skipCoveredRoutes: true` excludes the page under a pushed route.

Application loading widgets can be recognized with `isPending`. Paint-only
wrappers can be excluded from structural identity with `isPaintOnly`. These
callbacks keep the probe independent of application widget classes.

`ShiftRun` in `test/support/shift_run.dart` records taps and pumps the requested
offsets. It captures intermediate animation frames. Call `opened()` before
measuring initial loading, then `frames()` and `expectNoErrors('scenario')`.
For a data refresh without a user action, capture with `snap()` and `frames()`.
The driver captures indeterminate progress indicators by default. Set
`rejectIndeterminateProgress: true` when a scenario forbids them.

The scores are project policy, not browser CLS or a validated perceptual scale.
The launch checks classify supplied times and colours; they do not measure
startup speed. Widget tests use a fake clock and do not establish device timing.
