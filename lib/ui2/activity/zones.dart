// HEART-RATE ZONES — the ceiling, the two anchors, and (only sometimes) the
// 28-day distribution. TS-03 / TS-04 / TS-05.
//
// THE SENTENCE IS THE FEATURE. Zone edges are percentages of a ceiling, and
// this app has two completely different ceilings depending on what it has seen:
// a number MEASURED on the wrist, or `208 − 0.7·age`. Those are materially
// different claims and the screen says which one it is every time. The number
// itself never changes its wording either: "highest we've seen" with the date
// and the session, never "your max HR", and nothing anywhere invites a
// max-effort test.
//
// WHY THE DISTRIBUTION IS OFTEN ABSENT. A three-bar "most of your minutes are
// in the grey middle" read off bands built on 220−age is manufactured — the
// bars would be a picture of an arithmetic assumption, not of training. So it
// is GATED, in the repository, not captioned: no observed ceiling and no
// measured resting HR means no chart at all. It appears about four weeks after
// the band first sees you go hard, and not before.
//
// WHAT THIS SCREEN WILL BE ACCUSED OF. A very low resting heart rate makes
// zone 1 enormous — 48 → 184 bpm puts Z1 at 48–116. That is the reserve
// arithmetic working exactly as intended and it will be reported as a bug, so
// the copy names it before the user does.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart' show whyFromNote;
import '../../state/app_state.dart';
import '../screens/home_screen.dart' show repoOf, monthName;
import '../screens/journal_compose.dart' show OsTextField;
import '../screens/metric_detail.dart' show detailScaffold;
import '../ui2.dart';

/// 'YYYY-MM-DD' → '3 Aug'. Returns the raw label if it does not parse — a date
/// we cannot format is still better than dropping the attribution.
String _prettyDay(String iso, [AppLocalizations? l]) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : '${d.day} ${monthName(d.month, l)}';
}

/// One zone row as the repository serves it.
typedef ZoneRow = ({int zone, String name, int lo, int hi});

class ZonesData {
  /// The observed ceiling: bpm, the day it was held, and the session it came
  /// from. Null while the band has never seen a qualifying effort.
  final int? ceilingBpm;
  final String? ceilingDate;
  final String? ceilingSession;

  /// `karvonen` (both anchors measured) · `observed` (ceiling measured, resting
  /// history still short) · `tanaka` (the age estimate) · null (no ceiling).
  final String? source;
  final int? maxHr;

  /// The 28-day median resting HR the reserve was measured from, and how many
  /// nights back it.
  final int? restingHr;
  final int restingDays, restingMinDays;

  final List<ZoneRow> zones;

  /// TS-05. Null whenever the bars would be built on the age estimate, on too
  /// few sessions, or on sessions with no per-minute trace.
  final List<int>? distMinutes;
  final int distSessions, distEasy, distModerate, distHard;
  final String? distShape;

  /// WHY there are no edges, as the repository said it. Never a sentence
  /// written on this screen; null means nothing said why.
  final String? note;

  /// WHY the 28-day distribution is absent — it has three distinct causes and
  /// the repository names the one that applies, so the screen no longer picks
  /// between two of them off `source`.
  final String? distNote;

  /// WHY there is no measured ceiling. `observedCeilingBpm` refuses for an
  /// unstamped strap, and on all three real databases that — not "no hard
  /// session yet" — is the reason. Null means nothing said why.
  final String? ceilingNote;

  /// The age on file. Null is the ONE case where "Add your age in Profile" is
  /// a real instruction — the screen used to offer it unconditionally, and the
  /// measured run printed it to a user whose age was set, so following it did
  /// nothing at all.
  final int? age;

  const ZonesData({
    this.ceilingBpm,
    this.ceilingDate,
    this.ceilingSession,
    this.source,
    this.maxHr,
    this.restingHr,
    this.restingDays = 0,
    this.restingMinDays = 14,
    this.zones = const [],
    this.distMinutes,
    this.distSessions = 0,
    this.distEasy = 0,
    this.distModerate = 0,
    this.distHard = 0,
    this.distShape,
    this.note,
    this.distNote,
    this.ceilingNote,
    this.age,
  });

  bool get measured => source == 'karvonen';

