# Edge — "Volt" UI overhaul brief

> **For Claude Code.** This is the full brief for a complete visual overhaul of the
> Edge Flutter app. Do the work in the phases in §10, **one phase per session**.
> Stop at the end of each phase, report, and wait for approval. Do not start the
> next phase on your own.
>
> **How the human starts each session:**
> `Read docs/design/DESIGN_OVERHAUL.md and AGENTS.md and lib/ui2/README.md. Then do Phase N only.`
>
> Reference images (the mood board) are in `docs/design/refs/`. Open them with
> the Read tool before Phase 1 and again before any screen phase.

---

## 1. What you are changing, and what you must not touch

**Scope: visual layer only.** That means `lib/ui2/**`, `lib/theme/**` (cleanup),
`assets/fonts/**`, `assets/images/**`, `pubspec.yaml` (`flutter:` assets/fonts
block only), and the `test/ui2_*` design-system tests listed in §11.

**Out of scope. Do not edit:** anything in `lib/ble`, `lib/compute`, `lib/data`,
`lib/state`, `lib/sync`, `lib/notify`, `lib/coach`, `lib/health`, `lib/import`,
or `lib/ai`, and no metric or derivation logic anywhere. If a screen's *data*
looks wrong to you, write it down in your phase report. Do not fix it.

These rules come from the repo itself and still apply to every pixel you draw:

1. **Never fabricate a metric.** An absent value is `StatusCard` /
   `StatusCard.forMetric`, never "—", never a placeholder number, and never a
   pretty empty ring that *looks* like a value. The new hero styles (the scallop
   badge, aurora tiles, big numerals) must have **no absent variant**. When the
   value is null, the screen falls back to `StatusCard`. A calibrating
   readiness keeps `DashedRing`.
