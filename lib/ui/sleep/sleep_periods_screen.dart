// Sleep periods (v2) — every sleep of the day, one bento card each, on the NEW
// design language. A nap is not a special case: it's just a shorter sleep.
// Slept once → one card; napped twice → three cards. The day total is an ink
// hero tile; every period card carries its own mini hypnogram + StageBars on
// the ONE DomainAccent stage palette. Backed by /day/v2/sleep.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../compute/nap_edits.dart';
import '../../data/db.dart';
import '../design/design.dart';

class SleepPeriodsScreen extends StatefulWidget {
  final String date; // 'YYYY-MM-DD'
  const SleepPeriodsScreen({super.key, required this.date});

  @override
  State<SleepPeriodsScreen> createState() => _SleepPeriodsScreenState();
}

enum _Phase { loading, ready, empty, error }

class _SleepPeriodsScreenState extends State<SleepPeriodsScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, dynamic> _data = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().repo;
    if (api == null) {
      setState(() {
        _phase = _Phase.error;
        _error = 'Not signed in.';
      });
      return;
    }
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final res = await api.getDaySleepV2(widget.date);
      if (!mounted) return;
      setState(() {
        _data = res;
        _phase = _periods.isEmpty ? _Phase.empty : _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  // ── parsing ──────────────────────────────────────────────────────────────
  num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
  List<Map<String, dynamic>> get _periods {
    final p = _data['periods'];
    if (p is List) {
      return p.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  int get _needMin => (_num(_data['need_min'])?.toInt()) ?? 480;

  /// Null when any listed period's asleep minutes are unknown — the total is
  /// then unknown too, not zero.
  int? get _totalAsleep => _num(_data['total_asleep_min'])?.toInt();
  bool get _beta => _data['stages_beta'] == true;

  /// Log a nap the detector missed. Two time pickers rather than a duration,
  /// because people remember when they lay down, not how long they were out.
  Future<void> _addNap() async {
    final start = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 14, minute: 0),
      helpText: 'Nap started',
    );
    if (start == null || !mounted) return;
    final end = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: (start.hour + 1) % 24,
        minute: start.minute,
      ),
      helpText: 'Nap ended',
    );
    if (end == null || !mounted) return;

    final day = DateTime.parse(widget.date);
    final startTs =
        DateTime(day.year, day.month, day.day, start.hour, start.minute)
            .millisecondsSinceEpoch ~/
        1000;
    var endTs =
        DateTime(day.year, day.month, day.day, end.hour, end.minute)
            .millisecondsSinceEpoch ~/
        1000;
    // An end before the start means it ran past midnight.
    if (endTs <= startTs) endTs += 24 * 3600;

    if (!manualNapWindowIsValid(startTs, endTs)) {
      _say(
        'A nap runs from ${kMinManualNapSec ~/ 60} minutes to '
        '${kMaxManualNapSec ~/ 3600} hours. Longer than that belongs in your '
        'main sleep.',
      );
      return;
    }
    if (napOverlapsExisting(startTs, endTs, _sleepWindows)) {
      // Silently merging two overlapping entries would inflate the day's total
      // while hiding the mistake.
      _say('That overlaps a sleep already on this day.');
      return;
    }

    await LocalDb.putNapEdit(
      dayId: widget.date,
      startTs: startTs,
      endTs: endTs,
      source: 'manual',
    );
    await _rederive(expectStart: startTs);
  }

  /// Remove a period. A detected nap is SUPPRESSED (its window is remembered,
  /// so it stays gone when the detector runs again); a logged one is deleted
  /// outright.
  Future<void> _removeNap(Map<String, dynamic> period) async {
    final start = (period['onset_ts'] as num?)?.toInt();
    final end = (period['wake_ts'] as num?)?.toInt();
    if (start == null || end == null) return;
    if (period['source'] == 'manual') {
      await LocalDb.deleteNapEdit(widget.date, start);
    } else {
      await LocalDb.putNapEdit(
        dayId: widget.date,
        startTs: start,
        endTs: end,
        source: 'rejected',
      );
    }
    await _rederive();
  }

  /// Every sleep already on the day, MAIN INCLUDED.
  ///
  /// The main sleep has to be in here or a nap can be logged inside it — main
  /// 23:00–07:00 and a logged 06:00–07:00 would both be accepted, and that
  /// hour would be counted once in the night's TST and again in nap minutes.
  List<Map<String, dynamic>> get _sleepWindows => [
    for (final p in _periods)
      if (p['onset_ts'] != null && p['wake_ts'] != null)
        {'start': p['onset_ts'], 'end': p['wake_ts']},
  ];

  Future<void> _rederive({int? expectStart}) async {
    // Both callers reach here after an awaited database write, so the screen
    // can already be gone — a Provider lookup on a disposed context throws.
    if (!mounted) return;
    // The edit only shows up once the day is re-derived — nap minutes feed
    // sleep need and sleep debt, so this is a recompute, not a redraw.
    await context.read<AppState>().reanalyzeForNapEdit();
    if (!mounted) return;
    await _load();
    if (!mounted || expectStart == null) return;
    final landed = _periods.any(
      (p) => (p['onset_ts'] as num?)?.toInt() == expectStart,
    );
    if (!landed) {
      // A day whose raw data has aged out cannot be re-derived, and a derive
      // already in flight is skipped rather than queued. Either way the row is
      // saved and will apply next time that day is rebuilt — saying nothing
      // would look like the tap did nothing at all.
      _say('Saved. It will show once this day is rebuilt.');
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Sleep periods',
      subtitle: 'Every sleep, naps included',
      actions: [
        Semantics(
          button: true,
          label: 'Log a nap',
          child: Pressable(
            pressedScale: 0.94,
            onTap: _addNap,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x4,
                vertical: Sp.x3,
              ),
              decoration: BoxDecoration(
                color: AppColors.tonalFill(AppColors.accent),
                borderRadius: BorderRadius.circular(R.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 18, color: AppColors.accent),
                  const SizedBox(width: Sp.x1),
                  Text(
                    'Nap',
                    style: AppText.label.copyWith(color: AppColors.accent),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.accent,
        child: ListView(
          // AlwaysScrollable so pull-to-refresh fires even when content is
          // short (loading / empty / error).
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding:
              const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x10),
          children: [
            if (_phase == _Phase.loading) ...[
              Skeleton.hero(),
              const SizedBox(height: Sp.x3),
              Skeleton.tileRow(rows: 2),
            ] else if (_phase == _Phase.empty)
              StateCard(
                icon: OsIcon.bedtime,
                title: 'No sleep detected',
                message:
                    'Wear your strap overnight (and through any naps) and sync '
                    'to see each sleep here. You can also log a nap yourself.',
                actionLabel: 'Log a nap',
                onAction: _addNap,
              )
            else if (_phase == _Phase.error)
              StateCard(
                icon: OsIcon.sync,
                title: "Couldn't load sleep",
                message: _error ?? 'Please try again.',
                actionLabel: 'Try again',
                onAction: _load,
              )
            else
              ...dsStaggered([
                _summary(),
                const SizedBox(height: Sp.x3),
                for (final p in _periods) ...[
                  _periodCard(p),
                  const SizedBox(height: Sp.x3),
                ],
              ]),
          ],
        ),
      ),
    );
  }

  // Day hero: total asleep across all periods vs need — the board's ink tile.
  Widget _summary() {
    final n = _periods.length;
    final total = _totalAsleep;
    final t = (total == null || _needMin <= 0)
        ? double.nan
        : (total / _needMin).clamp(0.0, 1.0).toDouble();
    return BentoTile(
      tone: BentoTone.ink,
      accent: DomainAccent.sleep,
      padding: const EdgeInsets.all(Sp.x5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const TileHeader('Total sleep'),
                const SizedBox(height: Sp.x2),
                BigStat(
                  value: total == null ? '—' : _hm(total),
                  size: BigStatSize.xl,
                  caption: 'need ${_hm(_needMin)} · $n sleep${n == 1 ? '' : 's'}',
                ),
              ],
            ),
          ),
          const SizedBox(width: Sp.x3),
          ArcGauge(
            value: t,
            color: DomainAccent.sleep,
            size: 96,
            stroke: 10,
            sweepFraction: 0.75,
            endDot: !t.isNaN,
            valueText: t.isNaN ? '—' : '${(t * 100).round()}%',
            label: 'of need',
          ),
        ],
      ),
    );
  }

  Widget _periodCard(Map<String, dynamic> p) {
    final isMain = p['is_main'] == true;
    final onset = _num(p['onset_ts'])?.toInt();
    final wake = _num(p['wake_ts'])?.toInt();
    // Null, NOT 0. A period whose asleep minutes we don't have renders "—";
    // defaulting to 0 printed a confident "0m" on every real nap for as long
    // as the producer and this screen disagreed about the key name.
    final dur = _num(p['duration_min'])?.toInt();
    final eff = _num(p['efficiency'])?.toDouble();
    final conf = _num(p['confidence'])?.toDouble();
    final stages = (p['stages'] is Map)
        ? (p['stages'] as Map).cast<String, dynamic>()
        : null;
    final hypno = hypnoSegmentsFromPoints(
        (p['hypnogram'] is List) ? p['hypnogram'] as List : const []);

    return BentoTile(
      tone: isMain ? BentoTone.paper : BentoTone.soft,
      accent: DomainAccent.sleep,
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TileHeader(
                  isMain
                      ? 'Main sleep'
                      : (p['source'] == 'manual' ? 'Nap · logged' : 'Nap'),
                  icon: isMain ? OsIcon.sleep : OsIcon.bedtime,
                  trailing: _beta ? const Tag('est') : null,
                ),
              ),
              // Only naps can be removed. The main sleep window is edited on
              // the sleep detail screen, where the override lives — deleting
              // it here would leave the day with no sleep at all rather than
              // with a corrected one.
              if (!isMain)
                Semantics(
                  button: true,
                  label: 'Remove this nap',
                  child: Pressable(
                    pressedScale: 0.9,
                    onTap: () => _removeNap(p),
                    child: Padding(
                      padding: const EdgeInsets.only(right: Sp.x2),
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ),
                ),
              // No dot at all when confidence is unknown — a ConfDot(0) is a
              // red "we are sure this is bad" dot, which is a claim.
              if (conf != null) ConfDot(conf),
              InfoDot(
                title: isMain ? 'Main sleep' : 'Nap',
                body: isMain
                    ? 'Stages are a wrist estimate from heart rate + motion '
                        '(no EEG).'
                    : 'Detected from wrist stillness plus a drop in heart '
                        'rate against your awake daytime baseline. Time '
                        'asleep excludes brief wake-ups. No stage breakdown: '
                        'a short nap has no complete sleep cycle, and daytime '
                        'heart rate is too intermittent to split one. The dot '
                        'shows detection confidence.',
              ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: BigStat(
                  value: dur == null ? '—' : _hm(dur),
                  caption: (onset != null && wake != null)
                      ? '${_clock(onset)} – ${_clock(wake)}'
                      : null,
                ),
              ),
              if (eff != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: StatusChip(
                    '${(eff * 100).round()}% efficient',
                    tone: ChipTone.positive,
                  ),
                ),
            ],
          ),
          if (hypno.isNotEmpty) ...[
            const SizedBox(height: Sp.x4),
            // Per-period stepped hypnogram — same component + palette as the
            // main Sleep screen, compact and unlabelled.
            Hypnogram(hypno, height: 56, labels: false),
          ],
          if (stages != null) ...[
            const SizedBox(height: Sp.x3),
            _stageBars(stages),
          ],
        ],
      ),
    );
  }

  /// StageBars from the period's stage minutes. Falls back to the legacy
  /// combined nrem_min (rendered as Light) when the light/deep split is absent.
  Widget _stageBars(Map<String, dynamic> s) {
    var light = (_num(s['light_min']) ?? 0).round();
    final deep = (_num(s['deep_min']) ?? 0).round();
    final rem = (_num(s['rem_min']) ?? 0).round();
    if (light <= 0 && deep <= 0) light = (_num(s['nrem_min']) ?? 0).round();
    if (light + deep + rem <= 0) return const SizedBox.shrink();
    return StageBars(
      lightMin: light,
      deepMin: deep,
      remMin: rem,
      height: 10,
    );
  }

  String _hm(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }

  String _clock(int epochSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    final h24 = d.hour;
    final ampm = h24 < 12 ? 'AM' : 'PM';
    var h = h24 % 12;
    if (h == 0) h = 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} $ampm';
  }
}
