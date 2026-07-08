// Records, streaks, and resting-HR trend over time — on the bento design
// language: a medal for the headline PR, per-domain BigStat tiles for the
// rest, streak flames, and a real resting-HR sparkline. Backed by
// getRecords() (+ getChart('resting_hr') for the trend line).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/payloads.dart';
import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key});
  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

enum _Phase { loading, ready, empty, error }

class _RecordsScreenState extends State<RecordsScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  RecordsData _r = RecordsData.fromJson(null);
  List<double?> _rhrSpark = const [];

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
        _error = 'Pair your strap first.';
      });
      return;
    }
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final res = await api.getRecords();
      // Daily resting-HR points for the trend sparkline (the drift payload
      // itself only carries then/now aggregates).
      List<double?> spark = const [];
      try {
        final chart = await api.getChart('resting_hr');
        final pts = (chart['points'] as List?) ?? const [];
        final vals = <double?>[
          for (final p in pts)
            if (p is Map && p['v'] is num) (p['v'] as num).toDouble(),
        ];
        // The drift compares ~the last 37 days — show the same window.
        spark = vals.length > 37 ? vals.sublist(vals.length - 37) : vals;
      } catch (_) {/* sparkline is an enrichment */}
      if (!mounted) return;
      final r = RecordsData.fromJson(res);
      setState(() {
        _r = r;
        _rhrSpark = spark;
        _phase = r.isEmpty ? _Phase.empty : _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      // Illustrated headline — the trophy art leads the title.
      titleWidget: Row(
        children: [
          const OsAppIcon(OsIcon.records, size: 36),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Records',
                    style: AppText.h1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text('Your body, over time', style: AppText.captionMuted),
              ],
            ),
          ),
        ],
      ),
      children: [
        if (_phase == _Phase.loading) ...[
          Skeleton.hero(),
          const SizedBox(height: Sp.x4),
          Skeleton.tileRow(rows: 2),
          const SizedBox(height: Sp.x4),
          Skeleton.chart(),
        ] else if (_phase == _Phase.empty)
          StateCard(
            icon: OsIcon.records,
            title: 'Nothing logged yet',
            message:
                'Wear and sync for a few days. Your records, streaks and '
                'trends build up here over time.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else if (_phase == _Phase.error)
          StateCard(
            icon: OsIcon.sync,
            title: "Couldn't load your records",
            message: _error ?? 'Please try again.',
            actionLabel: 'Try again',
            onAction: _load,
          )
        else
          RecordsContent(r: _r, rhrSpark: _rhrSpark),
      ],
    );
  }
}

/// Pure presentation for the records board (render-testable without a repo).
class RecordsContent extends StatelessWidget {
  final RecordsData r;

  /// Daily resting-HR values (oldest→newest) for the trend sparkline.
  final List<double?> rhrSpark;

  const RecordsContent({super.key, required this.r, this.rhrSpark = const []});

  // ── formatting ────────────────────────────────────────────────────────────

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _prettyDate(String iso) {
    final p = iso.split('-');
    if (p.length != 3) return iso;
    final mo = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (mo == null || d == null || mo < 1 || mo > 12) return iso;
    return '${_months[mo - 1]} $d';
  }

  static String _hm(num m) {
    final mm = m.round();
    final h = mm ~/ 60, rest = mm % 60;
    if (h == 0) return '${rest}m';
    if (rest == 0) return '${h}h';
    return '${h}h ${rest}m';
  }

