# lib/ui2 — the design system

Everything a screen needs, and nothing a screen may bypass. Import the barrel:

```dart
import 'package:openstrap_edge/ui2/ui2.dart';
```

Five files: `theme.dart` (tokens), `grammar.dart` (components), `charts.dart`
and `paint_activity.dart` (painters), `app_shell.dart` (the five tabs).

---

## The rules the tests enforce

`test/ui2_tokens_test.dart` greps `lib/ui2` and fails the build on any of:

| Banned | Use instead |
|---|---|
| `fontSize:` | `F.body`, `F.cap`, `F.n34`, … |
| `Color(0x…)` | `C.*` / `P.of(context).*` (only `theme.dart` may declare pigment) |
| `Colors.white` / `Colors.black` | `p.card`, `p.ink`, `p.inkOnFill` |
| `BorderRadius.circular(12)` | `R.rMd` (`R.rSm` … `R.rPill`) |
| `.repeat(` | a caller-owned phase value — see `BreathRing.t` |
| `Duration(…)` | `Motion.fast/base/slow` through `motion(context, …)` |
| `GestureDetector` / `InkWell` / `Listener` | `Pressable`, or `Scrubber` for a drag |

Two more tests back it: `ui2_contrast_test.dart` sweeps every accent × every
surface × both themes at a 4.5:1 floor — **including what the painters draw**,
because a mark's colour is information — and `ui2_golden_test.dart` captures
every component in light/dark at 1.0× and 2.0× text scale.

Above 2.0× there are no PNGs, on purpose: iOS reaches 3.1× and Android about
2.6× effective, and 174 more images per tier is 174 more images nobody reviews.
Instead the same case list is pumped at 1.0/1.4/2.0/3.0/3.1× with **any
`RenderFlex` overflow failing the build**, and every `Pressable` in every case
is measured against 44 pt. Both sweeps exist because the 2.0× goldens passed
with fixtures like `'52'` and `'38 min'` while six components overflowed at
that scale on a real duration.

**When you add a screen, add its components to the golden case list.** That is
the whole reason visual fixes stopped regressing.

---

## Tokens — `theme.dart`

```dart
final p = P.of(context);   // first line of every build()
```

### Surfaces and ink (both themes, always)

| Token | What it is |
|---|---|
| `p.bg` | page background |
| `p.card` / `p.card2` | raised card / recessed card |
| `p.line` / `p.track` | hairline / progress track |
| `p.ink` | primary text |
| `p.ink2` | secondary text |
| `p.ink3` | muted / caption text — **still clears 4.5:1 on every surface** |
| `p.el(int level)` | `List<BoxShadow>`; `0` = flat |

### Accents — never raw

`C.green`, `C.blue`, `C.purple`, `C.orange`, `C.red`, `C.teal`, `C.yellow`,
`C.pink`, `C.indigo`, `C.greenD`, `C.sky`, `C.blueSoft`, plus the five domain
aliases `C.domHome/domHealth/domFood/domMove/domMind`.

Raw pigment is **not** legible as text — `C.green` on white is 2.28:1. Convert:

| Call | Meaning |
|---|---|
| `p.on(accent)` | the accent **as text or an icon** on any surface (≥ 4.5:1) |
| `p.fill(accent)` | the accent **as a filled surface** under `p.inkOnFill` (≥ 4.5:1) |
| `p.wash(accent)` | a tint for a card background or an active chip — never carries its own text; pair with `p.on` |
| `p.inkOnFill` | the ink that goes on top of `p.fill` |

`P.contrast(a, b)` is public if you need to measure.

### Type — 7 steps, 3 weights

`F.display` 34 · `F.t1` 28 · `F.t2` 22 · `F.head` 17 · `F.body` 15 ·
`F.cap` 13 · `F.over` 11.

Numerals (tabular figures — a changing value must not re-flow its own layout):
`F.n48`, `F.n34`, `F.n24`, `F.n17`. **Use these for every number that can
change.**

### Spacing and radii

