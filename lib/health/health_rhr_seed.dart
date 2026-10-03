// Seed a SHADOW resting-heart-rate baseline from the phone's health store.
//
// THE PROBLEM. A personal baseline needs nights. A new user has none, so
// readiness — which is a deviation from a personal centre — is honestly blank
// for weeks. Many of those users have two years of resting HR sitting in Apple
// Health from a watch they already wear.
//
// WHAT THIS SHIPS, AND WHAT IT REFUSES.
//   * A BASELINE, NEVER A DAY. No imported night appears on the sleep chart, no
//     readiness is backfilled. Another device's number is on another device's
//     scale — that can inform a personal CENTRE and SPREAD, and it can never be
//     a value the app shows as measured.
//   * RHR ONLY. Not HRV, not respiratory rate. iOS writes SDNN and Android
//     writes RMSSD, and this app's HRV baseline is fed from rmssd: folding
//     SDNN into it gives a new user confidently wrong readiness for their first
//     month, which is worse than the blank it replaced.
//   * A SHADOW, and nothing consumes it. It is written under its own baselines
//     key, read by nobody, and compared against the band's own once the band
//     has 14 nights of its own. If the two disagree wildly the seed is a
//     liability and the feature stops there — that comparison is the point of
//     this pass, not a diagnostic bolted onto a shipped feature.
//
// PROVENANCE. HealthKit's resting HR is Apple's own derived number, computed by
// their algorithm from their sensor. This has every provenance obligation the
// WHOOP importer has: it is a vendor snapshot, and it must be labelled as one
// wherever it ever surfaces.
//
// (Do not quote the ICC 0.92-0.97 agreement figure at anyone about this. That
// is multi-night averaging; single-night agreement is nearer 0.7-0.9.)

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:package_info_plus/package_info_plus.dart';

import '../data/db.dart';
import '../data/day_label.dart';

/// `baselines` key for the shadow seed. Deliberately NOT one of the keys the
/// derivation engine reads — a grep for this string should find this file, its
/// test, and nothing else.
const String kShadowRhrSeedKey = 'shadow_rhr_seed';

/// How many of the band's own nights before the comparison means anything.
const int kCompareAfterNights = 14;

/// Beyond this many robust-sigmas apart, the seed and the band are not
/// describing the same person's resting heart rate and the seed is a liability.
/// Sigma is the BAND's (1.253 × spread, floored at 2 bpm by the metric config),
/// so on a typical baseline this is roughly 5 bpm.
const double kSeedDisagreementZ = 2.0;

/// The result of comparing the shadow seed against the band's own baseline.
@immutable
class SeedComparison {
  const SeedComparison({
    required this.seedBaseline,
    required this.bandBaseline,
    required this.bandNights,
    required this.z,
  });

  final double seedBaseline;
  final double bandBaseline;
  final int bandNights;

  /// How far the seed's centre sits from the band's, in the band's own robust
  /// sigmas. Signed: positive means the phone reads HIGHER than the band.
  final double z;

  double get deltaBpm => seedBaseline - bandBaseline;

  /// True when the two centres are far enough apart that seeding from the phone
  /// would move a user's readiness for the wrong reason.
  bool get disagrees => z.abs() > kSeedDisagreementZ;

  Map<String, dynamic> toJson() => {
        'seed_baseline': seedBaseline,
        'band_baseline': bandBaseline,
        'band_nights': bandNights,
        'z': z,
        'delta_bpm': deltaBpm,
        'disagrees': disagrees,
      };
}

/// Compare a seeded centre against the band's own folded baseline.
///
/// NULL when the band has fewer than [kCompareAfterNights] usable nights: there
/// is nothing to compare against yet, and "no disagreement detected" from three
/// nights would be a false all-clear.
///
/// Pure, so the decision is testable without a health store or a database.
SeedComparison? compareSeedToBand({
  required double seedBaseline,
  required List<double?> bandNightlyRhr,
}) {
  final state = ana.Baselines.foldHistory(
    bandNightlyRhr,
    ana.Baselines.restingHRCfg,
  );
  if (state == null || state.nValid < kCompareAfterNights) return null;
  final dev = ana.Baselines.deviation(seedBaseline, state);
  if (dev == null) return null;
  return SeedComparison(
    seedBaseline: seedBaseline,
    bandBaseline: state.baseline,
    bandNights: state.nValid,
    z: dev.z,
  );
}

/// Collapse raw resting-HR points to ONE value per local calendar day, newest
/// point per day winning, oldest day first, with a null for every day in the
/// span that has none.
///
/// The gaps matter: [ana.Baselines.foldHistory] treats a null as a missing
/// night and holds rather than skipping, which is how the spread stays honest
/// about an intermittently worn watch.
///
/// Pure — takes (localDayLabel, bpm) pairs so the folding is testable without
/// the plugin's types.
List<double?> nightlySeriesFrom(
  List<(String, double)> dayValues, {
  required String firstDay,
  required String lastDay,
}) {
  final byDay = <String, double>{};
  for (final (day, bpm) in dayValues) {
    // Bounds are a sanity floor on a value being adopted without review. The
    // fold rejects out-of-range values too; doing it here as well keeps a
    // corrupt record from choosing the day.
    if (bpm < 30 || bpm > 120) continue;
    byDay[day] = bpm;
  }
  final out = <double?>[];
  var day = firstDay;
  for (var guard = 0; guard < 4000; guard++) {
    out.add(byDay[day]);
    if (day == lastDay) break;
    final end = localDayEndSec(day);
    if (end == null) break;
    day = dayLabelOf(
      DateTime.fromMillisecondsSinceEpoch(end * 1000, isUtc: true).toLocal(),
    );
  }
  return out;
}

