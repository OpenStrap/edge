// The workouts activity heatmap — 13 weeks of daily workout calorie burn as a
// Monday-aligned day grid. It answers the one question the reverse-chron
// session feed structurally cannot: where the gaps are, and what the training
// rhythm actually looks like.
//
// This file's pure layer (below) is deliberately separable from the widget: day
// bucketing, the intensity scale and the streak are all calendar arithmetic,
// and calendar arithmetic is where this kind of grid goes wrong.

import 'dart:math' as math;

import 'package:flutter/material.dart';

// design.dart re-exports the theme tokens (Palette, AppColors, Sp, Motion) and
// AppText alongside the bento/controls widgets.
import '../design/design.dart';

/// The fill for a 0..4 intensity level, resolved against a SPECIFIC palette.
///
/// One construction serves both modes because `ink` flips with the palette:
/// blending it into `coralDeep` DEEPENS the top bucket on paper and BRIGHTENS
/// it on char, so "hotter" reads correctly either way without a second ramp.
///
/// Level 0 is `surfaceSunk` — a well, deliberately not on the coral ramp at
/// all, so a rest day never looks like a faint training day.
///
/// Guarded by the contrast tests in test/calorie_heatmap_test.dart, which
/// assert monotonic luminance and a minimum separation between every adjacent
/// pair in both palettes.
Color heatColorIn(Palette p, int level) {
  // The interpolation factors differ by mode, and they have to. On paper,
  // coralSoft is a pale tint sitting close to coral; on char it's a deep ember
  // fill sitting far below it — so the same t lands at a very different
  // perceptual position. Sharing one set of factors produces a ramp that
  // spends most of its range between levels 0 and 1 and almost none between 3
  // and 4 (measured 2.48:1 vs 1.29:1 on char). These are tuned per palette for
  // even spacing; the evenness test is what pins them.
  final dark = p.isDark;
  switch (level.clamp(0, 4)) {
    case 0:
      return p.surfaceSunk;
    case 1:
      return Color.lerp(p.coralSoft, p.coral, dark ? 0.25 : 0.38)!;
    case 2:
      return Color.lerp(p.coralSoft, p.coral, dark ? 0.62 : 0.70)!;
    case 3:
      return p.coral;
    default:
      return Color.lerp(p.coralDeep, p.ink, dark ? 0.30 : 0.18)!;
  }
}

/// The fill for a 0..4 intensity level in the CURRENT theme.
Color heatColor(int level) => heatColorIn(AppColors.active, level);

/// One cell of the grid — a single LOCAL calendar day.
class HeatDay {
  /// Local midnight for this day.
  final DateTime date;

  /// Calories burned across every session that STARTED on this day.
  final int kcal;

  /// How many sessions landed here (a day can hold more than one).
  final int sessions;

  /// Summed active minutes for the day.
  final int durationMin;

  /// This day hasn't happened yet (the tail of the current week). The grid
  /// draws nothing here — an empty well would read as a day you skipped.
  final bool isFuture;

  const HeatDay({
    required this.date,
    this.kcal = 0,
    this.sessions = 0,
    this.durationMin = 0,
    this.isFuture = false,
  });
}

/// The kcal value that saturates the ramp — the 90th percentile of days you
/// actually trained, never below [floor].
///
/// Relative rather than absolute on purpose. Fixed thresholds leave a beginner's
/// grid permanently cold and an endurance athlete's permanently maxed; scaling
/// to your own distribution makes the shading mean the same thing for both. The
/// percentile (not the max) keeps one exceptional session from flattening the
/// quarter, and the floor stops three easy walks from all reading as max effort.
int heatScale(List<HeatDay> days, {int floor = 250}) {
  final trained = [
    for (final d in days)
      if (d.kcal > 0) d.kcal,
  ]..sort();
  if (trained.isEmpty) return floor;
  // Nearest-rank percentile: the smallest value with >= 90% of samples at or
  // below it.
  final rank = ((0.9 * trained.length).ceil() - 1).clamp(0, trained.length - 1);
  final p90 = trained[rank];
  return p90 < floor ? floor : p90;
}

