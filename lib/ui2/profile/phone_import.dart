// Two reads out of the phone's health store, behind one row on Your data.
//
// They are on the same screen because they are the same promise: OpenStrap did
// not measure any of this. What differs is what each one is ALLOWED to become.
//
// THE OTHER TWO READS ARE NOT HERE, and that is the point. Height and weight
// live on Edit profile, which is the form they fill; workouts live on Workout ›
// History, which is the list they join. Both used to be on this screen, three
// taps deep beside a database export, where nobody goes looking for their
// Sunday run. What is LEFT here is what has nowhere better to be: a resting
// heart rate that becomes a shadow baseline nothing reads yet, and readings
// from instruments this band does not have. They are collected passively — a
// button you press when you think of it, no background sync, no prompt at
// launch — which is exactly what a settings screen is for.
//
//   · Resting heart rate seeds a RANGE — a normal to compare against — and
//     never a day. Another device's resting HR is on another device's scale,
//     which is exactly why it can shape "usual for you" and can never be a
//     value on a chart. No imported night, no back-filled readiness.
//     The screen says this in ordinary words; "a centre and a spread" was the
//     register the owner objected to, and the fact underneath it is unchanged.
//   · Cuff, meter and thermometer readings are DISPLAY ONLY, with the source
//     app's name attached to every one. They are never blended into a composite
//     and never a training target — the moment someone trains a wrist→BP
//     mapping on an imported cuff series, this app is a regulated device that
//     is wrong. That guard is repeated at the import site on purpose.
//
// HRV is deliberately absent from both. iOS writes SDNN, Android RMSSD, and the
// app's own baseline key is fed from rmssd; mixing them is how a new user gets
// a confidently wrong first month, which is worse than the blank it replaces.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../../data/db.dart';
import '../../health/health_import_state.dart';
import '../../health/health_measurement_import.dart';
import '../../health/health_rhr_seed.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'devices.dart' show formatDayTime;

/// The kinds SD-12 imports, in the order they are shown, with the label and the
/// unit each is stored in.
const List<(String kind, String label)> kImportedKindLabels = [
  (kKindSystolic, 'Blood pressure, systolic'),
  (kKindDiastolic, 'Blood pressure, diastolic'),
  (kKindGlucose, 'Blood glucose'),
  (kKindBodyTemp, 'Body temperature'),
];

/// Localized labels for [kImportedKindLabels], keyed by kind.
Map<String, String> _kindLabels(BuildContext c) {
  final l = AppLocalizations.of(c);
  return {
    kKindSystolic: l?.phoneImportSystolic ?? 'Blood pressure, systolic',
    kKindDiastolic: l?.phoneImportDiastolic ?? 'Blood pressure, diastolic',
    kKindGlucose: l?.phoneImportGlucose ?? 'Blood glucose',
    kKindBodyTemp: l?.phoneImportBodyTemp ?? 'Body temperature',
  };
}

class PhoneImport extends StatefulWidget {
  const PhoneImport({super.key});

  @override
  State<PhoneImport> createState() => _PhoneImportState();
}

class _PhoneImportState extends State<PhoneImport> {
  bool _busy = false;
  String? _note;
  bool _noteFailed = false;

  ana.BaselineState? _seed;
  SeedComparison? _compare;

