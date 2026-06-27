// Real-data sleep probe — NOT shipped. Decodes a dumped R24 hex file into the
// real Substrate, runs the EXACT pipeline detectors, and prints, per night:
//   • van Hees window (ACCEL ONLY) — onset/offset/SPT
//   • the immobile-run structure (where the night fragments + the gaps)
//   • the HR-dip step's threshold + where it FIRST triggers
//   • segmentSleep (WITH HR-dip) — final onset/offset/TST/WASO/eff
// so we can see whether van Hees fragmentation or the HR-dip trim is what shoves
// onset to 02:41. Run: dart run tool/sleep_probe.dart [/tmp/r24_0626_hex.txt]
import 'dart:io';
import 'dart:math' as math;
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

String _t(num ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
  String p(int x) => x.toString().padLeft(2, '0');
  return '${p(d.month)}/${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
}

String _ts(int sec) => _t(sec * 1000);
String _hrs(int sec) => '${(sec / 3600).toStringAsFixed(2)}h';

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

int _lb(List<int> a, int v) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (a[mid] < v) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

void main(List<String> args) {
  final path = args.isNotEmpty ? args[0] : '/tmp/r24_0626_hex.txt';
  final lines = File(path)
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .toList();
  stderr.writeln('hex lines: ${lines.length}');
  final sub = decodeSubstrate(lines);
  print('SUBSTRATE  ${sub.length} sec   '
      '${_ts(sub.tsSec.first)} → ${_ts(sub.tsSec.last)}\n');

  final accel = sub.accelSamples();
  final hr = sub.hr1hz();

  // What the app actually produces:
  final days = calendarDays(sub);
  print('=== calendarDays() → ${days.length} day(s) ===');
  for (final d in days) {
    final s = d.sleep;
    final w = s.window;
    final line = (s.present && w != null)
        ? 'onset ${_t(w.onsetMs!)}  offset ${_t(w.offsetMs!)}  '
            'inBed ${_hrs(s.inBedSec!)}  TST ${_hrs(s.tstSec!)}  '
            'WASO ${(s.wasoSec! / 60).round()}m  eff ${s.efficiencyPct!.round()}%  '
            'conf ${s.confidence.toStringAsFixed(2)}'
        : 'NO SLEEP';
    print('  day ${d.date}  wake@${_ts(d.startSec)}  [$line]');
    // Stress (Baevsky SI) over the sleep-window RR — confirm it computes.
    if (s.present && w != null) {
      final lo = w.onsetMs!, hi = w.offsetMs!;
      final rr = <double>[];
      for (var k = 0; k < sub.rrMs.length; k++) {
        if (sub.rrTsMs[k] >= lo && sub.rrTsMs[k] <= hi) rr.add(sub.rrMs[k]);
      }
      final nn = ana.correctRr(rr).nn;
      final si = ana.baevskyStressIndex(nn);
      print('     stress → SI ${si.present ? si.value!.si.toStringAsFixed(1) : "—"}  '
          'level ${si.present ? si.value!.level : "—"}  '
          '(beats ${nn.length})');
    }
    if (s.present && s.tstSec != null && s.tstSec! > 0) {
      int pct(int? x) => ((x ?? 0) * 100 / s.tstSec!).round();
      print('     stages of TST →  light ${pct(s.lightSec)}%  '
          'deep ${pct(s.deepSec)}%  rem ${pct(s.remSec)}%   '
          '(light ${((s.lightSec ?? 0) / 3600).toStringAsFixed(1)}h  '
          'deep ${((s.deepSec ?? 0) / 3600).toStringAsFixed(1)}h  '
          'rem ${((s.remSec ?? 0) / 3600).toStringAsFixed(1)}h)');
    }
  }

  // Active-minutes sanity check (same ENMO logic as the engine), per calendar
  // day, excluding that day's sleep window.
  print('\n=== active minutes (1 Hz ENMO, wake only) ===');
  for (final d in days) {
    final lo = d.startSec, hi = d.endSec;
    final onS = d.sleep.window != null ? d.sleep.window!.onsetMs! ~/ 1000 : 0;
    final offS = d.sleep.window != null ? d.sleep.window!.offsetMs! ~/ 1000 : 0;
    final idxLo = sub.tsSec.indexWhere((t) => t >= lo);
    if (idxLo < 0) continue;
    final moveSec = <int, int>{}, totSec = <int, int>{};
    double? prevAng;
    for (var i = idxLo; i < sub.length && sub.tsSec[i] < hi; i++) {
      final t = sub.tsSec[i];
      final a = accel[i];
      final aang = ana.zAngle(a.x, a.y, a.z);
      final dPrev = prevAng;
      prevAng = aang;
      if (offS > onS && t >= onS && t < offS) continue;
      final m = t ~/ 60;
      totSec[m] = (totSec[m] ?? 0) + 1;
      if (dPrev != null && (aang - dPrev).abs() > 5.0) {
        moveSec[m] = (moveSec[m] ?? 0) + 1;
      }
    }
    var active = 0;
    totSec.forEach((m, tot) {
      if (tot > 0 && (moveSec[m] ?? 0) / tot >= 0.20) active++;
    });
    print('  day ${d.date}: $active active min  (${totSec.length} wake min total)');
  }

  // Per night, slice exactly like the scan does and compare detectors.
  // Slice boundaries: [prevWakeIdx .. thisWakeIdx) — the search region the
  // scan used for this night.
  print('\n=== per-night detector breakdown ===');
  var prevWakeSec = sub.tsSec.first;
  for (final d in days) {
    if (d.sleep.window == null) continue;
    final wakeSec = d.sleep.window!.offsetMs! ~/ 1000; // THIS night's true wake
    final loIdx = _lb(sub.tsSec, prevWakeSec);
    final hiIdx = _lb(sub.tsSec, wakeSec);
    if (hiIdx - loIdx < 600) {
      prevWakeSec = wakeSec;
      continue;
    }
    final aSlice = accel.sublist(loIdx, hiIdx);
    final hSlice = hr.sublist(loIdx, hiIdx);
    final base = <double>[for (var i = 0; i < loIdx; i++) if (hr[i] > 0) hr[i]];
    final hrBaseline = base.length >= 60 ? base : null;

    print('\n── night ending in day ${d.date}  '
        'slice ${_ts(sub.tsSec[loIdx])} → ${_ts(sub.tsSec[hiIdx - 1])}  '
        '(${hiIdx - loIdx} s) ──');

    // A) van Hees ACCEL-ONLY
    final vh = ana.vanHeesSleepWindow(aSlice);
    final w = vh.value;
    if (w == null) {
      print('  vanHees: NO window (${vh.note})');
    } else {
      print('  vanHees(accel only): onset ${_t(w.onsetMs!)}  '
          'offset ${_t(w.offsetMs!)}  SPT ${_hrs(w.sptSec)}  '
          'conf ${vh.confidence.toStringAsFixed(2)}');

      // immobile-run structure (maximal true-runs ≥5min) + gaps between them
      final im = w.immobile;
      final runs = <List<int>>[]; // [startIdx, endIdxExclusive]
      var i = 0;
      while (i < im.length) {
        if (!im[i]) {
          i++;
          continue;
        }
        var j = i;
        while (j < im.length && im[j]) {
          j++;
        }
        if (j - i >= 300) runs.add([i, j]);
        i = j;
      }
      print('  immobile runs ≥5min: ${runs.length}');
      for (var r = 0; r < runs.length; r++) {
        final st = runs[r][0], en = runs[r][1];
        final gap = r > 0 ? st - runs[r - 1][1] : 0;
        print('    #${r + 1}  ${_t(aSlice[st].tsMs)} → '
            '${_t(aSlice[en - 1].tsMs)}  len ${_hrs(en - st)}'
            '${r > 0 ? "   (active gap before: ${(gap / 60).round()}m)" : ""}');
      }

      // B) HR-dip step (what segment.dart does inside the vanHees window)
      if (hrBaseline != null) {
        final baseValid = hrBaseline.where((h) => h > 0).toList();
        final baseMed = _median(baseValid);
        if (baseMed != null) {
          final thresh = 0.95 * baseMed;
          print('  HR-dip: daytime median ${baseMed.toStringAsFixed(1)}  '
              'thresh(0.95×) ${thresh.toStringAsFixed(1)} bpm');
          // first/last sustained ≥5min run below thresh within [onset,offset)
          int? firstDip, lastDip;
          var run = 0;
          for (var k = w.onsetIdx; k < w.offsetIdx; k++) {
            final h = k < hSlice.length ? hSlice[k] : 0.0;
            if (h > 0 && h < thresh) {
              run++;
              if (run >= 300) {
                firstDip ??= k - run + 1;
                lastDip = k;
              }
            } else {
              run = 0;
            }
          }
          if (firstDip == null) {
            print('  HR-dip: NO sustained 5-min run below thresh '
                '→ keeps accel window, conf×0.6');
          } else {
            print('  HR-dip: first sustained dip @${_t(aSlice[firstDip].tsMs)}  '
                'last @${_t(aSlice[lastDip!].tsMs)}  '
                '→ TRIMS onset ${_t(w.onsetMs!)} → ${_t(aSlice[firstDip].tsMs)}');
          }
        }
      } else {
        print('  HR-dip: no baseline (<60 pre-slice HR samples) → skipped');
      }
    }

    // C) segmentSleep FINAL (with HR-dip), the real result
    final seg = ana.segmentSleep(aSlice, hSlice, hrBaseline: hrBaseline);
    if (seg.present && seg.window != null) {
      final sw = seg.window!;
      print('  segmentSleep FINAL: onset ${_t(sw.onsetMs!)}  '
          'offset ${_t(sw.offsetMs!)}  TST ${_hrs(seg.tstSec!)}  '
          'WASO ${(seg.wasoSec! / 60).round()}m  eff ${seg.efficiencyPct!.round()}%');
    } else {
      print('  segmentSleep FINAL: ABSENT');
    }

    prevWakeSec = wakeSec;
  }
}