/// Bucket a day's burn into 0..4 against [scale] from [heatScale].
///
/// 0 is reserved for "didn't train" and is never reachable by a nonzero burn:
/// a rest day and a very light day must read differently or the grid stops
/// answering the question it exists for. 1..4 split the scale into quarters,
/// with everything past the p90 absorbed by the top bucket.
int heatLevel(int kcal, int scale) {
  if (kcal <= 0) return 0;
  if (scale <= 0) return 4; // degenerate scale — don't divide, just saturate
  final t = kcal / scale;
  if (t <= 0.25) return 1;
  if (t <= 0.50) return 2;
  if (t <= 0.75) return 3;
  return 4;
}

/// Consecutive trained days ending at [today] — or at yesterday, when today
/// hasn't been trained yet.
///
/// The yesterday allowance matters: a streak that resets at midnight would tell
/// you you'd broken it before you'd had a chance to train that day.
int currentStreak(List<HeatDay> days, {required DateTime today}) {
  final t = DateTime(today.year, today.month, today.day);
  final trained = {
    for (final d in days)
      if (d.kcal > 0) d.date,
  };

  // Anchor on today if it's trained, else on yesterday; if neither, no streak.
  final yesterday = DateTime(t.year, t.month, t.day - 1);
  var cursor = trained.contains(t)
      ? t
      : trained.contains(yesterday)
          ? yesterday
          : null;
  if (cursor == null) return 0;

  var n = 0;
  while (trained.contains(cursor)) {
    n++;
    cursor = DateTime(cursor!.year, cursor.month, cursor.day - 1);
  }
  return n;
}

/// A month name pinned to the grid column where that month starts.
class MonthLabel {
  /// Zero-based week column.
  final int column;

  /// Short month name, e.g. 'Mar'.
  final String text;

  const MonthLabel(this.column, this.text);
}

/// Where to write month names above the grid.
///
/// The board shows rhythm but not *when*: a three-week gap is meaningless if
/// you can't tell whether it was March or May. A label is emitted for the first
/// column of each month — keyed off each column's Monday, so a month is named
/// once, at the week it takes over, and never repeated.
List<MonthLabel> monthLabels(List<HeatDay> days) {
  final out = <MonthLabel>[];
  int? lastMonth;
  for (var col = 0; col * 7 < days.length; col++) {
    final monday = days[col * 7].date;
    if (monday.month != lastMonth) {
      out.add(MonthLabel(col, _mon[monday.month - 1]));
      lastMonth = monday.month;
    }
  }
  return out;
}

/// Comma-group an integer: 22140 -> "22,140".
///
/// Local rather than a package: `intl` isn't a dependency here, and every other
/// stat in the app is small enough to render as a bare int. A 13-week calorie
/// total is the first five-figure number on a card, and an ungrouped run of
/// digits is measurably harder to read at a glance.
String groupThousands(int n) {
  final neg = n < 0;
  final digits = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    // Comma before every group of three counted from the RIGHT — i.e. wherever
    // the remaining digit count is a positive multiple of three.
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return neg ? '-$buf' : buf.toString();
}

/// Narrow a `getSessions()` result to the sessions the grid should shade.
///
/// That call deliberately merges unconfirmed auto-detected bouts in with saved
/// ones, which is right for the suggestions flow and wrong here: shading a
/// detection would put a day on the grid that the feed and the training summary
/// both omit, while the "Suggested workouts" card for it is still sitting above
/// asking to be confirmed. Live sessions are held back for a different reason —
/// their calorie tally isn't final, so they'd shade in as an artificially cold
/// day and then jump when the session ends.
///
/// The test is `status`, NOT `source`. `source: 'auto'` records that a workout
/// ORIGINATED in the detector, and that stays true once the user confirms it:
/// the row `_logDetectedSession` saves carries `source: 'auto'` with
/// `status: 'done'`, and the feed renders it with an `auto` tag. Filtering on
/// source therefore drops real logged workouts, producing the very
/// disagreement this filter exists to prevent, only inverted — the day sits in
/// the feed and in the training summary but reads as a rest day on the grid.
/// Only the synthetic shape built for an UNCONFIRMED bout carries
/// `status: 'detected'`, so status alone is the complete test.
List<Map<String, dynamic>> loggedForHeatmap(
        List<Map<String, dynamic>> sessions) =>
    [
      for (final w in sessions)
        if (w['status'] != 'detected' && w['status'] != 'live') w,
    ];