  static ZonesData parse(Map<String, dynamic> z) {
    final c = z['ceiling'];
    final d = z['distribution'];
    final mins = d is Map ? d['minutes'] : null;
    return ZonesData(
      ceilingBpm: c is Map ? (c['bpm'] as num?)?.round() : null,
      ceilingDate: c is Map ? c['date'] as String? : null,
      ceilingSession: c is Map ? c['session_type'] as String? : null,
      source: z['source'] as String?,
      maxHr: (z['max_hr'] as num?)?.round(),
      restingHr: (z['resting_hr'] as num?)?.round(),
      restingDays: (z['resting_days'] as num?)?.toInt() ?? 0,
      restingMinDays: (z['resting_min_days'] as num?)?.toInt() ?? 14,
      zones: [
        for (final r in (z['zones'] as List? ?? const []).whereType<Map>())
          (
            zone: (r['zone'] as num).toInt(),
            name: r['name'] as String? ?? '',
            lo: (r['lo'] as num).round(),
            hi: (r['hi'] as num).round(),
          ),
      ],
      distMinutes: mins is List && mins.length == 5
          ? [for (final v in mins) (v as num).round()]
          : null,
      distSessions: d is Map ? (d['sessions'] as num?)?.toInt() ?? 0 : 0,
      distEasy: d is Map ? (d['easy_min'] as num?)?.toInt() ?? 0 : 0,
      distModerate: d is Map ? (d['moderate_min'] as num?)?.toInt() ?? 0 : 0,
      distHard: d is Map ? (d['hard_min'] as num?)?.toInt() ?? 0 : 0,
      distShape: d is Map ? d['shape'] as String? : null,
      note: z['note'] as String?,
      ceilingNote: z['ceiling_note'] as String?,
      distNote: ((z['absent'] as Map?)?['distribution'] as Map?)?['note']
          as String?,
      age: (z['age'] as num?)?.toInt(),
    );
  }

  static Future<ZonesData> load(LocalRepository repo) async =>
      parse(await repo.getZones());
}

class ZonesDetail extends StatefulWidget {
  /// Preloaded, for goldens. Null means read the repo on open.
  final ZonesData? data;
  const ZonesDetail({super.key, this.data});

  @override
  State<ZonesDetail> createState() => _ZonesDetailState();
}

