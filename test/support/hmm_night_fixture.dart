import 'dart:math' as math;

import 'package:openstrap_edge/compute/onehz_pipeline.dart';

// Six observed minutes, with alternating RR intervals giving nonzero RMSSD.
Map<String, dynamic> hmmNight({bool enabled = true, bool rr = true,
    bool gap = false}) {
  const t = 1577923200, n = 360;
  return DayBundleInput(date: '2020-01-02',
    dayTsSec: const [], dayHr: const [], dayRrTsMs: const [], dayRrMs: const [],
    sleepTsSec: [for (var i = 0; i < n; i++) t + i],
    sleepHr: [for (var i = 0; i < n; i++) gap && i >= 120 && i < 180 ? 0 : 55],
    sleepRrTsMs: rr ? [for (var i = 0; i < n; i++) (t + i) * 1000.0] : const [],
    sleepRrMs: rr ? [for (var i = 0; i < n; i++) 1000 + 30 * math.sin(i * 0.8)] : const [],
    sleepSkinTemp: const [], sleepEnmo: List.filled(n, 0.01),
    sleepJson: {'tst_sec': n, 'nrem_sec': n, 'light_sec': n,
      'deep_sec': 0, 'rem_sec': 0, 'wake_sec': 0, 'waso_sec': 0,
      'efficiency_pct': 100.0},
    hypnoStages: List.filled(n, 'light'), sleepOnsetSec: t,
    sleepOffsetSec: t + n, profile: const {'age_years': 35,
      'weight_kg': 75, 'height_cm': 178, 'sex': 'male'},
    dayConfidence: 1, dayFlags: const [], useHmmStages: enabled).toJson();
}