/// Build the [weeks]x7 grid ending on the Sunday that closes [today]'s week.
///
/// Days are stepped via `DateTime(y, m, d + i)` rather than
/// `add(Duration(days: 1))` on purpose: Duration arithmetic is absolute, so
/// across a DST transition it lands at 23:00 or 01:00 of the neighbouring day
/// and the grid silently repeats or skips a date. The constructor normalises
/// overflowing day numbers and always yields local midnight.
List<HeatDay> buildHeatDays(
  List<Map<String, dynamic>> workouts, {
  required DateTime today,
  int weeks = 13,
}) {
  final t = DateTime(today.year, today.month, today.day);
  // weekday: Mon=1 .. Sun=7, so (7 - weekday) reaches this week's Sunday.
  final end = DateTime(t.year, t.month, t.day + (7 - t.weekday));
  final start = DateTime(end.year, end.month, end.day - (weeks * 7 - 1));

  // Tally by local day key first, so multiple sessions on one date collapse
  // into a single cell rather than the last one winning.
  final kcal = <DateTime, int>{};
  final count = <DateTime, int>{};
  final mins = <DateTime, int>{};

  for (final w in workouts) {
    final startTs = (w['start_ts'] as num?)?.toInt();
    if (startTs == null || startTs == 0) continue;
    final local =
        DateTime.fromMillisecondsSinceEpoch(startTs * 1000).toLocal();
    final key = DateTime(local.year, local.month, local.day);
    kcal[key] = (kcal[key] ?? 0) + ((w['calories'] as num?)?.round() ?? 0);
    count[key] = (count[key] ?? 0) + 1;
    mins[key] = (mins[key] ?? 0) + ((w['duration_min'] as num?)?.round() ?? 0);
  }

  final out = <HeatDay>[];
  for (var i = 0; i < weeks * 7; i++) {
    final d = DateTime(start.year, start.month, start.day + i);
    out.add(HeatDay(
      date: d,
      kcal: kcal[d] ?? 0,
      sessions: count[d] ?? 0,
      durationMin: mins[d] ?? 0,
      isFuture: d.isAfter(t),
    ));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget
// ─────────────────────────────────────────────────────────────────────────────

/// Widest a 3-letter month label gets at 9px — reserved so a label pinned
/// to the right edge stays fully on the card.
const double _monthLabelWidth = 24.0;

const _dow = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _mon = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _readoutDate(DateTime d) =>
    '${_dow[d.weekday - 1]} ${d.day} ${_mon[d.month - 1]}';

String _cellKey(DateTime d) => 'heat-${d.year.toString().padLeft(4, '0')}'
    '-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// The activity heatmap tile — a Monday-aligned day grid of workout calorie
/// burn, with a header that swaps between the window total and a tapped day.
///
/// Takes an already-built [days] grid rather than raw workouts so the whole
/// calendar layer stays independently testable.
class CalorieHeatmapCard extends StatefulWidget {
  final List<HeatDay> days;
  final DateTime today;

  const CalorieHeatmapCard({
    super.key,
    required this.days,
    required this.today,
  });

  @override
  State<CalorieHeatmapCard> createState() => _CalorieHeatmapCardState();
}

class _CalorieHeatmapCardState extends State<CalorieHeatmapCard>
    with TickerProviderStateMixin {
  DateTime? _selected;

  /// Staggered reveal — runs once, then holds.
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  /// The peak day's ember breath. Repeats for as long as the card is mounted,
  /// so it is created ONLY when motion is allowed — see [_syncPulse].
  AnimationController? _pulse;
  bool _startedReveal = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!_startedReveal) {
      _startedReveal = true;
      reduce ? _reveal.value = 1.0 : _reveal.forward();
    }
    _syncPulse(reduce);
  }

  @override
  void didUpdateWidget(covariant CalorieHeatmapCard old) {
    super.didUpdateWidget(old);
    // A refresh can slide the window past the selected day. build() already
    // falls back to the summary, but the selection has to be released too or
    // the peak pulse stays suppressed forever waiting on a day that is gone.
    if (_selected != null &&
        !widget.days.any((d) => d.date == _selected)) {
      _selected = null;
    }
    _syncPulse(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
  }

  void _syncPulse(bool reduce) {
    // Silent while a cell is selected: the selection ring is the thing to look
    // at then, and two competing attractors read as noise.
    final wants = !reduce && _selected == null && _peak != null;
    if (wants && _pulse == null) {
      _pulse = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      )..repeat(reverse: true);
    } else if (!wants && _pulse != null) {
      _pulse!.dispose();
      _pulse = null;
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    _pulse?.dispose();
    super.dispose();
  }

  List<HeatDay> get _drawn =>
      [for (final d in widget.days) if (!d.isFuture) d];

  /// The single hottest day in the window, if anything was logged.
  HeatDay? get _peak {
    HeatDay? best;
    for (final d in _drawn) {
      if (d.kcal > 0 && (best == null || d.kcal > best.kcal)) best = d;
    }
    return best;
  }

  void _toggle(HeatDay d) {
    setState(() {
      _selected = _selected == d.date ? null : d.date;
      _syncPulse(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final drawn = _drawn;
    final total = drawn.fold<int>(0, (a, d) => a + d.kcal);
    final sessions = drawn.fold<int>(0, (a, d) => a + d.sessions);
    final streak = currentStreak(widget.days, today: widget.today);
    final scale = heatScale(widget.days);
    final peak = _peak;
    // Derived, not hardcoded: `days` is a constructor argument, so a caller
    // that builds a different span must not be described as 13 weeks. Pluralised
    // because the whole point is serving spans other than 13 — "1 weeks" would
    // be the derivation announcing itself.
    final weeks = (widget.days.length / 7).ceil();
    final weekLabel = weeks == 1 ? '1 week' : '$weeks weeks';

    // Resolved by lookup rather than firstWhere: the window slides forward as
    // days pass and on a refresh that crosses midnight the selected date can
    // fall off the back of the board. Falling back to the summary is right —
    // a phantom readout for a day no longer shown would be worse.
    HeatDay? sel;
    if (_selected != null) {
      for (final d in widget.days) {
        if (d.date == _selected) {
          sel = d;
          break;
        }
      }
    }

    return BentoTile(
      tone: BentoTone.paper,
      accent: DomainAccent.strain,
      padding: const EdgeInsets.all(Sp.x4),
      child: Builder(builder: (context) {
        final tone = ToneScope.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: TileHeader('Activity · $weekLabel')),
                InfoDot(
                  title: 'Activity heatmap',
                  body: 'Every day of the last $weekLabel, shaded by the '
                      'calories you burned in logged workouts. Empty squares '
                      'are days you did not train.',
                  methodNote: 'Shade is scaled to your own 90th-percentile '
                      'day (currently $scale kcal), so it means the same '
                      'thing whatever your usual session looks like.',
                ),
              ],
            ),
            const SizedBox(height: Sp.x2),
            AnimatedSwitcher(
              duration: Motion.fast,
              child: sel == null
                  ? _summary(tone, total, sessions, streak)
                  : _dayReadout(tone, sel),
            ),
            const SizedBox(height: Sp.x4),
            _HeatGrid(
              days: widget.days,
              today: widget.today,
              scale: scale,
              selected: _selected,
              peak: peak?.date,
              reveal: _reveal,
              pulse: _pulse,
              onTap: _toggle,
            ),
            const SizedBox(height: Sp.x3),
            _Legend(tone: tone),
          ],
        );
      }),
    );
  }

  Widget _summary(ToneColors tone, int total, int sessions, int streak) =>
      Column(
        key: const ValueKey('summary'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bigValue(groupThousands(total), tone),
          Text(
            '$sessions sessions'
            '${streak >= 2 ? ' · $streak-day streak' : ''}',
            style: AppText.caption.copyWith(color: tone.fgMuted),
          ),
        ],
      );

  Widget _dayReadout(ToneColors tone, HeatDay d) => Column(
        key: ValueKey('day-${d.date}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bigValue(d.kcal > 0 ? groupThousands(d.kcal) : '—', tone),
          Text(
            d.sessions == 0
                ? '${_readoutDate(d.date)} · No workout'
                : '${_readoutDate(d.date)} · '
                    '${d.sessions > 1 ? '${d.sessions} sessions · ' : ''}'
                    '${d.durationMin} min',
            style: AppText.caption.copyWith(color: tone.fgMuted),
          ),
        ],
      );

  Widget _bigValue(String v, ToneColors tone) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(v, style: AppText.metric.copyWith(color: tone.fg)),
          const SizedBox(width: Sp.x2),
          Text('kcal', style: AppText.label.copyWith(color: tone.fgMuted)),
        ],
      );
}