  static String _grouped(num v) {
    final s = v.round().toString();
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(' ');
      out.write(s[i]);
    }
    return out.toString();
  }

  static String _titleCase(String s) => s.isEmpty
      ? s
      : s
          .split(RegExp(r'[ _/]'))
          .where((w) => w.isNotEmpty)
          .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');

  /// (value, unit) split so BigStat can superscript the unit.
  static (String, String?) _fmt(String key, num v) => switch (key) {
        'lowest_rhr' || 'lowest_sleeping_hr' => ('${v.round()}', 'bpm'),
        'top_strain' || 'top_workout' => (v.toStringAsFixed(1), null),
        'longest_sleep' => (_hm(v), null),
        'best_efficiency' => ('${(v * 100).round()}', '%'),
        'most_steps' => (_grouped(v), null),
        'top_readiness' => ('${v.round()}', '/100'),
        _ => (v.toString(), null),
      };

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final medal = _medalDef();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: dsStaggered([
        _summaryTile(),
        const SizedBox(height: Sp.x3),
        if (medal != null) ...[medal, const SizedBox(height: Sp.x3)],
        _recordsBento(medalKey: _medalKey()),
        const SizedBox(height: Sp.x3),
        _driftTile(),
        ..._streakSection(),
      ]),
    );
  }

  // ── all-time tallies: one inverted headline tile ─────────────────────────

  Widget _summaryTile() {
    Widget cell(String v, String label) => Expanded(
          child: BigStat(value: v, label: label, size: BigStatSize.md),
        );
    return BentoTile(
      tone: BentoTone.ink,
      child: Row(
        children: [
          cell('${r.daysTracked}', 'Days'),
          cell('${r.nightsTracked}', 'Nights'),
          cell('${r.workoutsTracked}', 'Workouts'),
        ],
      ),
    );
  }

  // ── headline PR as an engraved medal ─────────────────────────────────────

  /// Priority for which record gets the medal treatment.
  static const _medalPriority = ['top_workout', 'top_strain', 'lowest_rhr'];

  String? _medalKey() {
    for (final k in _medalPriority) {
      if (r.record(k) != null) return k;
    }
    return null;
  }

  Widget? _medalDef() {
    final key = _medalKey();
    if (key == null) return null;
    final rec = r.record(key)!;
    final (value, unit) = _fmt(key, rec.value);
    final title = switch (key) {
      'top_workout' => 'Top workout strain — $value',
      'top_strain' => 'Biggest day strain — $value',
      _ => 'Lowest resting HR — $value ${unit ?? ''}'.trim(),
    };
    final type = rec.type;
    final subtitle = (type != null && type.isNotEmpty)
        ? '${_titleCase(type)} · ${_prettyDate(rec.date)}'
        : _prettyDate(rec.date);
    return MedalCard(
      medal: 'PR',
      overline: 'Personal record',
      title: title,
      subtitle: subtitle,
    );
  }

  // ── the rest of the PRs: per-domain BigStat bento ─────────────────────────

  static const _recordDefs = <(String, String, OsIcon, OsIcon?)>[
    ('lowest_rhr', 'Lowest resting HR', OsIcon.heart, OsIcon.restingHeartRate),
    ('lowest_sleeping_hr', 'Lowest sleeping HR', OsIcon.sleep, OsIcon.sleep),
    ('top_strain', 'Biggest day strain', OsIcon.bodyStrain, OsIcon.bodyStrain),
    ('top_workout', 'Top workout strain', OsIcon.run, OsIcon.workouts),
    ('longest_sleep', 'Longest sleep', OsIcon.bedtime, OsIcon.bedtime),
    ('best_efficiency', 'Sleep efficiency', OsIcon.sleep, OsIcon.sleep),
    ('most_steps', 'Most steps', OsIcon.run, OsIcon.steps),
    ('top_readiness', 'Top readiness', OsIcon.recovery, OsIcon.recovery),
  ];

  static Color _accentOf(String key) => switch (key) {
        'lowest_rhr' => DomainAccent.heart,
        'lowest_sleeping_hr' ||
        'longest_sleep' ||
        'best_efficiency' =>
          DomainAccent.sleep,
        'top_strain' || 'top_workout' => DomainAccent.strain,
        'most_steps' => DomainAccent.steps,
        'top_readiness' => DomainAccent.recovery,
        _ => AppColors.accent,
      };

  Widget _recordsBento({String? medalKey}) {
    final tiles = <Widget>[];
    for (final (key, label, icon, _) in _recordDefs) {
      if (key == medalKey) continue; // already the medal
      final rec = r.record(key);
      if (rec == null) continue;
      final (value, unit) = _fmt(key, rec.value);
      final type = rec.type;
      tiles.add(
        BentoTile(
          tone: tiles.length == 1 ? BentoTone.soft : BentoTone.paper,
          accent: _accentOf(key),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TileHeader(label, icon: icon),
              const SizedBox(height: Sp.x2),
              BigStat(
                value: value,
                unit: unit,
                caption: (type != null && type.isNotEmpty)
                    ? '${_titleCase(type)} · ${_prettyDate(rec.date)}'
                    : _prettyDate(rec.date),
              ),
            ],
          ),
        ),
      );
    }
    if (tiles.isEmpty) return const SizedBox.shrink();
    // True masonry: alternate the two stacks.
    final left = <Widget>[], right = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      (i.isEven ? left : right).add(tiles[i]);
    }
    return BentoColumns(left: left, right: right, entrance: false);
  }

  // ── resting-HR drift with the real trend line ─────────────────────────────

  Widget _driftTile() {
    final d = r.rhrDrift;
    if (d == null) {
      return BentoTile(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const TileHeader('Resting HR trend'),
            const SizedBox(height: Sp.x2),
            const BigStat.dash(caption: 'Needs ~3 weeks of nights'),
          ],
        ),
      );
    }
    final improving = d.direction == 'improving';
    final flat = d.direction == 'flat';
    final headline = flat
        ? 'Holding steady'
        : improving
            ? 'Down ${d.delta.abs().toStringAsFixed(1)} bpm'
            : 'Up ${d.delta.abs().toStringAsFixed(1)} bpm';
    return BentoTile(
      tone: BentoTone.soft,
      accent: DomainAccent.heart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TileHeader(
            'Resting HR trend',
            trailing: InfoDot(
              title: 'Resting-HR trend',
              body: improving
                  ? 'A falling resting heart rate usually means your fitness '
                      'is improving.'
                  : flat
                      ? 'Your resting heart rate has been stable.'
                      : 'A rising resting heart rate can mean fatigue, stress '
                          'or illness — worth keeping an eye on.',
              methodNote:
                  'Mean of the newest 7 nightly RHR values vs ~30 days back '
                  '(${d.days} days of history).',
            ),
          ),
          const SizedBox(height: Sp.x2),
          BigStat(
            value: d.now.toStringAsFixed(0),
            unit: 'bpm',
            caption: '$headline · from ${d.then.toStringAsFixed(0)}',
            captionAccent: !flat && !improving,
          ),
          if (rhrSpark.length >= 2) ...[
            const SizedBox(height: Sp.x3),
            Sparkline(
              rhrSpark,
              color: DomainAccent.heart,
              height: 44,
              area: true,
              baseline: d.then,
            ),
          ],
        ],
      ),
    );
  }

  // ── streak flames ─────────────────────────────────────────────────────────

  static const _streakDefs = <(String, String, Color Function())>[
    ('wear', 'Wear', _accentBrand),
    ('sleep', 'Sleep', _accentSleep),
    ('strain_target', 'Strain target', _accentStrain),
  ];

  static Color _accentBrand() => AppColors.accent;
  static Color _accentSleep() => DomainAccent.sleep;
  static Color _accentStrain() => DomainAccent.strain;

  List<Widget> _streakSection() {
    final tiles = <Widget>[];
    for (final (key, label, accentOf) in _streakDefs) {
      final s = r.streak(key);
      if (s == null) continue;
      final active = s.current > 0;
      tiles.add(
        BentoTile(
          tone: active ? BentoTone.soft : BentoTone.paper,
          accent: accentOf(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TileHeader('$label streak',
                  icon: active ? OsIcon.calories : OsIcon.wear,
                  // Streak art only while the streak is alive — a broken
                  // streak keeps the quiet watch glyph.
                  ),
              const SizedBox(height: Sp.x2),
              BigStat(
                value: '${s.current}',
                unit: s.current == 1 ? 'day' : 'days',
                caption: s.label,
              ),
            ],
          ),
        ),
      );
    }
    if (tiles.isEmpty) return const [];
    final left = <Widget>[], right = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      (i.isEven ? left : right).add(tiles[i]);
    }
    return [
      const SizedBox(height: Sp.x3),
      BentoColumns(left: left, right: right, entrance: false),
    ];
  }
}