2. **Never guess a cause.** Copy rules in `lib/ui2/README.md` ("what is
   missing → why → what fixes it", banned respiratory strings, no "you have")
   are unchanged. Don't rewrite copy unless a phase says so.
3. **Tokens only.** `test/ui2_tokens_test.dart` bans raw `fontSize:`,
   `Color(0x…)`, `Colors.white/black`, `BorderRadius.circular(n)`, `Duration(…)`,
   `.repeat(`, and raw `GestureDetector/InkWell/Listener` outside `theme.dart` /
   `grammar.dart`. Keep that boundary. Extend it (§11), never loosen it.
4. **Contrast is solved, not eyeballed.** Every ink/accent/surface pair must
   clear 4.5:1 in **both** themes. `test/ui2_contrast_test.dart` must keep
   passing (updated per §11 for the new fill model).
5. **Overflow and tap size.** `test/ui2_component_sweep_test.dart` pumps every
   gallery case at 1.0/1.4/2.0/3.0/3.1× text and fails on any overflow or any
   `Pressable` under 44 pt. Seven languages ship (en, de, es, fr, hi, ru, zh).
   Russian and Hindi are long, so design for them.
6. **Reduced motion.** Every duration goes through `motion()` / `animate()`.
   No looping animation without a caller-owned phase.
7. **Performance.** Heavy work never runs on the UI isolate, and a theme change
   must not cause a rebuild storm. This has starved background BLE before (AGENTS
   §4.4). Blur and gradients follow the budget in §5.7.
8. **Offline and private.** Fonts and images are **bundled assets**. Nothing is
   fetched at runtime (no `google_fonts`, no network images). 
9. **Trademarks.** The mood board shows a third-party brand. The redesign must
   never show WHOOP (or any device maker's) name, logo, or product styling as our
   own branding. Generated device images are logo-less and generic (see
   `docs/design/IMAGE_PROMPTS.md`). Keep the README disclaimer intact.
10. **Ponytail discipline** (`.claude/skills/ponytail/SKILL.md`): reuse before
    you write, keep diffs as small as possible, and add no new dependencies unless §10 names
    them.

## 2. Strategy: re-skin through the system, not screen by screen

The app already has a strict design system: tokens in `lib/ui2/theme.dart`,
components in `lib/ui2/grammar.dart`, painters in `lib/ui2/charts.dart` /
`paint_activity.dart`, and the shell in `lib/ui2/app_shell.dart`. In the audit, 77
files / ~61k lines in `lib/ui2` were built on it: `StatusCard` ×251, `Surface`
×233, `Section` ×148, `Pressable` ×145, `Pill` ×75, `ChartFrame` ×64,
`BigButton` ×57, `NavBar` ×38.

**So most of the overhaul happens in about 5 files.** Change the tokens and the
components first, and roughly 80% of the app re-skins itself. Then the screen phases
only fix what the system cannot reach: one-off layouts, raw Material widgets, and
heroes.

This is also what keeps the fork mergeable with upstream `OpenStrap/edge`,
whose screen files change constantly. **Edit as few screen files as you can, and
make screen edits small and mechanical.**

Leaks the audit found, which the system phases must close:

| Leak (in lib/ui2, outside grammar.dart) | Count | Fix |
|---|---|---|
| `TextButton` | 33 | new `TextAction` component |
| `showModalBottomSheet` direct | 22 | new `AppSheet.show()` |
| `AlertDialog` | 13 | new `AppDialog.show()` |
| `TextField` | 38 | new `AppField` |
| `Switch(` | 6 | new `AppSwitch` |
| Icon `size:` literals (14 different values, 12–54) | ~180 | icon size tokens `I.*` |
| raw `Container(` | 98 | review; most become `Surface` or token boxes |
| `Ring(… C.green …)` raw pigment (home_screen) | ≥1 | pass solved colour |

Dead weight to remove at the end (Phase 7): the legacy "Ember" theme in
`lib/theme/tokens.dart` + `lib/theme/theme.dart` (`AppColors`, `Palette`,
`buildOpenStrapTheme`). It survives only through `ThemeController`, which still
sets `AppColors.active` and paints the **Android system nav bar with the Ember
`AppColors.bg`**. That colour does not match `ui2`'s `p.bg`. The Barlow
Condensed fonts are used only by that legacy theme.

## 3. Design direction: "Volt"

**One sentence:** a near-black, quiet, premium instrument with one electric
lime accent, soft geometric type, very round shapes, and colour that shows up
only where there is data.

The mood board (`docs/design/refs/`):

- **Palette card:** char `#0F1014`, volt lime `#B1F002`, white, coral
  `#FB6B53`, slate `#3A444B`, and a geometric sans (Lufga).
- **Onboarding screens:** black canvas, frosted-glass pills, circular icon
  buttons, a lime organic "path" that winds down the screen through step dots,
  a thin lime arc around the product, and a lime pill CTA with a dark icon.
- **Glucose dashboard:** tiles that are soft, grainy, blurred colour fields
  ("aurora tiles") in pink / sage / blue / orange, with a big light-weight number
  on each.
- **Healthspan screens:** a cream/off-white light mode with black chrome, a
  **scalloped badge** around the hero number, black circular nav buttons, a
  lime active state, and big medium-weight numerals with a small unit.

Principles, in priority order:

1. **Monochrome first.** Surfaces and chrome are char/cream + ink. Colour is
   earned.
2. **Lime is the one action colour.** It means "act here / you are here /
   good". Budget: **at most one lime primary CTA per screen**, plus the active nav
   item, plus progress fills. Lime is **never text on a light surface**
   (1.37:1). In light mode lime is only a fill, with dark ink on it.
3. **Data colour lives in data.** Domain hues show up in charts, aurora tiles
   and hero glows. They never appear in buttons or chrome.
4. **Coral is signal, not brand.** Low / attention / destructive only.
5. **Round, soft, generous.** Big radii, pill controls, circular icon buttons,
   lots of air. Hairlines instead of shadows in dark mode.
6. **One hero per screen.** Each screen has one thing you see first: a scallop
   badge, a big numeral, or an aurora tile. Everything else steps down.

## 4. Tokens: exact values (`lib/ui2/theme.dart`)

Keep the class names (`C`, `P`, `F`, `S`, `R`, `Motion`) and **keep every
existing member name** so call sites don't churn. Change the values. Add the new
members listed here. All contrast numbers below were measured with the WCAG
formula and match `P.contrast`.

### 4.1 Neutrals and surfaces

| Token | Dark ("Char") | Light ("Cream") |
|---|---|---|
| `p.bg` | `#08090B` | `#F2F1EC` |
| `p.card` | `#131418` | `#FFFFFF` |
| `p.card2` (recessed / icon-button fill) | `#1C1E23` | `#E9E8E2` |
| `p.line` (hairline) | `#25282E` | `#DCDBD4` |
| `p.track` (ring / progress track) | `#2A2D33` | `#E2E1DA` |
| `p.ink` | `#F4F4F1` (15.1:1 on card2) | `#0F1014` (15.5:1 on card2) |
| `p.ink2` | `#A7AAB1` (7.2:1 on card2) | `#474B53` (7.1:1 on card2) |
| `p.ink3` | `#8B9099` (5.2:1 on card2) | `#5F646D` (4.85:1 on card2) |
| **new** `p.glass` | `#131418` @ 72% + blur 24 | `#FFFFFF` @ 72% + blur 24 |
| **new** `p.inverse` (black chrome on cream / cream on char) | `#F4F4F1` | `#0F1014` |
| **new** `p.onInverse` | `#0F1014` | `#F4F4F1` |

### 4.2 Brand and signal

| Token | Value | Notes |
|---|---|---|
| **new** `C.volt` | `#B1F002` | Primary action, active nav, "good" progress. Dark ink on it: 13.9:1. White on it: 1.37:1, **never** use white. |
| **new** `C.coral` | `#FB6B53` | Low / attention / destructive. Dark ink on it 6.6:1. White on it 2.9:1, **never** use white. |
| **new** `C.slate` | `#3A444B` | Secondary dark chips, inactive controls on cream. |
| `C.green` / `C.greenD` | alias → `C.volt` | Keeps existing call sites compiling. Remove in Phase 7 only if it's trivial. |
| `C.red` | alias → `C.coral` | same |

### 4.3 Data palette (domain hues: charts, aurora, hero glow only)

All of these clear 4.5:1 as text on dark `card2` and as a fill under **dark** ink.
In light mode they pass through `p.on()` to become legible text.

| Domain / role | Token | Value |
|---|---|---|
| Today / readiness "high" | `C.domHome` | → `C.volt` |
| Sleep | `C.domSleep` (was indigo) | `#A99BFF` lavender |
| Activity / strain | `C.domMove` (was purple) | `#6EC3FF` sky |
| Health / heart | `C.domHealth` (was blue) | `#FF7A9A` rose |
| Mind / wellness | `C.domMind` (was teal) | `#9FD4B4` sage |
| Food | `C.domFood` (was orange) | `#FFB547` amber |
| Extra series | `C.aqua` | `#5ED3C9` |

Remap the old raw accents (`blue`, `purple`, `indigo`, `teal`, `orange`, `yellow`,
`pink`, `sky`, `blueSoft`) onto this palette so no off-palette hue survives.
Keep them as aliases, and update `C.all` so the contrast sweep covers every
value. Keep the route ramp and `mapFloor/mapCeil` as they are (they're tuned
for a map, see the comments in theme.dart). Only retune `routeFast`/`routeMid`
if they clash.

### 4.4 The fill model changes (important)

Today `p.fill(accent)` darkens the accent until **white** text passes. With
this palette, that turns volt into olive mud. The new model:

- `p.fill(accent)` returns the **pure pigment** when `C.ink-dark (#0F1014)` on it
  clears 4.5:1. If it doesn't, it falls back to the current darken-for-white
  solve.
- **new** `p.inkOn(Color fill)` returns `#0F1014` or `#FFFFFF`, whichever clears
  4.5:1 (prefer dark). `p.inkOnFill` stays as a getter for compatibility but is
  deprecated. Migrate its call sites in grammar.dart to `p.inkOn(p.fill(a))`.
- `p.on(accent)` (accent as text) keeps its current solver.
- `p.wash(accent)` keeps its current behaviour; dark-mode alpha can rise to 0.20.

### 4.5 Type (`F`)

- **Family: a free SIL-OFL geometric sans (decided: no paid fonts).** One
  bundled family for everything, on every platform (stop using `.SF Pro Text`).
  This replaces the iOS/Android split, so both platforms render the same design.
  The mood board's Lufga and Gilroy are commercial and are **not** used.
  - **Candidates, in order of preference:** **Urbanist** (closest to Gilroy and
    Lufga), then **Outfit**, then **Plus Jakarta Sans**. Download the `.ttf`
    files from each font's official GitHub repo or Google Fonts (into a scratch
    dir first), and include its `OFL.txt` when bundled.
  - **Tests each candidate must pass (check with fontTools,
    `pip install fonttools`):**
    1. `tnum` (tabular figures) in the `GSUB` feature tags. The `F.n*` numerals
       depend on it, since a live number must never re-flow its own layout.
    2. Latin Extended-A (ő, ű, ä, é) and Cyrillic coverage (the app ships
       Russian). A face with no Cyrillic still works, because Russian falls back
       to the platform font. Report it, and check the sweep test for Russian at
       3.1× text.
    3. Static weights 400/500/600 exist, or a variable font whose axes Flutter
       can use (`FontVariation`). Prefer static `.ttf` files, so the weights are
       exact.
  - **Pick the first candidate that passes test 1.** If none has `tnum`, use the
    best-looking one and apply the tabular fix in `Numeral` only (fixed-width
    digit boxes). Report which case applies. Do not silently change the family
    later.
  - Bundle weights 400/500/600 (+700 only if a step uses it). Family name in code:
    the chosen family. Remove the Manrope and Barlow Condensed declarations in
    Phase 7 once nothing references them.
- **Character:** large text is lighter than today. Display/hero use **w500**,
  not w700 (the mood board's "Connect Your Whoop" is regular-medium at large
  size). Titles use w600. Body uses w400.
- **Ramp** (keep names, adjust values; add `n64`):

| Token | Size / line | Weight | Tracking |
|---|---|---|---|
| `F.display` | 36 / 42 | 500 | −0.8 |
| `F.t1` | 28 / 34 | 500 | −0.5 |
| `F.t2` | 22 / 28 | 600 | −0.3 |
| `F.head` | 17 / 24 | 600 | −0.2 |
| `F.body` | 15 / 22 | 400 | −0.1 |
| `F.cap` | 13 / 18 | 400 | 0 |
| `F.over` | 11 / 14 | 600 | +0.6 (callers uppercase it) |
| **new** `F.n64` | 64 / 1.0 | 500 | −2.4, tnum |
| `F.n48` | 48 / 1.0 | 500 | −1.6, tnum |
| `F.n34` | 34 / 1.0 | 500 | −1.0, tnum |
| `F.n24` | 24 / 1.0 | 600 | −0.6, tnum |
| `F.n17` | 17 / 1.0 | 600 | −0.3, tnum |

- **Units** sit next to numerals in `F.cap` or `F.body`, `p.ink3`, aligned to the
  baseline (`84 mg/dl`, `115 bpm`). Add a small `Numeral(value, unit, style)`
  helper in grammar.dart so every screen does this the same way.

### 4.6 Spacing, radii, icons, elevation

- `S`: keep the 4-pt grid. Add `S.gutter = 20` (screen side padding; today it
  varies) and `S.navClear` = floating-nav height + bottom inset + `S.x4`, so
  scroll content never hides behind the bar.
- `R` (rounder than today):

| Token | Old | New | Used for |
|---|---|---|---|
| `R.sm` | 8 | 10 | small chips, inner bars |
| `R.md` | 12 | 16 | fields, small tiles |
| `R.lg` | 16 | 22 | list groups, sheets' inner cards |
| `R.xl` | 24 | 28 | **every `Surface` card** |
| `R.xxl` | 32 | 36 | hero tiles, sheet top corners |
| `R.pill` | 999 | 999 | buttons, chips, nav |

- **new `I`** icon sizes: `I.sm 16`, `I.md 20`, `I.lg 24`, `I.xl 32`, `I.hero
  48`. Every `Icon(size:)` in lib/ui2 uses one of them. Lucide stays as the icon
  set (its thin stroke matches the mood board), so don't add an icon dependency.
- **Elevation:** dark mode is flat: no shadows, a 1 px `p.line` hairline, and
  optionally a 2–3% top-to-bottom white gradient on hero cards. Light mode uses
  one soft shadow (`el(1)`: 0 / 8 / 24, ink @ 6%) and no hairline. `p.el()` keeps
  its signature.

### 4.7 Motion

Keep `fast 120 / base 180 / slow 280` and the gate. Add `Motion.hero = 420 ms`
for one-time hero draw-ins (rings, scallop). Add curve tokens `Ease.standard
= Curves.easeOutCubic` and `Ease.emphasized = Curves.easeOutBack` (scale
only, never on layout). Still no `.repeat(`.

## 5. Components (`lib/ui2/grammar.dart`)

Every change here re-skins hundreds of call sites. Keep constructor signatures
**source-compatible**: add optional named params, don't rename or reorder.

### 5.1 Restyle existing

- **`Surface`**: radius `R.xl`, padding `S.x5` (20). Dark: `p.card` + 1 px
  `p.line` border, no shadow. Light: `p.card` + `el(1)`, no border. Pressed
  state: scale 0.98 through `Pressable` (gated).
- **`Section`**: title `F.head` w600 `p.ink`, action as `TextAction` (§5.2).
  Spacing above a section `S.x8`, below the title `S.x3`.
- **`ScreenTitle`**: `F.display`, left-aligned, with trailing slot for
  `ProfileAvatar` / round icon buttons.
- **`NavBar`** (pushed screens): left `RoundIconButton(arrowLeft)`, centred
  title `F.head`, right slot for one `RoundIconButton` (close / info / more).
  Matches the "Step 3 ← ×" header.
- **`BigButton`**: height 56, `R.pill`. Primary = `p.fill(C.volt)` + `p.inkOn`.
  `soft: true` = `p.card2` + `p.ink`. **New** optional `tone: ButtonTone.inverse`
  = `p.inverse` + `p.onInverse` (the black pill on cream), and `tone:
  ButtonTone.danger` = coral text on `p.card2`. Icon-only primary variant =
  56 circle (the lime power button).
- **`Pill`**: `R.pill`, `p.wash(c)` + `p.on(c)`, `F.cap` w600.
- **`SubTabs`**: a segmented pill row. Active = `p.inverse` fill + `p.onInverse`
  text (monochrome; lime stays reserved). Inactive = transparent + `p.ink2`.
  Horizontal scroll stays, with a fade edge instead of the chevron.
- **`SignalCard` / `TrendCard` / `ProgressCard` / `DeepDiveCard`**: big numeral
  via `Numeral`, label `F.cap p.ink2` on top, icon in a 32 px `p.card2` circle.
  Sparklines get rounded caps, 2 px stroke, and no fill in dark (or a 12% fill).
- **`InsightCard` / `Observation` / `Recommendation`**: `p.card2` surface, a small
  circular icon chip, no coloured borders. `Recommendation` CTA = `TextAction`
  with an arrow.
- **`StatusCard`**: keep the three-part copy. Visual: `p.card` with a **dashed**
  1 px `p.line` border (absence reads as "outline, not filled"), and a
  `circleHelp` icon chip in `p.card2`. `fix:` renders as `BigButton(soft:
  true)`.
- **`MetricRow`**: 64 pt rows inside one grouped `Surface` with inset hairlines
  (the Health › Overview list). The value is `F.n17` + unit. The direction arrow
  stays (the README explains why).
- **`Consistency`**: 7-dot / N-dot row of circles (the "This week" M–S row),
  filled = `p.fill(C.volt)`, empty = `p.card2`. Still not a streak.

### 5.2 New components (add each to the gallery in the same commit)

- **`RoundIconButton(icon, onTap, semanticLabel, {tone})`**: 44 pt min (48
  visual), circle, `p.card2` (or `p.glass` over imagery, or `p.inverse` on
  cream). Replaces ad-hoc back/close/settings/AI buttons.
- **`TextAction(label, onTap, {icon, tone})`**: replaces `TextButton`. `F.body`
  w600, `p.ink` (dark) / `p.ink` (light) with optional trailing arrow, and coral
  for `tone: danger`. Lime text is only allowed in dark mode, and only for the
  single primary action of a card.
- **`AppSheet.show(context, {title, child, actions})`**: `p.card`, top radius
  `R.xxl`, grab handle, uses `sheetMotion()`. Replaces direct
  `showModalBottomSheet`.
- **`AppDialog.show(context, {title, body, primary, secondary, destructive})`**:
  radius `R.xl`, buttons are `BigButton`s stacked full-width.
- **`AppField`**: filled `p.card2`, radius `R.md`, no underline, label above in
  `F.cap p.ink2`, focus ring 2 px `p.ink` (not lime in light mode).
- **`AppSwitch`**: track on = `p.fill(C.volt)` with a dark thumb, off =
  `p.track` with a `p.ink3` thumb. Must keep the switch semantics role.
- **`Glass({child, radius})`**: a `BackdropFilter` blur 24 + `p.glass` tint + 1 px
  white @ 8% hairline. **Budget:** see §5.7. Has a `solid` fallback (no blur)
  used automatically when `MediaQuery.highContrast` is on or when the
  performance flag in §5.7 says so.
- **`ScallopBadge({value, unit, label, delta, size})`**: the signature
  element. A 12-lobe scalloped disc (`ShapeBorder` or `CustomPainter` in
  charts.dart; the lobe count and depth are constants in theme.dart) filled with
  cream `#F2F1EC` in **both** themes, holding an `F.n34` numeral + label + a small
  delta caret. Draw-in: scale 0.92→1 with `Ease.emphasized` over `Motion.hero`,
  gated. **Rule:** at most one per screen, and only for a present value. No
  absent variant.
- **`AuroraTile({hue, child, intensity})`**: a card whose background is 2–3
  blurred radial gradients of a domain hue over `p.card` (dark) or a pale wash
  (light), plus a subtle grain (bundled `assets/images/grain.png`, tiled at
  ~4% opacity). Painted once, wrapped in `RepaintBoundary`, never animated.
  **Contrast rule:** text on the tile is measured against the **brightest point
  of the gradient**, blended over the card, and it must clear 4.5:1. Add this
  case to the contrast test.
- **`StepPath`**: the onboarding "lime river". A smooth cubic path that winds
  through N step dots, drawn with `p.fill(C.volt)` at ~10 px stroke with
  rounded joins. Completed steps are filled dots, the current one is a ringed dot,
  and future ones are `p.card2`. Purely decorative: `ExcludeSemantics`, and the
  step text carries the meaning.
- **`Numeral(value, {unit, style, color})`**: baseline-aligned number + unit
  (§4.5).

### 5.3 Floating tab bar (`app_shell.dart`)

- A floating `Glass` pill, inset `S.x4` from the sides and from the bottom safe
  area, height 64, radius pill.
- Active tab = `p.fill(C.volt)` pill (icon + label, dark ink). Inactive = icon
  + label in `p.ink3`, no background. **Keep labels on every tab** (a11y + text
  scale), and keep the 44 pt targets, `Semantics(selected:)`, and the back-stack
  behaviour exactly as they are.
- The domain accent no longer colours the tab bar (decision D1, §12: lime for
  every active tab).
  `ShellDomain.accent` stays and feeds the screen's hero glow / aurora instead.
- Content behind the bar: every tab's scroll view gets `S.navClear` bottom
  padding. The `banner` slot (minimised workout) floats just above the bar as
  its own `Glass` pill.
- The Android system nav bar colour is `p.bg` (fixed in Phase 7 when
  `ThemeController` drops `AppColors`).

### 5.4 Header pattern (every tab root)

`ScreenTitle` (greeting or tab name) on the left. On the right: `RoundIconButton`s
(AI briefing ✦, settings ⚙) and `ProfileAvatar`. The date / sync line is under
the title in `F.cap p.ink2`. The day switcher is a pill with chevrons, centred.

### 5.5 Charts (`charts.dart`, `paint_activity.dart`)

- Strokes 2 px with round caps and joins. Area fills 10–14% of the line colour,
  fading to 0. Gridlines are `p.line` at 1 px dashed 2/4. Tick labels stay
  `p.ink3`, `F.cap`, tabular.
- **`Ring`**: stroke 12 (Today trio) with round caps, track `p.track`, and the
  **value numeral inside the ring** (today the number is under it). The icon moves
  under the ring with the label. `DashedRing` stays for calibrating.
- **Readiness colour ramp:** coral (<34) → amber (34–66) → volt (≥67). Use the
  same thresholds the code uses today; don't invent new ones. If the code has no
  thresholds, keep the single domain colour.
- **HR zones (1–5):** slate-blue → sky → volt → amber → coral. Re-solve to keep
  `zone_contrast_test` passing.
- **Hypnogram:** keep the rule "awake palest → deep darkest, each its own
  contrast step", built as a lavender ramp (awake `#E6E1FF`, REM `#C7BDFF`,
  light `#A99BFF`, deep `#6F5CF0`) in dark. Re-solve for light. Rounded 4 px
  segment ends. Legends still come from `Hypnogram.legend`.