  /// Latest row per kind, newest first. Each carries its own `source`; a row
  /// without one is not renderable and never reaches here.
  final Map<String, Map<String, dynamic>> _latest = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final compare = await RhrSeedImporter.compareAgainstBand();
    final latest = <String, Map<String, dynamic>>{};
    for (final (kind, _) in kImportedKindLabels) {
      final rows = await LocalDb.importedMeasurements(kind, limit: 1);
      if (rows.isNotEmpty) latest[kind] = rows.first;
    }
    if (!mounted) return;
    setState(() {
      _compare = compare;
      _latest
        ..clear()
        ..addAll(latest);
    });
  }

  Future<void> _run(Future<(String, bool)> Function() job) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final (text, failed) = await job();
      if (mounted) {
        setState(() {
          _note = text;
          _noteFailed = failed;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _note = AppLocalizations.of(context)?.dataFailed(e.toString()) ??
              'Failed: $e';
          _noteFailed = true;
        });
      }
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<(String, bool)> _seedRhr() async {
    final l = AppLocalizations.of(context);
    final importer = RhrSeedImporter();
    if (!await importer.requestPermission()) {
      return (
        l?.phoneImportRhrDenied(storeName) ??
            '$storeName did not grant resting heart rate. Nothing was read.',
        true,
      );
    }
    final state = await importer.seed();
    if (state == null) {
      return (
        l?.phoneImportRhrNothingUsable ??
            'Nothing usable came back. It needs resting heart rate over enough days to show your usual range.',
        true,
      );
    }
    if (mounted) setState(() => _seed = state);
    return (
      l?.phoneImportRhrSeeded(state.nValid) ??
          '${state.nValid} day${state.nValid == 1 ? '' : 's'} added to your '
              'usual range. No day was added to any chart.',
      false,
    );
  }

  Future<(String, bool)> _syncMeasurements() async {
    final l = AppLocalizations.of(context);
    final importer = ImportedMeasurementImporter();
    if (!await importer.requestPermission()) {
      return (
        l?.phoneImportMeasurementsDenied(storeName) ??
            '$storeName did not grant those readings. Nothing was read.',
        true,
      );
    }
    final n = await importer.sync();
    return n == 0
        ? (
            l?.phoneImportNothingCameBack(storeName) ??
                'Nothing came back. $storeName holds no readings of these kinds, '
                    'or none inside the window it will share.',
            false,
          )
        : (
            l?.phoneImportReadingsStored(n) ??
                '$n reading${n == 1 ? '' : 's'} stored, each with the app that '
                    'recorded it.',
            false,
          );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final labels = _kindLabels(c);
    final seed = _seed;
    final cmp = _compare;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(l?.phoneImportNavTitle ?? 'From your phone'),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
                children: [
                  // ── seed-baselines ──────────────────────────────────────────
                  Section(
                    l?.phoneImportRhrSection ?? 'Resting heart rate',
                    Surface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l?.phoneImportRhrExplainer(storeName) ??
                                'Reads your resting heart rate from $storeName, so '
                                    'the app has a rough idea of your normal before the '
                                    'band has measured one.',
                            style: F.body.copyWith(color: p.ink2, height: 1.4),
                          ),
                          const SizedBox(height: S.x3),
                          Text(
                            // The two facts that have to survive any rewrite.
                            // The first is a promise-limit: copy implying this
                            // already shapes readiness would promise a number
                            // the screen does not produce. The second is why it
                            // can never be a chart value — another device's
                            // resting HR is on another device's scale.
                            l?.phoneImportRhrLimit ??
                                'Not used yet. Once the band has 14 nights of its own, it is compared with them below. It never becomes a reading of its own.',
                            style: F.cap.copyWith(color: p.ink3, height: 1.5),
                          ),
                          const SizedBox(height: S.x4),
                          BigButton(
                            l?.phoneImportReadRhr ?? 'Read resting heart rate',
                            icon: LucideIcons.heartPulse,
                            color: C.blue,
                            soft: true,
                            onTap: _busy ? null : () => _run(_seedRhr),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (seed != null) ...[
                    const SizedBox(height: S.x3),
                    MetricRow(
                      LucideIcons.heartPulse,
                      C.blue,
                      l?.phoneImportWhatPhoneSays ?? 'What your phone says',
                      '${seed.baseline.round()}',
                      unit: 'bpm',
                      // The spread is what makes this a range rather than a
                      // number, so it stays — but as a range the reader can
                      // picture, not as the word "spread".
                      sub: l?.phoneImportUsuallyRange(
                              (seed.baseline - seed.spread).round(),
                              (seed.baseline + seed.spread).round(),
                              seed.nValid,
                              storeName) ??
                          'usually ${(seed.baseline - seed.spread).round()}'
                              '–${(seed.baseline + seed.spread).round()} bpm, '
                              'over ${seed.nValid} days from $storeName',
                    ),
                  ],
                  // THE GATE. Null until the band has its own 14 nights — and a
                  // comparison from three nights would be a false all-clear, so
                  // there is nothing to draw until then.
                  if (cmp != null) ...[
                    const SizedBox(height: S.x3),
                    StatusCard(
                      cmp.disagrees
                          ? (l?.phoneImportDisagreeTitle ??
                              'The phone and the band disagree')
                          : (l?.phoneImportAgreeTitle ??
                              'The phone and the band agree'),
                      cmp.disagrees
                          ? (l?.phoneImportDisagreeBody(
                                  storeName,
                                  cmp.deltaBpm.abs().toStringAsFixed(1),
                                  cmp.deltaBpm > 0
                                      ? (l.phoneImportHigher)
                                      : (l.phoneImportLower),
                                  cmp.bandNights) ??
                              '$storeName puts your resting heart rate '
                                  '${cmp.deltaBpm.abs().toStringAsFixed(1)} bpm '
                                  '${cmp.deltaBpm > 0 ? 'higher' : 'lower'} than '
                                  'this band over ${cmp.bandNights} nights. They '
                                  'measure different things, so it stays unused.')
                          : (l?.phoneImportAgreeBody(
                                  cmp.bandNights,
                                  cmp.deltaBpm.abs().toStringAsFixed(1),
                                  storeName) ??
                              'Over ${cmp.bandNights} nights the band lands within '
                                  '${cmp.deltaBpm.abs().toStringAsFixed(1)} bpm of '
                                  'what $storeName said. It still is not used for '
                                  'anything.'),
                      icon: cmp.disagrees
                          ? LucideIcons.triangleAlert
                          : LucideIcons.check,
                    ),
                  ],
                  const SizedBox(height: S.x6),
                  // ── SD-12 ───────────────────────────────────────────────────
                  Section(
                    l?.phoneImportMeasuredElsewhere ?? 'Measured by something else',
                    Surface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l?.phoneImportMeasuredElsewhereBody ??
                                'A cuff, a glucose meter, a thermometer. The band can’t measure these, so each reading shows the app that recorded it.',
                            style: F.body.copyWith(color: p.ink2, height: 1.4),
                          ),
                          const SizedBox(height: S.x3),
                          Text(
                            l?.phoneImportNeverAveraged ??
                                'Shown as they arrived. Never averaged into one of '
                                    'this app’s own numbers, never used to teach it to '
                                    'guess one from the wrist.',
                            style: F.cap.copyWith(color: p.ink3, height: 1.5),
                          ),
                          const SizedBox(height: S.x4),
                          BigButton(
                            l?.phoneImportReadFrom(storeName) ??
                                'Read from $storeName',
                            icon: LucideIcons.stethoscope,
                            color: C.teal,
                            soft: true,
                            onTap: _busy ? null : () => _run(_syncMeasurements),
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (final (kind, _) in kImportedKindLabels)
                    if (_latest[kind] case final row?) ...[
                      const SizedBox(height: S.x3),
                      MetricRow(
                        LucideIcons.clipboardList,
                        C.teal,
                        labels[kind]!,
                        _formatValue(row['value']),
                        unit: '${row['unit'] ?? ''}',
                        sub: _sourceLine(row),
                      ),
                    ],
                  const SizedBox(height: S.x5),
                  // The two reads that MOVED, said once, so somebody who
                  // remembers them being here is not left hunting.
                  StatusCard(
                    l?.phoneImportMovedTitle ?? 'Height, weight and workouts moved',
                    l?.phoneImportMovedBody ??
                        'Height and weight are on Edit profile now, and workouts '
                            'this phone recorded are on Workout, under History. '
                            'Each one sits on the screen it fills.',
                    icon: LucideIcons.arrowRight,
                  ),
                  const SizedBox(height: S.x2),
                  if (_busy) ...[
                    const SizedBox(height: S.x6),
                    Center(
                      child: CircularProgressIndicator(color: p.on(C.blue)),
                    ),
                  ],
                  if (_note != null && _note!.isNotEmpty) ...[
                    const SizedBox(height: S.x5),
                    StatusCard(
                      _noteFailed
                          ? (l?.dataThatDidNotWork ?? 'That did not work')
                          : (l?.actionDone ?? 'Done'),
                      _note!,
                      icon: _noteFailed
                          ? LucideIcons.triangleAlert
                          : LucideIcons.check,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "118" / "5.4". One decimal only when the value has one — a cuff reading
/// printed as `118.0` reads like a precision nobody claimed.
String _formatValue(Object? v) {
  final d = (v as num?)?.toDouble();
  if (d == null) return '';
  return d == d.roundToDouble() ? '${d.round()}' : d.toStringAsFixed(1);
}




/// "Omron Connect · Thu 4 Sep, 07:12". The source is not optional decoration:
/// a reading this app did not take, shown without saying who did, is a reading
/// this app is implicitly claiming.
String _sourceLine(Map<String, dynamic> row) {
  final src = (row['source'] as String?)?.trim();
  final ts = (row['ts'] as num?)?.toInt();
  final when = ts == null
      ? null
      : formatDayTime(DateTime.fromMillisecondsSinceEpoch(ts * 1000));
  return [if (src != null && src.isNotEmpty) src, ?when].join(' · ');
}