/// The 13x7 board. Weeks are columns (oldest left), weekdays are rows.
class _HeatGrid extends StatelessWidget {
  final List<HeatDay> days;
  final DateTime today;
  final int scale;
  final DateTime? selected;
  final DateTime? peak;
  final Animation<double> reveal;
  final Animation<double>? pulse;
  final void Function(HeatDay) onTap;

  const _HeatGrid({
    required this.days,
    required this.today,
    required this.scale,
    required this.selected,
    required this.peak,
    required this.reveal,
    required this.pulse,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final weeks = (days.length / 7).ceil();
    final t = DateTime(today.year, today.month, today.day);

    return LayoutBuilder(builder: (context, c) {
      // Day-label gutter + inter-cell gaps come out of the available width
      // first; whatever is left divides evenly across the week columns.
      const gutter = 22.0, gap = 4.0;
      final cell =
          ((c.maxWidth - gutter - gap * (weeks - 1)) / weeks).clamp(9.0, 26.0);
      final radius = cell * 0.3;

      final months = monthLabels(days);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Month names, pinned to the left edge of the column each month
          // starts in. A Stack rather than a Row because the labels are sparse
          // and positional — they must line up with a specific week, not
          // distribute across the row.
          SizedBox(
            width: c.maxWidth,
            height: 13,
            child: Stack(
              children: [
                for (final m in months)
                  Positioned(
                    // Clamped, not dropped. A month that starts in the last
                    // column would otherwise run off the card — but skipping it
                    // leaves the weeks nearest today as the only unnamed
                    // stretch, which is the opposite of useful. Pinning it to
                    // the right edge keeps every month named.
                    left: math.min(
                      gutter + m.column * (cell + gap),
                      (c.maxWidth - _monthLabelWidth).clamp(0.0, c.maxWidth),
                    ),
                    top: 0,
                    child: Text(
                      m.text,
                      style: AppText.captionMuted
                          .copyWith(fontSize: 9, height: 1.2),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Sp.x1),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: gutter,
                child: Column(
              children: [
                for (var row = 0; row < 7; row++)
                  SizedBox(
                    height: cell + gap,
                    // Label alternate rows only (M/W/F/S) — seven stacked
                    // labels at this cell size is denser than the grid itself.
                    child: row.isOdd
                        ? const SizedBox.shrink()
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _dow[row][0],
                              style: AppText.captionMuted
                                  .copyWith(fontSize: 9, height: 1),
                            ),
                          ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    for (var row = 0; row < 7; row++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: gap),
                        child: Row(
                          children: [
                            // weeks rounds UP, so a caller passing a part-week
                            // list would index past the end. buildHeatDays
                            // always emits whole weeks, but the widget takes
                            // any List<HeatDay>.
                            for (var col = 0; col < weeks; col++)
                              if (col * 7 + row < days.length)
                                Padding(
                                  padding: EdgeInsets.only(
                                      right: col == weeks - 1 ? 0 : gap),
                                  child: _cell(
                                    days[col * 7 + row],
                                    cell.toDouble(),
                                    radius.toDouble(),
                                    col,
                                    row,
                                    t,
                                  ),
                                ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    });
  }

  Widget _cell(
      HeatDay d, double size, double radius, int col, int row, DateTime t) {
    // A day that hasn't happened leaves a hole, not an empty well — an empty
    // well would read as a day you skipped.
    if (d.isFuture) return SizedBox(width: size, height: size);

    final isSelected = selected == d.date;
    final isToday = d.date == t;
    final isPeak = peak == d.date;

    // Diagonal reveal: later weeks and later weekdays start fractionally
    // later, so the board lights up as one wave rather than all at once.
    final delay = (col * 0.045 + row * 0.012).clamp(0.0, 0.6);

    // Only the peak cell reads pulse.value, and the pulse repeats for as long
    // as the card is mounted. Merging it into all 91 cells would rebuild the
    // entire board every frame, forever, to breathe one square — each rebuild
    // reallocating the Opacity/Transform/AnimatedScale/Container chain. `reveal`
    // stops notifying once it settles, so subscribing the rest to it alone
    // leaves them genuinely idle after the intro.
    final animation =
        isPeak && pulse != null ? Listenable.merge([reveal, pulse]) : reveal;

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final p = ((reveal.value - delay) / 0.35).clamp(0.0, 1.0);
        final eased = Curves.easeOutCubic.transform(p);
        final glow = isPeak && pulse != null ? pulse!.value : 0.0;

        return Opacity(
          opacity: eased,
          child: Transform.scale(
            scale: 0.55 + 0.45 * eased,
            child: GestureDetector(
              key: ValueKey(_cellKey(d.date)),
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(d),
              child: Semantics(
                button: true,
                selected: isSelected,
                // Colour IS the content here, so a screen reader gets nothing
                // from the grid without this. Read the day and its burn rather
                // than the intensity level — "level 3 of 4" describes the
                // rendering, not the training.
                label: d.sessions == 0
                    ? '${_readoutDate(d.date)}, no workout'
                    : '${_readoutDate(d.date)}, ${d.kcal} kcal, '
                        '${d.sessions} '
                        '${d.sessions == 1 ? 'session' : 'sessions'}, '
                        '${d.durationMin} minutes',
                child: AnimatedScale(
                  scale: isSelected ? 1.14 : 1.0,
                  duration: Motion.springy.d,
                  curve: Motion.springy.c,
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      color: heatColor(heatLevel(d.kcal, scale)),
                      borderRadius: BorderRadius.circular(radius),
                      border: isSelected
                          ? Border.all(color: AppColors.ink, width: 2)
                          : isToday
                              ? Border.all(
                                  color: AppColors.ink.withValues(alpha: 0.9),
                                  width: 1.4)
                              : null,
                      boxShadow: glow > 0
                          ? [
                              BoxShadow(
                                color: AppColors.coral
                                    .withValues(alpha: 0.10 + 0.28 * glow),
                                blurRadius: 4 + 10 * glow,
                                spreadRadius: 1 + 2 * glow,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Less -> More swatches, plus the unit.
class _Legend extends StatelessWidget {
  final ToneColors tone;
  const _Legend({required this.tone});

  @override
  Widget build(BuildContext context) {
    final style = AppText.caption.copyWith(fontSize: 10, color: tone.fgMuted);
    return Row(
      children: [
        Text('Less', style: style),
        const SizedBox(width: Sp.x2),
        for (var l = 0; l <= 4; l++)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: heatColor(l),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        const SizedBox(width: Sp.x1),
        Text('More', style: style),
        const Spacer(),
        Text('kcal per day', style: style),
      ],
    );
  }
}
