// cloud_import.dart — one-shot import of a v2 cloud account's DERIVED history into
// the local store, for the "existing user" onboarding path.
//
// The v2 cloud only exposes DERIVED summaries (daily / sleep / sessions) — raw
// 1 Hz is never retrievable — so imported days are read-only SNAPSHOTS: we shape
// each cloud day into the same bundle the local pipeline produces (a SUBSET:
// scalars + sleep accounting/window + minimal clinical envelopes) and persist it
// via the normal LocalDb.putDayResult (day_result + metric_series in one txn),
// marked `finalized` so the DerivationEngine never tries to recompute it (there's
// no raw to recompute from). Importing the daily series into metric_series also
// SEEDS the rolling baselines the recovery/illness stack reads — that's the
// "snapshots + baselines" the onboarding promised.
//
// Overlap with future 1 Hz days is safe: putDayResult is INSERT-OR-REPLACE on
// (day_id, algo_version), so once the band syncs and a real 1 Hz day is derived
// it OVERWRITES any imported snapshot for the same date (real data wins).

import 'dart:convert';

import '../compute/derivation_engine.dart' show kAlgoVersion;
import '../data/db.dart';
import 'backend_client.dart';

class CloudImportResult {
  final int days;
  final int sessions;
  final Map<String, dynamic> profile; // cloud user → local profile fields
  CloudImportResult(this.days, this.sessions, this.profile);
}

class CloudImporter {
  static const int defaultDays = 90;

  /// Pull [days] of derived history from the authenticated [api] and write it to
  /// the local store. Returns counts + the mapped local profile. The caller
  /// (AppState) persists the profile and flips the onboarding choice.
  static Future<CloudImportResult> run(BackendClient api,
      {int days = defaultDays}) async {
    final now = DateTime.now().toUtc();
    final fromD = now.subtract(Duration(days: days));
    final from = _ymd(fromD), to = _ymd(now);

    final profileRaw = await api.getProfile();
    final dailies = await api.getDailies(from, to);
    final sleeps = await api.getSleeps(from, to);
    final sessions = await api.getSessions(
        fromD.millisecondsSinceEpoch ~/ 1000, now.millisecondsSinceEpoch ~/ 1000);

    // Index sleep rows by date so each daily row can pick up its night.
    final sleepByDate = <String, Map<String, dynamic>>{};
    for (final s in sleeps) {
      if (s is Map && s['date'] is String) {
        sleepByDate[s['date'] as String] = s.cast<String, dynamic>();
      }
    }
    final dailyDates = <String>{};
    var dayCount = 0;
    for (final row in dailies) {
      if (row is! Map) continue;
      final date = row['date'] as String?;
      if (date == null) continue;
      dailyDates.add(date);
      await _writeDay(date, row.cast<String, dynamic>(), sleepByDate[date]);
      dayCount++;
    }
    // Nights present in /sleep but with no daily row → still import the sleep.
    for (final e in sleepByDate.entries) {
      if (dailyDates.contains(e.key)) continue;
      await _writeDay(e.key, const {}, e.value);
      dayCount++;
    }

    var sessCount = 0;
    for (final w in sessions) {
      if (w is! Map) continue;
      await _writeSession(w.cast<String, dynamic>());
      sessCount++;
    }

    return CloudImportResult(dayCount, sessCount, _mapProfile(profileRaw));
  }

  /// Cloud `users` row → the local profile map AppState persists.
  static Map<String, dynamic> _mapProfile(Map<String, dynamic> u) {
    num? n(Object? v) => v is num ? v : null;
    return <String, dynamic>{
      if (u['name'] != null) 'name': u['name'],
      if (n(u['age']) != null) 'age': n(u['age'])!.round(),
      if (n(u['height_cm']) != null) 'height_cm': n(u['height_cm']),
      if (n(u['weight_kg']) != null) 'weight_kg': n(u['weight_kg']),
      if (u['sex'] != null) 'sex': u['sex'],
      if (n(u['step_goal']) != null) 'step_goal': n(u['step_goal'])!.round(),
      if (u['track_cycle'] != null) 'track_cycle': u['track_cycle'] == 1 || u['track_cycle'] == true,
    };
  }