- The live HR line is coral, with a glowing end dot (static glow, no pulse loop).
- `ChartFrame` keeps every rule in README "Reading a chart". Restyle only.

### 5.6 Imagery slots

All images are bundled WebP with transparent backgrounds, with `@2x`/`@3x`
variants in `assets/images/2.0x|3.0x`. **Load them only through a new
`Art` enum in theme.dart** (`Art.bandHero`, `Art.bandSide`, …) mapping to
filenames, so no screen writes an asset path. Every image gets a
`semanticLabel` or `excludeFromSemantics: true` when it's decorative. Budget:
≤ 120 KB per @3x file. The slots and exact filenames are in
`docs/design/IMAGE_PROMPTS.md` §"Asset slots". If a file is missing, the `Art`
widget renders nothing (and never a broken-image icon), so code can land before
art.

The cream cartoon mascots (`mascot_workout.png`, `mascot_wellness.png`, and
their 2.0x/3.0x copies) are **replaced** by the new 3D-object art in `StartCard`
(decision D2). `StartCard` keeps its layout fixes (see its header comment).
Only the art and the ground change. The `StartCard` code comments about
"both mascots are CREAM" and the cream-on-pale-card problem go away, because the
new art is black objects on a coloured aurora. Update them. Leave no mascot
references behind.

