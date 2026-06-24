// Contract test for the EXPANDED LocalPipeline: exercise EVERY Rust-core FFI call
// computeAll() makes — including the 1 Hz family — with inputs built from the 550 real
// whoop_hist frames, and assert none error and the headline metrics produce values.
// This catches request/response shape drift without needing the SQLite store.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/native/native_core.dart';

void main() {
  final home = Platform.environment['HOME']!;
  final root = '$home/Documents/whoop-master';
  final dylib = '$root/openstrap-edge/rust/target/debug/libosc_edge.dylib';
  final hist = '$root/whoop_hist.jsonl';

  test('full local metric chain (per-day + cross-day + 1 Hz) via FFI', () {
    if (!File(dylib).existsSync()) {
      fail('build the glue first: cd openstrap-edge/rust && cargo build');
    }
    final core = NativeCore.open(libPath: dylib);

    // Decode the 550 R24 frames → minutes + pooled RR + per-minute RR.
    final lines = File(hist).readAsLinesSync().where((l) => l.trim().isNotEmpty);
    final rr = <num>[];
    final rrByMinMap = <int, List<num>>{};
    final buckets = <int, List<num>>{};
    for (final line in lines) {
      final rec = jsonDecode(line) as Map<String, dynamic>;
      if (rec['t'] != 24) continue;
      final out = core.decode('decode_r24', rec['hex'] as String);
      if (out == null) continue;
      final hr = (out['hr'] ?? 0) as num;
      final ts = (out['ts_epoch'] ?? 0) as num;
      final frameRr = (out['rr_intervals_ms'] ?? const []) as List;
      for (final v in frameRr) {
        rr.add(v as num);
        (rrByMinMap[ts ~/ 60] ??= []).add(v);
      }
      if (hr > 0) (buckets[ts ~/ 60] ??= []).add(hr);
    }

    final minutes = buckets.entries.map((e) {
      final hrs = e.value;
      return {
        'ts': e.key * 60,
        'hr_avg': hrs.reduce((a, b) => a + b) / hrs.length,
        'hr_min': hrs.reduce((a, b) => a < b ? a : b),
        'hr_max': hrs.reduce((a, b) => a > b ? a : b),
        'hr_n': hrs.length,
        'activity': 0,
        'steps': 0,
        'wrist_on': true,
      };
    }).toList()
      ..sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    final byMin = (rrByMinMap.entries.map((e) => {'ts': e.key * 60, 'rr': e.value}).toList()
      ..sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int)));
    final baseline = {'resting_hr': 50, 'max_hr': 190, 'sleep_need_min': 480};
    final profile = {'age': 30, 'sex': 'm', 'height_cm': 178, 'weight_kg': 78};
    final onset = minutes.first['ts'], wake = minutes.last['ts'];

    // Helper: call + assert it didn't return an {error:...}.
    dynamic ok(String fn, Map<String, dynamic> req) {
      final r = core.analytics(fn, req);
      expect(r is Map && r['error'] != null, isFalse, reason: '$fn errored: $r');
      return r;
    }

    // ── per-day chain ──
    final sleep = ok('calc_sleep', {'minutes': minutes, 'baseline': baseline});
    ok('stage_hypnogram', {'minutes': minutes, 'onset': onset, 'wake': wake, 'baseline': baseline, 'rr_by_min': byMin});
    ok('calc_sleep_periods', {'minutes': minutes, 'baseline': baseline});
    final rhr = ok('calc_resting_hr', {'minutes': minutes, 'sleep_window': {'onset_ts': onset, 'wake_ts': wake}});
    final strain = ok('calc_strain', {'minutes': minutes, 'baseline': baseline, 'profile': profile});
    final zones = ok('calc_hr_zones', {'minutes': minutes, 'baseline': baseline, 'profile': profile});
    ok('calc_calories', {'minutes': minutes, 'profile': profile, 'resting_hr': rhr['resting_hr'], 'max_hr': zones['max_hr_used']});
    ok('calc_hr_recovery', {'minutes': minutes, 'baseline': baseline, 'profile': profile});
    ok('detect_sessions', {'minutes': minutes, 'baseline': baseline, 'profile': profile});
    ok('calc_nocturnal_heart', {'sleep_minutes': minutes, 'day_minutes': minutes, 'baseline': baseline});
    ok('calc_sleep_stress', {'sleep_minutes': minutes, 'baseline': baseline});
    ok('calc_restlessness', {'sleep_minutes': minutes, 'baseline': baseline});
    final hrv = ok('time_domain_hrv', {'rr': rr});
    ok('freq_domain_hrv', {'rr': rr});
    ok('baevsky_stress_index', {'rr': rr});
    ok('calc_recovery', {'rmssd_today': hrv['rmssd'], 'baseline_rmssd': [80.0, 90.0, 100.0, 95.0, 88.0], 'date': '2024-01-01'});
    ok('calc_stress', {'rr': rr, 'baseline_si': [50.0, 60.0, 55.0, 58.0, 52.0], 'date': '2024-01-01'});

    // ── 1 Hz-native family ──
    final cvhr = ok('calc_cvhr', {'rr': rr});
    ok('calc_dc_ac', {'rr': rr});
    ok('calc_hr_asymmetry', {'rr': rr});
    ok('calc_long_term_hrv', {'rr': rr});
    ok('calc_circadian_hrv', {'by_minute': byMin, 'night_from': onset, 'night_to': wake});
    ok('calc_daytime_hrv', {'by_minute': byMin});

    // ── illness / anomaly ──
    ok('calc_illness', {'today': {'resting_hr': rhr['resting_hr'], 'rmssd': hrv['rmssd']}, 'history': {'resting_hr': [55.0, 56.0], 'rmssd': [90.0, 95.0]}});
    ok('calc_anomaly', {'recent_rhr': [55.0, 56.0, 57.0], 'sleep_efficiency': sleep['efficiency'], 'baseline': baseline});

    // ── cross-day chain ──
    final series = [for (var i = 0; i < 10; i++) {'ts': 1700000000 + i * 86400, 'strain': 8.0 + i}];
    ok('calc_load', {'daily_strain': series});
    ok('calc_fitness_model', {'daily_strain': series});
    ok('calc_monotony', {'daily_strain': series});
    ok('calc_fitness_trend', {'daily': [for (var i = 0; i < 8; i++) {'resting_hr': 55.0 + i, 'hrr60': 30.0, 'daily_strain': 8.0}]});
    ok('calc_vo2max', {'max_hr': zones['max_hr_used'], 'resting_hr': rhr['resting_hr']});
    ok('calc_sleep_regularity', {'nights': [for (var i = 0; i < 5; i++) {'onset_ts': onset, 'wake_ts': wake}]});
    ok('calc_readiness_index', {'recovery': 60.0, 'sleep_duration_min': sleep['duration_min'], 'sleep_need_min': 480, 'dip_pct': 0.15, 'sleep_stress': 30.0});

    expect(strain['score'], isNotNull);
    expect(hrv['rmssd'], isNotNull);
    // ignore: avoid_print
    print('FULL CHAIN OK — strain=${strain['score']} rmssd=${hrv['rmssd']} '
        'cvhr=${cvhr['fcv_per_hour']} sleep_eff=${sleep['efficiency']}');
  });
}
