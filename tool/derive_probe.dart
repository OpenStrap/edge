// Repro the "int is not a subtype of double?" derive crash on real data.
// Replicates DerivationEngine._deriveDay's pure parts (no DB): build the day's
// DayBundleInput, attach a history for day 2, run deriveDayBundle, print stack.
// Run: dart run tool/derive_probe.dart [/tmp/r24_0626_hex.txt]
import 'dart:io';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

void main(List<String> args) {
  final path = args.isNotEmpty ? args[0] : '/tmp/r24_0626_hex.txt';
  final lines =
      File(path).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
  final sub = decodeSubstrate(lines);
  final days = calendarDays(sub);
  stderr.writeln('days: ${days.length}');

  // Trailing histories (as metric_series would supply). Use WHOLE numbers to
  // mimic SQLite returning REALs as int, both as int and double, to flush the
  // cast. We pass them through jsonEncode/Decode like the real isolate path.
  // Match reality: day 2 has exactly ONE prior day in metric_series.
  final lnHist = <double>[4.2];
  final rhrHist = <double>[61]; // whole number (as SQLite would return)
  final respHist = <double>[14];
  final tempHist = <double>[745];

  for (var di = 0; di < days.length; di++) {
    final day = days[di];
    final daySub = sub.slice(day.startSec, day.endSec);
    final sleepSub = day.hasSleep
        ? sub.sliceIdx(day.sleepLoIdx, day.sleepHiIdx)
        : Substrate.empty;
    final hypno = day.sleep.stages4.isNotEmpty
        ? List<String>.from(day.sleep.stages4)
        : <String>[
            for (final s in day.sleep.stages)
              s == ana.SleepStage.wake
                  ? 'wake'
                  : (s == ana.SleepStage.rem ? 'rem' : 'light')
          ];
    final win = day.sleep.window;
    final onsetSec = win == null
        ? 0
        : (win.onsetMs != null ? (win.onsetMs! / 1000).round() : 0);
    final offsetSec = win == null
        ? 0
        : (win.offsetMs != null ? (win.offsetMs! / 1000).round() + 1 : 0);

    final input = DayBundleInput(
      date: day.date,
      dayTsSec: daySub.tsSec,
      dayHr: daySub.hr,
      sleepTsSec: sleepSub.tsSec,
      sleepHr: sleepSub.hr,
      sleepRrTsMs: sleepSub.rrTsMs,
      sleepRrMs: sleepSub.rrMs,
      sleepSpo2Red: sleepSub.spo2Red,
      sleepSpo2Ir: sleepSub.spo2Ir,
      sleepSkinTemp: sleepSub.skinTemp,
      sleepJson: day.sleep.toJson(),
      hypnoStages: hypno,
      sleepOnsetSec: onsetSec,
      sleepOffsetSec: offsetSec,
      profile: const {'age': 30, 'sex': 'm', 'weight_kg': 70, 'height_cm': 175},
      lnRmssdHistory: di == 0 ? const [] : lnHist,
      rhrHistory: di == 0 ? const [] : rhrHist,
      respHistory: di == 0 ? const [] : respHist,
      skinTempAdcHistory: di == 0 ? const [] : tempHist,
      dayConfidence: day.confidence,
      dayFlags: day.flags,
    );

    // Mimic the real isolate path: toJson → (transfer) → deriveDayBundle.
    final m = input.toJson();
    try {
      final bundle = deriveDayBundle(m);
      // Reproduce the activeMin injection. INT first (the bug), then toDouble.
      final scW = (bundle['scalars'] as Map?)?.cast<String, dynamic>();
      try {
        scW?['active_min'] = 477; // INT — should crash if scalars is double?
        stderr.writeln('  active_min(int) write: OK');
      } catch (e) {
        stderr.writeln('  active_min(int) write FAILED → $e  ← root cause');
        scW?['active_min'] = 477.0; // the fix
        stderr.writeln('  active_min(double) write: OK ← fix works');
      }
      final sc = (bundle['scalars'] as Map);
      final z = bundle['zones'] as Map?;
      final cyc = (bundle['sleep'] as Map?)?['cycle_count'];
      final cycSeries = ((bundle['sleep'] as Map?)?['cycle_series'] as List?)?.length ?? 0;
      stderr.writeln('  cycle_series points: $cycSeries  efficiency=${sc['efficiency']} worn_min=${sc['worn_min']}');
      final nts = (sc['sleeping_hr_nadir_ts'] as num?)?.toInt();
      final ntsClock = nts == null
          ? '—'
          : DateTime.fromMillisecondsSinceEpoch(nts * 1000)
              .toIso8601String()
              .substring(11, 16);
      stderr.writeln('  nadir_ts: $nts  (@ $ntsClock)');
      stderr.writeln('day ${day.date}: OK  '
          'rhr=${sc['rhr']?.toStringAsFixed(0)} stress=${sc['stress']?.toStringAsFixed(0)} '
          'cal=${sc['calories']} nadir=${sc['sleeping_hr_nadir']?.toStringAsFixed(0)} '
          'waking=${sc['waking_hr']?.toStringAsFixed(0)} active=${sc['active_min']} '
          'cycles=$cyc');
      stderr.writeln('  zones(min) z1=${z?['z1']} z2=${z?['z2']} z3=${z?['z3']} '
          'z4=${z?['z4']} z5=${z?['z5']}');
      stderr.writeln('  trend scalars: rem_min=${sc['rem_min']} deep_min=${sc['deep_min']} '
          'light_min=${sc['light_min']} tst_min=${sc['tst_min']} '
          'lf_hf=${sc['lf_hf']} hrv_cv=${sc['hrv_cv']}');
      // cv + irregular (from the pipeline clinical block)
      final clin = bundle['clinical'] as Map?;
      final irr = clin?['irregular'] as Map?;
      stderr.writeln('  cv=${clin?['cv']}  irregular{sd1=${irr?['sd1']} '
          'sd2=${irr?['sd2']} flag=${irr?['flag']}}');
      // engine-injected blocks — replicate inline over the same slices.
      double zang(Substrate s, int i) => ana.zAngle(s.ax[i], s.ay[i], s.az[i]);
      // wear segments
      var wearSegs = 0;
      for (var k = 1; k < daySub.length; k++) {
        if ((daySub.hr[k] > 0) != (daySub.hr[k - 1] > 0)) wearSegs++;
      }
      // daytime HRV buckets (RR outside sleep, 5-min RMSSD)
      final dbins = <int, List<double>>{};
      double? dp;
      for (var k = 0; k < daySub.rrMs.length; k++) {
        final ts = daySub.rrTsMs[k] ~/ 1000;
        if (offsetSec > onsetSec && ts >= onsetSec && ts < offsetSec) { dp = null; continue; }
        final v = daySub.rrMs[k];
        if (v < 300 || v > 2000) { dp = null; continue; }
        if (dp != null && (v - dp).abs() <= 200) (dbins[ts ~/ 300] ??= []).add((v - dp) * (v - dp));
        dp = v;
      }
      final dBuckets = dbins.values.where((l) => l.length >= 5).length;
      // restlessness (sleep accel) — moved minutes
      var restMin = 0, totMin = 0;
      final rmMove = <int, int>{}, rmTot = <int, int>{};
      for (var k = 1; k < sleepSub.length; k++) {
        final mm = sleepSub.tsSec[k] ~/ 60;
        rmTot[mm] = (rmTot[mm] ?? 0) + 1;
        if ((zang(sleepSub, k) - zang(sleepSub, k - 1)).abs() > 5) rmMove[mm] = (rmMove[mm] ?? 0) + 1;
      }
      rmTot.forEach((mm, t) { totMin++; if ((rmMove[mm] ?? 0) / t >= 0.20) restMin++; });
      stderr.writeln('  wear_segments≈$wearSegs  daytime_hrv_buckets=$dBuckets  '
          'restless≈$restMin/$totMin min');
    } catch (e, st) {
      stderr.writeln('day ${day.date}: FAILED → $e');
      stderr.writeln(st.toString().split('\n').take(12).join('\n'));
    }
  }
}
