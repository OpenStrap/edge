// Headless end-to-end proof of the LOCAL pipeline: load the real 550 whoop_hist
// R24 frames → decode via the Rust core (FFI) → build minutes + RR → run analytics
// (HRV + strain + resting HR) via the same core. Runs on the host Dart VM under
// `flutter test` by dlopen-ing the debug dylib — no device/simulator needed.
//
// Prereq: `cd rust && cargo build` (produces target/debug/libosc_edge.dylib).
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/native/native_core.dart';

void main() {
  final home = Platform.environment['HOME']!;
  final root = '$home/Documents/whoop-master';
  final dylib = '$root/openstrap-edge/rust/target/debug/libosc_edge.dylib';
  final hist = '$root/whoop_hist.jsonl';

  test('local pipeline: whoop_hist → decode → analytics (all via Rust FFI)', () {
    if (!File(dylib).existsSync()) {
      fail('build the glue first: cd openstrap-edge/rust && cargo build  (missing $dylib)');
    }
    final core = NativeCore.open(libPath: dylib);

    // 1. decode every R24 frame through the Rust decoder.
    final lines = File(hist).readAsLinesSync().where((l) => l.trim().isNotEmpty);
    final rr = <num>[];
    final buckets = <int, List<num>>{}; // ts//60 -> hr samples
    var decoded = 0;
    for (final line in lines) {
      final rec = jsonDecode(line) as Map<String, dynamic>;
      if (rec['t'] != 24) continue;
      final out = core.decode('decode_r24', rec['hex'] as String);
      if (out == null) continue;
      decoded++;
      final hr = (out['hr'] ?? 0) as num;
      final ts = (out['ts_epoch'] ?? out['ts'] ?? 0) as num;
      final frameRr = (out['rr_intervals_ms'] ?? out['rr'] ?? const []) as List;
      for (final v in frameRr) { rr.add(v as num); }
      if (hr > 0) (buckets[(ts ~/ 60)] ??= []).add(hr);
    }
    expect(decoded, greaterThan(500), reason: 'most of the 550 frames should decode');

    // 2. HRV from the pooled beat-to-beat RR.
    final hrv = core.analytics('time_domain_hrv', {'rr': rr});
    expect(hrv['rmssd'], isNotNull, reason: 'RR→HRV must produce an RMSSD');
    expect(hrv['n_beats'], greaterThan(20));

    // 3. build per-minute rollup → strain + resting HR.
    final minutes = buckets.entries.map((e) {
      final hrs = e.value;
      final avg = hrs.reduce((a, b) => a + b) / hrs.length;
      return {
        'ts': e.key * 60,
        'hr_avg': avg,
        'hr_min': hrs.reduce((a, b) => a < b ? a : b),
        'hr_max': hrs.reduce((a, b) => a > b ? a : b),
        'hr_n': hrs.length,
        'activity': 0,
        'steps': 0,
        'wrist_on': true,
      };
    }).toList()
      ..sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    final baseline = {'resting_hr': 50, 'max_hr': 190, 'sleep_need_min': 480};

    final strain = core.analytics('calc_strain', {'minutes': minutes, 'baseline': baseline});
    expect(strain['score'], isNotNull);
    expect(strain['tier'], 'HIGH');

    final rhr = core.analytics('calc_resting_hr', {
      'minutes': minutes,
      'sleep_window': {'onset_ts': minutes.first['ts'], 'wake_ts': minutes.last['ts']},
    });
    expect(rhr['resting_hr'], isNotNull);

    // ignore: avoid_print
    print('LOCAL PIPELINE OK — decoded $decoded frames, ${rr.length} RR (HRV n=${hrv['n_beats']} '
        'rmssd=${hrv['rmssd']}), ${minutes.length} min → strain=${strain['score']} rhr=${rhr['resting_hr']}');
  });
}