`S.x1` 4 → `S.x16` 64 on a 4 pt grid, plus `S.tap` = 44.
`R.rSm/rMd/rLg/rXl/rXxl/rPill` are `BorderRadius`; `R.sm/md/lg/…` the raw
doubles when a painter needs one.

### Motion

```dart
AnimatedContainer(duration: motion(context, Motion.base), …)
final t = animate(context, controller.value);   // returns 1 when motion is off
Motion.enabled(context);                        // if you must branch
```

`Motion.fast` 120 ms · `base` 180 ms · `slow` 280 ms. Reduced motion collapses
all of them to zero at this one gate. Never start a `repeat()`.

---

## Components — `grammar.dart`

### Pressable — the only gesture primitive

```dart
Pressable({required Widget child, VoidCallback? onTap, String? semanticLabel})

Scrubber({required double? value, required ValueChanged<double> onChanged,
          required String label, required String Function(double) describe,
          required Widget child, double step = .05})
```

`Pressable` applies the 44 pt minimum and gates its press animation. Pass
`semanticLabel` for anything without visible text. **There is no `expand`** —
it used to drop the constraint entirely and the doc comment claimed a hit slop
that did not exist.

`Scrubber` is the only drag: it carries the slider role, so increase/decrease
reach it without a pointer, and `describe` is what those steps say out loud.

### Layout primitives

```dart
Surface({required Widget child, EdgeInsets pad = EdgeInsets.all(S.x4),
         VoidCallback? onTap, Color? color, int elevation = 1,
         String? semanticLabel})

Section(String title, Widget child, {String? action, VoidCallback? onAction})
```

### The seven card jobs

```dart
// A · one number, glanceable, for grids
SignalCard(IconData icon, Color color, String label, String value,
           {String unit = '', String sub = '', VoidCallback? onTap})

// B · moving toward a goal
ProgressCard(String label, String value, String target, double frac,
             Color color, {IconData? icon})

// C · changing over time
TrendCard(String label, String value, String unit, String delta,
          String window, List<double> series, Color color,
          {bool up = false, bool? good = true, VoidCallback? onTap})
          // good: null = no baseline. No arrow, no verdict.

// D · something the system noticed
InsightCard(String headline, String reason,
            {String action = '', IconData icon = LucideIcons.sparkles,
             Color color = C.blue, VoidCallback? onTap})

// E · something the user should do
ActionCard(String title, String meta, String cta, IconData icon, Color color,
           {VoidCallback? onTap})

// F · something absent or uncertain — THE ONLY WAY TO RENDER A MISSING VALUE
StatusCard(String what, String why,
           {String fix = '', IconData icon = LucideIcons.circleHelp,
            VoidCallback? onFix})
StatusCard.forMetric(String what, Metric? m,
           {String unit = 'nights', String why = '', VoidCallback? onFix})
           // -> StatusCard? — null when the metric HAS a value

// G · a gateway into serious data
DeepDiveCard(String label, String value, String unit, String cta, Color color,
             {Widget? preview, VoidCallback? onTap})
```

**Never render `—`.** There is no empty variant of Signal or Trend on purpose.
An absent metric is `StatusCard.forMetric(...)`: what is missing → why → what
fixes it.

**And never guess the why.** A screen may only state a cause the data actually
gave it. `forMetric` renders the metric's OWN note (via `whyFromNote`) ahead of
the `why:` you pass, and when there is neither it says it does not know — a
hardcoded explanation beside an absent value is a guess wearing the clothes of a
diagnosis. The same rule governs `fix:`: an action button is a promise, so never
offer one that cannot change the outcome. "Add your age in Profile" printed to a
profile with an age costs more trust than no button at all.

### Rows

```dart
MetricRow(IconData icon, Color color, String name, String value,
          {String sub = '', String unit = '', List<double?> series = const [],
           Rising rising = Rising.neither,
           String? status, VoidCallback? onTap})
```