### 5.7 Performance budget (glass, gradients)

- At most **two** `BackdropFilter`s on screen at once: the tab bar, plus one
  overlay (a sheet header or a pill over imagery). **Never** in a list item.
- Aurora tiles and the scallop are painted once and cached by
  `RepaintBoundary`. No shader animation, no per-frame gradient rebuilds.
- Add `Perf.lowGlass` (a const in theme.dart, default false). When true,
  `Glass` renders solid. Wire it to nothing yet. It's the escape hatch if Android
  jank shows up.
- Theme switching: `P` stays a cheap const-constructed object, with no new
  `InheritedWidget` that rebuilds the whole tree.

## 6. Screen notes (what the system won't fix by itself)

Do these **after** the system phases. Domain batches, one phase each (§10).

**Today** (`home_screen`, `readiness_detail`, `driver_breakdown`,
`what_changed`, `ai_briefing`, `day_timeline`, `rough_night`): header per §5.4.
Hero = `RingTrio` restyled (numerals inside the rings, 12 px stroke) **or**
readiness in a `ScallopBadge` when present with the strain/sleep rings smaller
beside it. Pick the one that tests better at 3.1× text and in Russian, and show
both in the gallery. "At a glance" becomes a 2-column grid of `AuroraTile`s (heart
= rose, steps = volt, energy = amber), and the tiles keep the same values and
`StatusCard` fallbacks. "Today's plan" becomes grouped `MetricRow`-style rows.