  static Future<void> _writeDay(
      String date, Map<String, dynamic> d, Map<String, dynamic>? sl) async {
    num? n(Object? v) => v is num ? v : null;
    final rhr = n(d['resting_hr']);
    final rmssd = n(d['hrv_rmssd']);
    final sdnn = n(d['hrv_sdnn']);
    final readiness = n(d['readiness']) ?? n(d['recovery']);
    final strain = n(d['strain']);
    final resp = n(d['resp_rate']);
    final calories = n(d['calories']);
    final wearMin = n(d['wear_min']);
    final stress = _parseObj(d['stress']);
    final nocturnal = _parseObj(d['nocturnal']);

    // Sleep accounting (cloud minutes → seconds), if a night exists.
    Map<String, dynamic>? acct, win;
    num? tstMin, remMin, deepMin, lightMin, effPct;
    if (sl != null) {
      final dur = n(sl['duration_min']);
      final eff = n(sl['efficiency']); // 0..1
      final onset = n(sl['onset_ts']);
      final wake = n(sl['wake_ts']);
      final light = n(sl['light_min']);
      final deep = n(sl['deep_min']);
      final rem = n(sl['rem_min']);
      tstMin = dur;
      remMin = rem;
      deepMin = deep;
      lightMin = light;
      effPct = eff == null ? null : eff * 100;
      final tstSec = dur == null ? null : (dur * 60).round();
      final sptSec =
          (onset != null && wake != null) ? (wake - onset).round() : null;
      final wasoSec = (sptSec != null && tstSec != null)
          ? (sptSec - tstSec).clamp(0, 1 << 30)
          : null;
      acct = {
        'tst_sec': tstSec,
        'waso_sec': wasoSec,
        'in_bed_sec': sptSec,
        'efficiency_pct': effPct,
        'light_sec': light == null ? null : (light * 60).round(),
        'deep_sec': deep == null ? null : (deep * 60).round(),
        'rem_sec': rem == null ? null : (rem * 60).round(),
        'nrem_sec': (light != null && deep != null)
            ? ((light + deep) * 60).round()
            : null,
        'wake_sec': wasoSec,
        'deep_low_confidence': true,
        'imported': true,
      };
      win = {
        'onset_ms': onset == null ? null : (onset * 1000).round(),
        'offset_ms': wake == null ? null : (wake * 1000).round(),
        'spt_sec': sptSec,
      };
    }

    Map<String, dynamic> env(Object? value,
            {double conf = 0.7, String tier = 'HIGH'}) =>
        {
          'value': value ?? '—',
          'confidence': value == null ? 0 : conf,
          'tier': tier,
          'inputs_used': const ['cloud_v2'],
        };

    final clinical = <String, dynamic>{
      if (rmssd != null)
        'hrv_time': env({'rmssd': rmssd, 'sdnn': sdnn}, tier: 'HIGH'),
      if (rhr != null) 'resting_hr': env({'low30Mean': rhr}, tier: 'HIGH'),
      if (strain != null) 'strain': env(strain, tier: 'ESTIMATE'),
    };

    final bundle = <String, dynamic>{
      'date': date,
      'imported': true,
      'source': 'cloud_v2',
      'day_confidence': 0.7,
      'flags': const ['IMPORTED_CLOUD_V2'],
      'clinical': clinical,
      if (acct != null)
        'sleep': {
          'window': {
            'value': win,
            'confidence': 0.7,
            'tier': 'HIGH',
            'inputs_used': const ['cloud_v2'],
          },
          'accounting': {
            'value': acct,
            'confidence': 0.7,
            'tier': 'ESTIMATE',
            'inputs_used': const ['cloud_v2'],
          },
        },
      'stress': ?stress,
      'scalars': {
        'rhr': rhr,
        'rmssd': rmssd,
        'sdnn': sdnn,
        'readiness': readiness,
        'strain': strain,
        'resp_rate': resp,
        'calories': calories,
        'skin_temp_z': n(d['skin_temp_idx']),
        'spo2': n(d['spo2_idx']),
        'stress': stress == null ? null : n(stress['score']),
        'tst_min': tstMin,
        'rem_min': remMin,
        'deep_min': deepMin,
        'light_min': lightMin,
        'efficiency': effPct,
        'worn_min': wearMin,
        'sleeping_hr_nadir':
            nocturnal == null ? null : n(nocturnal['sleeping_hr_min']),
        'waking_hr': nocturnal == null ? null : n(nocturnal['day_hr_avg']),
      },
    };

    double? f(num? v) => v?.toDouble();
    await LocalDb.putDayResult(
      dayId: date,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(bundle),
      windowJson: jsonEncode(win ?? const {}),
      finalized: true, // imported snapshot — never recomputed (no raw exists)
      rhr: f(rhr),
      rmssd: f(rmssd),
      readiness: f(readiness),
      series: {
        'rhr': f(rhr),
        'rmssd': f(rmssd),
        'readiness': f(readiness),
        'strain': f(strain),
        'resp_rate': f(resp),
        'calories': f(calories),
        'tst_min': f(tstMin),
        'rem_min': f(remMin),
        'deep_min': f(deepMin),
        'light_min': f(lightMin),
        'efficiency': f(effPct),
        'worn_min': f(wearMin),
        'stress': stress == null ? null : f(n(stress['score'])),
        'skin_temp_z': f(n(d['skin_temp_idx'])),
        'spo2': f(n(d['spo2_idx'])),
      },
    );
  }

  static Future<void> _writeSession(Map<String, dynamic> w) async {
    num? n(Object? v) => v is num ? v : null;
    final start = n(w['start_ts'])?.toInt();
    final end = n(w['end_ts'])?.toInt();
    final zones = w['zones'];
    await LocalDb.putSession({
      'id': (w['id'] ?? 'cloud_$start').toString(),
      'start_ts': start ?? 0,
      'end_ts': end,
      'type': (w['type'] ?? w['detected_type'] ?? 'other').toString(),
      'status': (w['status'] ?? 'done').toString(),
      'source': 'cloud',
      'calories': n(w['calories'])?.toDouble(),
      'strain': n(w['strain'])?.toDouble(),
      'max_hr': n(w['max_hr'])?.toInt(),
      'duration_min':
          (start != null && end != null) ? ((end - start) / 60).round() : null,
      'zone_min_json': zones == null ? null : jsonEncode(zones),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Map<String, dynamic>? _parseObj(Object? v) {
    if (v is Map) return v.cast<String, dynamic>();
    if (v is String && v.isNotEmpty) {
      try {
        final d = jsonDecode(v);
        return d is Map ? d.cast<String, dynamic>() : null;
      } catch (_) {/* not JSON */}
    }
    return null;
  }
}