The trailing slot is a DIRECTION ARROW, not a sparkline: a 52 pt line chart
showed a shape nobody could read a number off. `series` is read by `trendOf`,
which only calls a direction if the newest three values clear half a standard
deviation of up to fourteen before them — four is enough, so seven recorded
values already produce a direction — inside that it is steady, and with
fewer than seven recorded days it is nothing at all (an empty slot, with the
reason in the semantics, because a flat arrow would claim a measured "no
change"). `rising` says which way is good news for THIS metric and is the only
thing the hue carries; the glyph carries the direction on its own, for the
readers who cannot see the hue.

```dart

InlineMetrics(List<(String label, String value, Color color)> items)
```

### Behavioural rules

```dart
Recommendation(String rec, String reason, String action,
               {Color color = C.green, VoidCallback? onTap})
GoalTrajectory(String label, String current, String target, String rate,
               double frac, Color color, {bool rateDown = true})
Observation(String headline, String detail,
            {String advice = '', VoidCallback? onTap})
Consistency(int have, int of, String label, Color color,
            {String unit = 'days'})
```

`Consistency` is **not a streak**. It reads "18 of 24 days" and never resets to
zero. Do not add one.

### Chrome

```dart
SubTabs(List<String> items, int index, ValueChanged<int> onTap,
        {Color color = C.green})
ScreenTitle(String title, {Widget? trailing})
Pill(String text, Color color, {IconData? icon})
BigButton(String label, {IconData? icon, Color color = C.green,
                         bool soft = false, VoidCallback? onTap})
NavBar(String title, {String sub = '', Widget? trailing,
                      VoidCallback? onBack})
```

---

## Painters — `charts.dart`, `paint_activity.dart`

Every one takes the data it draws. **None of them generate anything.** Hand a
painter an empty series and it draws nothing — fall through to a `StatusCard`.

Long series are reduced by `minMaxColumns(List<double>, double width,
double Function(double) y)` — at most two points per horizontal pixel, the
column min and max in time order, so a 30 000-point night costs the same as a
700-point one and single-sample spikes still survive. `maxColumns(d, cols)` is
the bar-chart equivalent. Both are exported; use them if you write a painter.

```dart
// charts.dart
LineChart(List<double> d, Color color,
          {bool fill = true, bool dots = false, double t = 1, Color? dotInk,
           AxisSpec? axis})
Bars(List<double> d, Color color,
     {int highlight = -1, double t = 1, AxisSpec? axis})
Ring(double v, Color color, Color track, {double stroke = 10, double t = 1})
MacroRing(double v, Color color, Color track)
Hypnogram(List<SleepStage> stages, P p, {double t = 1})  // awake/rem/light/deep
ZoneBar(List<double> z, P p)                         // five fractions
Actogram(List<List<double>?> days, Color color)      // per day, 24 slots; null = no record
HeatMap(List<List<double?>> weeks, Color color, Color track)  // null = no data
Spectrum(List<double> psd, {double split = .28, Color lf, Color hf})
NightStack(List<List<double>> series, List<Color> colors,
           {List<AxisSpec?>? axes})   // one per lane; lanes are different units

// paint_activity.dart — positions are normalised 0…1, origin top-left
RouteMap(List<Offset> pts, {List<double>? pace, Color slow, Color fast,
                            Color pinStart, Color pinEnd, Color pinInk,
                            bool pins = true})
MuscleMap(Map<String, double> load, Color color, Color base)
        // keys: MuscleMap.groups
Elevation(List<double> metres, Color color, {Color markerInk, AxisSpec? axis})
PowerCurve(List<double> watts, double max, Color color,
           {double targetLo = 0, double targetHi = 0, AxisSpec? axis})
           // axis supersedes max when given
LapBars(List<double> laps, Color color, Color track, {int done = -1})
BreathRing(double t, Color color)     // t is YOURS — never loop it internally
MovementMap(List<Offset> pts, Color color, Color line, {Rect court})
IntervalLadder(List<({double work, double rest})> rounds, Color work, Color rest)
PaceBar(double frac, Color color)     // a widget, not a painter
```

`t` on `LineChart`/`Bars`/`Ring`/`Hypnogram` is draw-in progress — feed it
`animate(context, …)` so reduced motion lands on a finished chart.

---

## Reading a chart — `AxisSpec` + `ChartFrame`

A painter draws a shape. **A shape is not information.** Every chart a user is
meant to read numbers off goes inside a `ChartFrame`, which supplies the four
things the shape doesn't have: the unit, the y scale in real numbers, the x
range, and a key for every colour.

```dart
class AxisSpec {
  final double min, max;
  final int ticks;                      // gridlines, INCLUDING both ends
  final String Function(double) format; // 56 -> '56';  450 -> '7h 30m'
  const AxisSpec({required this.min, required this.max,
                  this.ticks = 3, required this.format});

  double t(double v);                   // 0 at min, 1 at max, CLAMPED
  List<double> get tickValues;          // top-first

  /// Rounded out to steps a human would pick, and only to steps [format] can
  /// print — no gridline at 55.5 under `axisInt`. null for an empty series,
  /// which is the signal to render the frame's empty state.
  static AxisSpec? of(Iterable<double> d, {int ticks = 3,
      String Function(double) format = axisInt,
      double? floor, double? ceil, double? step});
}

String axisInt(double v);    // '56'          the default
String axisHm(double min);   // '7h 30m'      an axis measured in MINUTES
String axisFixed(double v);  // '36.5'        one decimal
```

```dart
ChartFrame({
  required String title,        // 'Resting heart rate'
  required String unit,         // 'bpm' — always rendered, no variant without it
  required Widget child,        // the painter
  double height = 120,
  AxisSpec? yAxis,              // gridlines + tick labels down the left
  List<String> xLabels = const [],       // first flush left, last flush right
  List<(String, Color)> legend = const [],
  String? footnote,             // 'Your usual range 52–64 bpm'
  Widget? empty,                // non-null MEANS NO DATA — `const NoData()`
  List<double?> series = const [],   // the SPOKEN version of the chart
  List<double> xMarks = const [],    // 0…1 breaks — NOT data, see rule 5
})

NoData({String message = 'No data yet'})
```

Pass `series:` as well as the painter's data. A picture has no screen-reader
form, so the frame turns the series into one sentence — latest, range,
direction — and marks itself `excludeSemantics`, because what it read out
before was the bare axis tick numbers and every header value twice.

Five rules:

1. **Pass the same `AxisSpec` to the frame and to the painter.** The frame
   prints `format` at each gridline; the painter maps values through `t`. Give
   it to only one of the two and the gridlines become decoration.
   ```dart
   final axis = AxisSpec.of(rhr, floor: 40)!;
   ChartFrame(
     title: 'Resting heart rate', unit: 'bpm', yAxis: axis,
     xLabels: ['30 Jul', '14 Aug', 'Today'],
     child: CustomPaint(size: Size.infinite,
                        painter: LineChart(rhr, C.blue, axis: axis)),
   );
   ```
   A painter with no `axis` auto-scales to its own min/max: correct for a
   sparkline, a lie under a labelled gridline, and the reason two charts side
   by side can silently use different scales.
2. **`xLabels` must describe the range actually drawn.** A hardcoded
   `['30 days ago', '15', 'Today']` under a seven-day window is worse than no
   labels. With three labels they mark the start, middle and end of the data.
3. **`xMarks` is provenance, never a measurement.** A mark says the days
   either side of it were not produced the same way — a release boundary, read
   off `getChart`'s `algo_breaks`. It draws dotted, in `p.ink3`, above the
   curve, and it does not take taps. **A mark without a `footnote` is a line
   nobody can read**: the footnote is the mark's only screen-reader form and
   the only thing that can say what it is. Keep the wording flat — a version
   change is provenance, not something that happened to the user.
4. **More than one colour means a `legend`.** Use the painters' own, never
   retyped: `Hypnogram.legend(p)`, `ZoneBar.legend(p)`, `Spectrum.legend`
   (instance), `IntervalLadder.legend` (instance). The swatch is the mark's
   *solved* colour, so the key and the plot can never disagree.

   The two painters that own a palette take `P` for exactly that reason: raw
   `C.sky` measures 1.67:1 on a white card, so the Light lane was invisible in
   light mode. Everything else takes its colour from the caller — pass
   `p.on(accent)`, never the pigment. `ZoneBar` also steps its bands up in
   height, because zone 4 against zone 5 is 1.34:1 *to each other* and a
   stacked bar has no lane position to separate them with.
5. **Empty is `empty:`, not an empty axis.** `empty: const NoData(message: '…')` keeps
   the title and the unit and drops the axis entirely. A whole metric with no
   value is still a `StatusCard` — `NoData` is the smaller case where the
   number exists but the series behind the picture doesn't.

Tick labels use `p.ink3` (solved to 4.5:1 on every surface) and **thin
themselves** rather than collide when the plot is too short for the requested
tick count at the user's text scale — the axis min/max never change, so the
curve keeps the scale that was pinned. At >1.3× text the unit moves under the
title instead of truncating it.

---

## The shell — `app_shell.dart`

```dart
AppShell({required Widget Function(BuildContext, ShellDomain) builder,
          ShellDomain initial = ShellDomain.home,
          void Function(ShellDomain)? onSelect})

enum ShellDomain { home, health, nutrition, workout, wellness }
  // .label · .icon · .accent
```

Tabs build lazily and are kept alive after first visit. **There is no sixth
tab.** Anything that feels like one is `SubTabs` inside the domain that owns
it.

### The catalogue — Health › Explore

Progressive disclosure hid the app from its own owner: 25 written `MetricSpec`s
existed and `MetricDetail` was constructed with **seven** keys anywhere in the
tree, so 16 finished drill-downs — title, unit, colour, method, citation, all
written — had no navigation edge at all.

`_catalogue` in `health_screen.dart` is the routing, and it is the one place a
metric becomes browsable. A row is `(spec key, metric_series key, one line)`;
its icon, colour and title come off the spec, never a second copy. **Add a
`MetricSpec` and add its catalogue row in the same commit** — a spec with no row
is a screen nobody can open, which is the bug this fixed.

Three rules the tab keeps:

- The number in the row is **how many days of history there are**, read from
  `LocalDb.metricSeriesCounts`. Not last night's value: a catalogue that showed
  readings would be a fifth copy of Overview.
- A metric with zero stored days is listed as not measured yet, **with no
  cause** — this screen reads a row count, and a count of zero never says why.
  No `fix:` either; nothing here can make a locked day derive.
- A capability this app does not produce gets **no row and no spec**. SpO2, ODI
  and anything apnea-shaped are refused; an index entry that existed to explain
  an absence is the thing the absent-forever rule forbids.

---

## Conventions that are not enforced by a test — follow them anyway

- Tabular figures (`F.n*`) on any number that can change.
- One `Recommendation` per screen at most; more than one is noise.
- `Observation` is for a clinician-worthy pattern. It never diagnoses and never
  names a cause.
- Copy in `StatusCard` is three parts: what is missing, why, what fixes it.
  "No data" alone is not acceptable copy.

---

## Banned strings — the respiratory surface

Landed before any respiratory screen exists, because this is the cheap moment.
Nothing in the UI prints these today and nothing may start.

| Banned | Why |
|---|---|
| `AHI` | an index we cannot compute |
| `apnea-hypopnea`, `apnoea` | same, spelled out |
| `mild` / `moderate` / `severe` | severity bands are an individual assignment |
| `you have` | the grammar of a diagnosis |

CVHR correlates with AHI at about r≈0.84, which sounds high and is nowhere near
enough to put one person in a severity category — at that correlation the CI on
a single person's AHI spans multiple clinical bands. The screen has no airflow,
no effort belt, no oximetry, no EEG for arousals, and no way to separate
obstructive from central.

**A lint cannot catch a card that quantifies without using the word.** "18
events per hour last night" contains none of the banned strings and is the same
claim. So the word list is the cheap half and copy review is the load-bearing
half; treat a grep pass as necessary, never sufficient.

Two more rules for anything that does ship on this surface:

- It terminates in "a clinician can test properly", never in a number.
- **It may not reassure.** An absent flag is not a negative result, and the copy
  says so on the same card — not in a footnote, not on a detail screen.

The same shape applies wherever detection meets a named condition: state that a
pattern is unlike the user's own baseline, never that they have the thing.