**Sleep** (`sleep_tab`, `sleep_detail`, `naps`, `circadian_detail`,
`month_grid`): hero = total sleep `F.n64` + a lavender aurora glow behind it.
Day switcher pill. Hypnogram card per §5.5. "Staged from signals" card actions
become `TextAction`s.

**Activity** (`workout_screen`, `activity/*`, `log_workout`,
`detected_activities`, `day_steps`, `nutrition_screen`, `log_food`,
`scan_barcode`): `StartCard` uses new art on a sky aurora ground, with a volt circular
play button. Activity shortcuts are 3 `Surface` tiles with icon chips. The week row
is `Consistency` dots. The live workout screen (`activity/live.dart`) is the
one place a full-bleed dark layout is allowed in light mode: big `F.n64` HR +
coral live line, with controls as `RoundIconButton`s + one volt primary. Don't
touch the session clock (`Motion.tick`). The poster/share renderer
(`poster.dart`) gets the new palette but keeps its layout.

**Health** (`health_screen`, `metric_detail`, `investigate`, `beats`, `ecg`,
`ecg_widgets`, `findings_log`, `wellness_screen`, `cycle_screen`,
`calm_breathing`, `journal_compose`, `custom_journal_field_sheet`, `coach*`,
`advanced`): Overview = grouped `MetricRow` list. `metric_detail` hero = big
`Numeral` + `Pill('LIVE')` in coral, "Your normal range" = 3-up numerals in one
`Surface`. Calm breathing: the sage aurora + `BreathRing` (phase stays
caller-owned). The ECG trace keeps clinical legibility: high-contrast ink line on
`p.card`, **no** aurora behind it.