/// Whether a health sample was written by this app. With health sync on, the
/// exporter writes the band's own nightly RHR back as RESTING_HEART_RATE, and
/// a seed built from those compares the band to itself. iOS reports the
/// writer's bundle id as sourceId; Health Connect leaves sourceId empty and
/// puts the package name in sourceName.
bool isOwnHealthSample(String sourceId, String sourceName, String ownId) =>
    ownId.isNotEmpty && (sourceId == ownId || sourceName == ownId);

class RhrSeedImporter {
  RhrSeedImporter({Health? health, bool? isApple})
      : _health = health ?? Health(),
        _isApple = isApple ?? (Platform.isIOS || Platform.isMacOS);

  final Health _health;
  final bool _isApple;

  static const List<HealthDataType> types = [
    HealthDataType.RESTING_HEART_RATE,
  ];

  /// READ access for resting heart rate, and nothing else. The existing write
  /// path asks for WRITE on four types; this deliberately does not widen that
  /// request — a permission sheet listing more than the feature uses is how a
  /// user learns not to trust the sheet.
  Future<bool> requestPermission() async {
    try {
      await _health.configure();
      final already = await _health.hasPermissions(
        types,
        permissions: const [HealthDataAccess.READ],
      );
      if (already == true) return true;
      return await _health.requestAuthorization(
        types,
        permissions: const [HealthDataAccess.READ],
      );
    } catch (e) {
      debugPrint('[rhr_seed] permission: $e');
      return false;
    }
  }

  /// Read the history window and fold it into a shadow baseline.
  ///
  /// Returns the folded state, or null when there was nothing usable to fold —
  /// an empty store, a denied permission and a watch worn twice all end here,
  /// and none of them may become a baseline.
  Future<ana.BaselineState?> seed({DateTime? now}) async {
    final end = now ?? DateTime.now();
    // SIX MONTHS on Apple. Health Connect caps third-party reads at the last 30
    // DAYS unless the user grants READ_HEALTH_DATA_HISTORY, and the pinned
    // `health` 11.1.1 exposes no API to request it — so asking Android for six
    // months returns 30 days while implying otherwise. 30 days is still twice
    // the nights this needs, so Android gets a real (if narrower) seed rather
    // than a false claim about the window.
    final start = _isApple
        ? DateTime(end.year, end.month - 6, end.day)
        : end.subtract(const Duration(days: 30));
    List<HealthDataPoint> points;
    try {
      await _health.configure();
      points = await _health.getHealthDataFromTypes(
        types: types,
        startTime: start,
        endTime: end,
      );
    } catch (e) {
      debugPrint('[rhr_seed] read: $e');
      return null;
    }
    var ownId = '';
    try {
      ownId = (await PackageInfo.fromPlatform()).packageName;
    } catch (e) {
      debugPrint('[rhr_seed] package info: $e');
    }
    final dayValues = <(String, double)>[];
    for (final p in points) {
      if (p.type != HealthDataType.RESTING_HEART_RATE) continue;
      if (isOwnHealthSample(p.sourceId, p.sourceName, ownId)) continue;
      final v = p.value;
      if (v is! NumericHealthValue) continue;
      dayValues.add((dayLabelOf(p.dateTo.toLocal()), v.numericValue.toDouble()));
    }
    if (dayValues.isEmpty) return null;
    final series = nightlySeriesFrom(
      dayValues,
      firstDay: dayLabelOf(start),
      lastDay: dayLabelOf(end),
    );
    final state = ana.Baselines.foldHistory(
      series,
      ana.Baselines.restingHRCfg,
    );
    if (state == null) return null;
    // The source name rides with it. This is Apple's (or the Android
    // provider's) OWN derived resting heart rate, not a raw measurement, and
    // anything that ever surfaces it has to be able to say so.
    await LocalDb.putBaseline(
      kShadowRhrSeedKey,
      jsonEncode({
        'state': state.toJson(),
        'source': _isApple ? 'HealthKit' : 'Health Connect',
        'window_days': end.difference(start).inDays,
        'days_read': series.length,
        'read_at': end.millisecondsSinceEpoch ~/ 1000,
      }),
    );
    return state;
  }

  /// Read back the stored shadow seed's centre, or null when none was stored.
  static Future<double?> storedSeedBaseline() async {
    final row = await LocalDb.baseline(kShadowRhrSeedKey);
    final payload = row?['payload_json'];
    if (payload is! String || payload.isEmpty) return null;
    try {
      final j = jsonDecode(payload);
      if (j is! Map) return null;
      final state = j['state'];
      if (state is! Map) return null;
      return (state['baseline'] as num?)?.toDouble();
    } catch (_) {
      return null;
    }
  }

  /// THE GATE. Compare the stored seed against the band's own baseline, folded
  /// from the band's own nightly resting HR.
  ///
  /// Null while the band has fewer than [kCompareAfterNights] nights, or when
  /// nothing was ever seeded. A non-null result whose [SeedComparison.disagrees]
  /// is true is the answer the ceiling asked for: the seed does not describe the
  /// same resting heart rate the band measures, and it must not be promoted into
  /// anything a user sees.
  static Future<SeedComparison?> compareAgainstBand() async {
    final seed = await storedSeedBaseline();
    if (seed == null) return null;
    // THE BAND'S OWN nightly values — an imported day is another vendor's
    // resting HR, and comparing a phone seed against that answers a different
    // question than the one this gate asks (see LocalDb.importedDates).
    final rows = await LocalDb.metricSeries('rhr', measuredOnly: true);
    final band = <double?>[
      for (final r in rows) (r['value'] as num?)?.toDouble(),
    ];
    return compareSeedToBand(seedBaseline: seed, bandNightlyRhr: band);
  }
}