class _ZonesDetailState extends State<ZonesDetail> {
  ZonesData? _d;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final d = await ZonesData.load(repo);
      if (mounted) setState(() => (_d = d, _loading = false));
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Five ascending bpm thresholds, one per zone's lower edge — an override
  /// that beats the computed karvonen/observed/tanaka set outright (see
  /// [manualZoneBoundsFromProfile]). Leaving all five fields blank clears it
  /// and falls straight back to the computed default; it is never discarded
  /// silently, only when the user asks for the computed set back.
  Future<void> _editManualZones(BuildContext c, ZonesData d) async {
    final app = c.read<AppState>();
    final current = (app.user?['hr_zone_bounds'] as List?)
        ?.map((v) => (v as num).round())
        .toList();
    final names = d.zones.length == 5
        ? [for (final z in d.zones) z.name]
        : const ['Warm-up', 'Easy', 'Aerobic', 'Threshold', 'Max effort'];
    final ctrls = [
      for (var i = 0; i < 5; i++)
        TextEditingController(
            text: current != null && current.length == 5
                ? '${current[i]}'
                : ''),
    ];
    final l = AppLocalizations.of(c);
    final saved = await showModalBottomSheet<bool>(
      context: c,
      isScrollControlled: true,
      sheetAnimationStyle: sheetMotion(c),
      backgroundColor: P.of(c).card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.xxl)),
      ),
      builder: (s) => Padding(
        padding: EdgeInsets.only(
            left: S.x5,
            right: S.x5,
            top: S.x5,
            bottom: MediaQuery.of(s).viewInsets.bottom + S.x5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l?.activityZonesEditYourOwnTitle ?? 'Set your own zones',
                style: F.head.copyWith(color: P.of(s).ink)),
            const SizedBox(height: S.x2),
            Text(
              l?.activityZonesEditYourOwnBody ??
                  'Five bpm thresholds, lowest to highest — where each zone '
                      'starts. Clear all five to go back to the zones we '
                      'compute for you.',
              style: F.cap.copyWith(color: P.of(s).ink3, height: 1.4),
            ),
            const SizedBox(height: S.x4),
            for (var i = 0; i < 5; i++) ...[
              OsTextField(
                controller: ctrls[i],
                label: 'Z${i + 1} · ${names[i]} starts at',
                hint: l?.activityZonesBpmUnit ?? 'bpm',
                keyboard: TextInputType.number,
              ),
              const SizedBox(height: S.x3),
            ],
            const SizedBox(height: S.x2),
            BigButton(l?.actionSave ?? 'Save',
                color: C.red, onTap: () => Navigator.of(s).pop(true)),
          ],
        ),
      ),
    );
    final typed = [for (final ctl in ctrls) Typed.of(ctl.text)];
    for (final ctl in ctrls) {
      ctl.dispose();
    }
    if (saved != true || !c.mounted) return;
    final bad = [
      for (var i = 0; i < 5; i++) if (typed[i].bad) 'Z${i + 1}',
    ];
    if (bad.isNotEmpty) {
      sayUnreadable(c, bad);
      return;
    }
    final allBlank = typed.every((t) => t.blank);
    if (allBlank) {
      await app.updateProfile({'hr_zone_bounds': null});
      if (mounted) await _load();
      return;
    }
    if (typed.any((t) => t.blank)) {
      if (mounted) {
        ScaffoldMessenger.of(c).showSnackBar(SnackBar(
          content: Text(l?.activityZonesNeedAllFive ??
              'All five thresholds are needed, lowest to highest. Nothing '
                  'was saved.'),
        ));
      }
      return;
    }
    final vals = [for (final t in typed) t.value!.round()];
    for (var i = 1; i < vals.length; i++) {
      if (vals[i] <= vals[i - 1]) {
        if (mounted) {
          ScaffoldMessenger.of(c).showSnackBar(SnackBar(
            content: Text(l?.activityZonesMustAscend ??
                'Each zone must start higher than the last. Nothing was '
                    'saved.'),
          ));
        }
        return;
      }
    }
    await app.updateProfile({'hr_zone_bounds': vals});
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final d = _d ?? const ZonesData();
    return detailScaffold(c, l?.activityZonesTitle ?? 'Heart-rate zones', [
      if (_loading && _d == null) ...[
        const SizedBox(height: S.x8),
        const Center(child: CircularProgressIndicator()),
      ] else ...[
        _ceiling(p, l, d),
        Section(l?.activityZonesYourZonesSection ?? 'Your zones', _zones(p, l, d)),
        const SizedBox(height: S.x2),
        Pressable(
          onTap: () => _editManualZones(context, d),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: S.x2),
            child: Text(
              d.source == 'manual'
                  ? (l?.activityZonesEditYourOwnLink ?? 'Edit your own zones')
                  : (l?.activityZonesSetYourOwnLink ?? 'Set your own zones'),
              style: F.body.copyWith(
                  color: p.on(C.red), fontWeight: FontWeight.w600),
            ),
          ),
        ),
        ..._distribution(p, l, d),
      ],
    ]);
  }

  // ── the ceiling, said the only way it can honestly be said ─────────────────
  Widget _ceiling(P p, AppLocalizations? l, ZonesData d) {
    final bpm = d.ceilingBpm;
    if (bpm == null) {
      // THE CEILING METRIC'S OWN REASON, when it gave one. The hold sentence
      // below is a cause this screen wrote, and on all three real databases it
      // was the wrong one — the ceiling refused for an unstamped strap, and
      // "wear the band for your normal hard sessions" could never fix that.
      final why = whyFromNote(d.ceilingNote);
      final tail = d.source == 'tanaka'
          // Only when there ARE age-estimated edges below. Said
          // unconditionally it described a section that, on every database in
          // the measured run, was itself empty.
          ? (l?.activityZonesNoCeilingTanakaTail ??
              ' Until one is measured, the zones below come off your age.')
          : '';
      return StatusCard(
        l?.activityZonesNoCeilingTitle ?? 'No measured ceiling yet',
        why != null
            ? '$why$tail'
            : (l?.activityZonesNoCeilingDefaultBody ??
                    'We only count a high reading the band held for 15 seconds while '
                        'you were moving. A one-second spike is not a heart '
                        'rate.') +
                tail,
        // The hard-session instruction belongs to the hold gate alone.
        fix: why == null
            ? (l?.activityZonesWearBandFix ??
                'Wear the band for your normal hard sessions')
            : '',
        icon: LucideIcons.heartPulse,
      );
    }
    final where = [
      if (d.ceilingDate != null)
        l?.activityZonesCeilingOnDate(_prettyDay(d.ceilingDate!, l)) ??
            'on ${_prettyDay(d.ceilingDate!, l)}',
      if (d.ceilingSession != null)
        l?.activityZonesCeilingDuringSession(
                d.ceilingSession!.toLowerCase()) ??
            'during ${d.ceilingSession!.toLowerCase()}',
    ].join(', ');
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l?.activityZonesHighestSeenLabel ?? 'HIGHEST WE HAVE SEEN',
              style: F.over.copyWith(color: p.ink3)),
          const SizedBox(height: S.x2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('$bpm', style: F.n34.copyWith(color: p.on(C.red))),
              const SizedBox(width: S.x2),
              Text(l?.activityZonesBpmUnit ?? 'bpm',
                  style: F.body.copyWith(color: p.ink3)),
            ],
          ),
          if (where.isNotEmpty) ...[
            const SizedBox(height: S.x1),
            Text(
              where[0].toUpperCase() + where.substring(1),
              style: F.body.copyWith(color: p.ink2),
            ),
          ],
          const SizedBox(height: S.x3),
          Text(
            l?.activityZonesHighestSeenFootnote ??
                'The highest we have measured, not a limit — it creeps up as the '
                    'band sees harder efforts. Do not go and test it.',
            style: F.cap.copyWith(color: p.ink3, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ── the edges, and the two numbers they were built from ────────────────────
  Widget _zones(P p, AppLocalizations? l, ZonesData d) {
    if (d.zones.isEmpty) {
      // THE REPOSITORY'S REASON, or none. This card used to name one — no age
      // — and offer "Add your age in Profile" as the fix, on a screen whose own
      // payload carries the age. The age was set, the button led to a filled-in
      // field, and nothing changed. It is offered now only when the age really
      // is missing, which is the only state in which it does anything.
      final why = whyFromNote(d.note, unit: 'days');
      final noAge = (d.age ?? 0) <= 0;
      return StatusCard(
        l?.activityZonesNoZonesTitle ?? 'No zones yet',
        why ??
            (noAge
                ? (l?.activityZonesNoAgeBody ??
                    'Zone edges are percentages of a maximum heart rate, and '
                        'without your age there is nothing to take a percentage of.')
                : (l?.activityZonesNoZonesDefaultBody ??
                    'Nothing recorded says why there are no zone edges yet.')),
        fix: noAge ? (l?.activityZonesAddAgeFix ?? 'Add your age in Profile') : '',
        icon: LucideIcons.activity,
      );
    }
    return Surface(
      child: Column(
        children: [
          for (final z in d.zones) ...[
            if (z.zone > 1) Divider(height: S.x5, color: p.line),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 28,
                  decoration: BoxDecoration(
                    color: ZoneBar.cols(p)[z.zone - 1],
                    borderRadius: R.rSm,
                  ),
                ),
                const SizedBox(width: S.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Z${z.zone} · ${z.name}',
                        style: F.body.copyWith(color: p.ink),
                      ),
                    ],
                  ),
                ),
                Text(
                  z.zone == 5 ? '${z.lo}+' : '${z.lo}–${z.hi}',
                  style: F.n17.copyWith(color: p.ink2),
                ),
                const SizedBox(width: S.x2),
                Text(l?.activityZonesBpmUnit ?? 'bpm',
                    style: F.cap.copyWith(color: p.ink3)),
              ],
            ),
          ],
          const SizedBox(height: S.x4),
          Text(
            _anchorCopy(l, d),
            style: F.cap.copyWith(color: p.ink3, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// WHERE THESE EDGES CAME FROM — the whole point of the screen. Three
  /// different claims, three different sentences, never a shared hedge.
  String _anchorCopy(AppLocalizations? l, ZonesData d) {
    final max = d.maxHr;
    switch (d.source) {
      case 'karvonen':
        return l?.activityZonesAnchorKarvonen(
                d.restingHr ?? 0, d.restingDays, max ?? 0) ??
            'Built from two numbers the band measured on you: your resting '
                'rate (${d.restingHr}, the middle of your last ${d.restingDays} '
                'nights) and the highest we have seen ($max). A low resting rate '
                'makes zone 1 wide. These are the usual bands, not your own '
                'measured thresholds.';
      case 'observed':
        return l?.activityZonesAnchorObserved(
                max ?? 0, d.restingMinDays, d.restingDays) ??
            'Built from the highest heart rate we have seen ($max). After '
                '${d.restingMinDays} nights of resting rate (you have '
                '${d.restingDays}) your resting rate joins it, which fits you '
                'better. These are the usual bands, not your own measured '
                'thresholds.';
      case 'tanaka':
        return l?.activityZonesAnchorTanaka(max ?? 0) ??
            'Built from $max bpm, estimated from your age rather than '
                'measured on you — it can be 20 bpm out either way. The edges move '
                'to a measured ceiling once the band sees a hard enough session.';
      case 'manual':
        return l?.activityZonesAnchorManual ??
            'Set by you, not computed — these five thresholds override '
                'whatever your age or a measured ceiling would have given you.';
      default:
        return l?.activityZonesAnchorDefault ??
            'Zone edges are percentages of a maximum heart rate.';
    }
  }

  // ── TS-05 — drawn only when both anchors were measured ─────────────────────
  List<Widget> _distribution(P p, AppLocalizations? l, ZonesData d) {
    final mins = d.distMinutes;
    if (mins == null) {
      // NOT a chart with a caveat. The absence IS the honest state, so it says
      // what would have to be true for the chart to mean anything.
      return [
        Section(
          l?.activityZonesIntensitySection ?? 'Where your intensity went',
          StatusCard(
            l?.activityZonesNotShownTitle ?? 'Not shown yet',
            // THE REPOSITORY'S REASON. This has three distinct causes — no
            // edges at all, edges off the age estimate, or a reserve anchor
            // still short — and the screen was choosing between two of them
            // off `source` alone.
            whyFromNote(d.distNote, unit: 'days') ??
                (d.measured
                    ? (l?.activityZonesNeedsMonthBody ??
                        'Needs about a month of recorded sessions, each with a '
                            'minute-by-minute heart rate.')
                    : (l?.activityZonesAgeEstimateBody ??
                        'The bars would be a picture of the age estimate, not of '
                            'your training. They appear once the zone edges above '
                            'are measured.')),
            icon: LucideIcons.chartColumn,
          ),
        ),
      ];
    }
    final total = mins.fold<int>(0, (a, b) => a + b);
    if (total <= 0) return const [];
    return [
      Section(
        l?.activityZonesIntensitySection ?? 'Where your intensity went',
        Surface(
          child: ChartFrame(
            title: l?.activityZonesSessionMinutesChartTitle ??
                'SESSION MINUTES, LAST 28 DAYS',
            unit: 'minutes',
            height: 10,
            legend: [
              for (var i = 0; i < 5; i++)
                ('Z${i + 1} · ${mins[i]}m', ZoneBar.cols(p)[i]),
            ],
            footnote: _shapeCopy(l, d),
            child: CustomPaint(
              size: Size.infinite,
              painter: ZoneBar([for (final v in mins) v / total], p),
            ),
          ),
        ),
      ),
    ];
  }

  /// A DESCRIPTION of the shape, with no target attached.
  ///
  /// Deliberately no 80/20: that literature is trained endurance athletes
  /// against lab-defined thresholds, and these are %HRR bands off a ceiling a
  /// wrist sensor happened to catch. Naming the shape is a mirror; calling a
  /// share of it correct would be a prescription we cannot support.
  String _shapeCopy(AppLocalizations? l, ZonesData d) {
    final shape = switch (d.distShape) {
      'pyramidal' => l?.activityZonesShapePyramidal ??
          'Most of your minutes are easy, fewer in the middle, '
              'fewest hard — a pyramid.',
      'polarised' => l?.activityZonesShapePolarised ??
          'Most of your minutes are easy and the rest are hard, '
              'with little in between.',
      'middle-heavy' => l?.activityZonesShapeMiddleHeavy ??
          'Most of your minutes sit in the middle rather than '
              'easy or hard.',
      _ => '',
    };
    final summary = l?.activityZonesShapeSummary(
            d.distEasy, d.distModerate, d.distHard, d.distSessions) ??
        '${d.distEasy} min easy, ${d.distModerate} moderate, '
            '${d.distHard} hard, over ${d.distSessions} recorded sessions. A '
            'description, not a target.';
    return '$shape $summary';
  }
}