**Profile & settings** (`profile/*`): grouped lists with inset hairlines,
`AppSwitch`, `RoundIconButton` header. Devices / pair sensor use the device art.
`gallery.dart` gets a new top section, "Volt system", that shows every token
(swatches with their measured contrast, the type ramp, radii, icons) in both
themes.

**Onboarding** (`splash`, `welcome`, `pairing`, `profile_setup`,
`pairing/device_picker`): this is where the mood board's onboarding screens
apply most directly. Black canvas (in both themes; onboarding is always Char),
`StepPath` winding through the steps, `Glass` step pills ("Step 2 · Connected"),
device art with a thin volt arc, a large `F.display` w500 headline ("Connect
your band"), and a volt circular CTA. Copy stays as it is except the headline
casing.

## 7. Copy and l10n

- No copy rewrites unless a phase says so. New strings go into `app_en.arb`
  with the existing `l?.key ?? 'English'` fallback pattern. Don't machine-translate
  the other six ARB files. List the new keys in your phase report.
- Never print a brand name of a device maker in decorative UI.

## 8. Accessibility checklist (every phase)

44 pt targets · 4.5:1 for all text, including on aurora and glass · labels on
all tabs · `semanticLabel` on every `RoundIconButton` · reduced motion lands on
a finished state · 3.1× text without overflow · hue never the only carrier of
meaning (arrows, labels, and legends stay).

## 9. Verification harness (build it in Phase 0)

You can't see a phone, so make the app show itself to you:

- `test/design_snapshots_test.dart`: pumps every gallery case (and, from
  Phase 5, each tab root with fixture data) in **dark + light** at **1.0× and
  2.0×** text on a 390×844 surface, and writes PNGs to `build/design_snapshots/`
  via `matchesGoldenFile` + `--update-goldens`, or `RenderRepaintBoundary.toImage`.
  **Load the real fonts with `FontLoader`** in `setUpAll`, or every glyph renders as
  Ahem boxes. Tag it `@Tags(['snapshots'])`, keep it out of CI (`dart_test.yaml`
  or a skip unless `SNAPSHOTS=1`), and gitignore the output.
- After every change you make in a phase, regenerate the snapshots and **open
  the PNGs with Read** to check them against `docs/design/refs/` before
  reporting.
- Every phase ends green on: `flutter analyze`, `flutter test test/ui2_*
  test/ui2/ test/zone_contrast_test.dart`, then the full `flutter test` before
  the phase report.

## 10. Phases

Each phase is one session and ideally one commit/PR, on a branch
`ui/volt-phase-N`. End every phase with a short report: what changed, the
snapshot PNG paths to look at, test results, open questions, and any data bugs
noticed.

**Phase 0: audit and harness (no visual changes).**
1. Read AGENTS.md, lib/ui2/README.md, theme.dart, grammar.dart, app_shell.dart,
   charts.dart, gallery.dart, and the ui2 tests.
2. Build the snapshot harness (§9) and produce a "before" set.
3. Font shortlist: download Urbanist, Outfit and Plus Jakarta Sans (OFL, from
   their official repos, into a scratch dir, **not** assets yet), run the three
   checks in §4.5, and render one specimen PNG per font using the app's real
   numbers (`84`, `7h 28m`, `1,174`, `14.8 br/min`) at `F.n64` / `F.display` /
   `F.body`. Recommend one, defaulting to Urbanist if it passes.
4. Produce `docs/design/AUDIT.md`: the leak table from §2 re-counted, every raw
   Material widget site, every icon-size literal, and every screen whose hero will
   change.
5. **Stop.** The human confirms the font pick from the specimens and the open
   items in §12.

**Phase 1: tokens.** Implement §4 in `theme.dart` (+ bundle the chosen font,
and remove nothing yet). Update `ui2_contrast_test` for the new fill model and
aurora (§11). Snapshots of the gallery in both themes. Expect the whole app to
re-colour. That's the point.

**Phase 2: components.** Implement §5.1 and §5.2 in `grammar.dart` (+ painters
in `charts.dart`), each new component in the gallery. Extend the tokens test
(§11). Don't touch screen files except to fix compile errors.

**Phase 3: shell, charts, imagery plumbing.** §5.3, §5.4, §5.5, the `Art` enum
§5.6 (renders nothing until assets exist), and `S.navClear` on every tab root.

**Phase 4: migrate leaks.** Mechanical replacement across lib/ui2: `TextButton`
→ `TextAction`, `showModalBottomSheet` → `AppSheet.show`, `AlertDialog` →
`AppDialog.show`, `TextField` → `AppField`, `Switch` → `AppSwitch`, icon size
literals → `I.*`. Then turn on the new bans in the tokens test. Keep behaviour
identical: same callbacks, same validators, same semantics.

**Phase 5a–5e: screens by domain** (§6): 5a Today, 5b Sleep, 5c Activity, 5d
Health, 5e Profile + Onboarding. Add each tab root to the snapshot harness
with fixture data (reuse `test/support/` fixtures). After the system is locked
(end of Phase 4), these may run as parallel subagents in separate worktrees, one
per domain, because they touch disjoint files.

**Phase 6: art drop-in.** The human places generated images in
`assets/images/` (names per IMAGE_PROMPTS.md). Optimise them (WebP, ≤120 KB @3x),
generate @1x/@2x, wire `StartCard` / onboarding / devices, and delete the mascot
files.

**Phase 7: cleanup.** `ThemeController` stops using `AppColors` (system nav
bar → `P(isDark).bg`, widget theme call stays). Delete `lib/theme/tokens.dart`,
`lib/theme/theme.dart` (after grepping the whole of `lib/` and `test/` for
`AppColors|AppText|Palette|buildOpenStrapTheme|kLightStageColor`), remove Barlow
Condensed + Manrope if unused, remove compatibility aliases that have no callers,
update `lib/ui2/README.md` to document Volt, regenerate `screenshots/*.png`, and
update the iOS widget/Live Activity colours (`WidgetService`) if they hardcode
the old palette (flag it if that needs Swift changes).

## 11. Test changes you are allowed (and expected) to make

- `ui2_contrast_test.dart`: replace "white on `fill(accent)`" with
  "`inkOn(fill(accent))` on `fill(accent)` ≥ 4.5". Add: text on `AuroraTile`'s
  peak colour, text on `Glass` over `p.bg` and over the brightest art pixel tint
  you allow (use the solid fallback colour), and `ScallopBadge` ink on cream.
- `ui2_tokens_test.dart`: **add** bans (outside grammar.dart/theme.dart) on
  `TextButton`, `AlertDialog(`, `showModalBottomSheet(`, `TextField(`,
  `Switch(`, numeric `size:` on icons, numeric `EdgeInsets` literals,
  `Image.asset(` (use `Art`), and `BackdropFilter(` (use `Glass`). Never remove an
  existing ban.
- `zone_contrast_test.dart`: update the expected palette only.
- Never weaken a threshold, never delete a test to make a phase pass. If a rule
  blocks the design, stop and ask.

## 12. Decisions

**Decided by the human (do not reopen):**

- **D1 Tab bar: volt (lime) for every active tab.** The domain hue does not
  colour the tab bar. It moves into each screen's hero glow / aurora.
- **D2 Mascots: replaced** with the 3D-object art (`art_workout.png`,
  `art_wellness.png`, etc.). Delete the two mascot files in Phase 6.
- **D3 Font: a free open-licence font** (Urbanist by default). Paid fonts such as Lufga and Gilroy are out. Final pick from the Phase 0 specimen (§4.5).

**Decided after Phase 0 (see `docs/design/AUDIT.md` §5):**

- **D3a Font: Outfit.** Urbanist has no `tnum`; Outfit is the first candidate
  that passes §4.5 test 1. No Cyrillic, so Russian falls back to the platform
  face.
- **D6 Readiness ramp** uses the code's own cut-offs (`lib/compute/findings.dart`):
  coral < 26, amber 26–37, volt ≥ 37. This replaces the 34 / 67 example in §5.5.
- **D7 `zone_contrast_test`** gets pointed at ui2's `ZoneRows.pigment` through
  `P` in Phase 3. It currently guards the legacy `AppColors` zones, which Phase
  7 deletes.
- **D8 Uncovered Material widgets** (`Divider`, `SnackBar`, progress
  indicators, date/time pickers, dropdowns) are restyled with `ThemeData`
  sub-themes in `buildTheme` during Phase 1. No new components, no call-site churn.
- **D9 `ui2_tokens_test` path fix** at the start of Phase 1: normalise `\` →
  `/` so the allow-list matches on Windows. This doesn't loosen anything.
- **D10 `ui2_scroll_hint_test`** fails after Phase 1 by design: it measures
  the five-tab `SubTabs` rows in Manrope, and Outfit is narrower (Health fits
  at 430 pt; Labs shows 25 pt at 390). Leave it failing. **Phase 2 re-measures
  it** once `SubTabs` is restyled (§5.1), updating only the measured premises.
  The `ScrollHint is honest` group stays as is.
- Reference images now live in `docs/design/refs/` (`01_palette_type` …
  `05_connect_hero`).

**Still open (defaults apply unless the human says otherwise):**

- **D4 Light mode.** Default: keep it, as "Cream". Onboarding and the live workout
  stay Char in both modes.
- **D5 Today hero.** RingTrio-restyled vs ScallopBadge + small rings. Picked from
  the Phase 5a snapshots.

## 13. Don'ts

No new state management, no new navigation package, no animation package, no
`google_fonts`, no network images, no shader/Rive/Lottie dependencies. No fifth
tab. No streaks. No second copy of a value on one screen (AGENTS §4.10). No
decorative number that isn't real data. No colour that isn't a token. No
screen-level `Theme(...)` overrides.
