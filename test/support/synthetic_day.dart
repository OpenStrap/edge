// A SYNTHETIC, PHYSIOLOGICALLY PLAUSIBLE DAY — one ground truth, rendered as
// every device would see it.
//
// Not anyone's physiology and not a capture: a deterministic model (seeded
// RNG) built so the analytics have something realistic to chew on and the
// test knows the right answer. One [SyntheticDay] owns the truth — a staged
// night, per-second heart rate, beat-to-beat RR with respiratory sinus
// arrhythmia, posture, a workout, steps, SpO2 and skin temperature — and
// renders it as:
//   * the primary band's 1 Hz decoded samples (what a WHOOP drain commits),
//   * a Colmi ring's history replies,
//   * an Ultrahuman ring's 32-byte records.
//
// The night: in bed 22:50, asleep 23:10, up 06:50 (local). Five ~90-min
// cycles, deep sleep front-loaded, REM back-loaded, two brief awakenings. A
// 40-min run at 17:30 the next day.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_edge/data/models.dart' show RawRecord, Sample;
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'garmin_watch.dart';

enum Stage { wake, light, deep, rem }

class SyntheticDay {
  /// The calendar day the night ENDS on — the day that gets derived.
  final DateTime day;

  SyntheticDay(this.day) {
    _build();
  }

  late final DateTime start = DateTime(day.year, day.month, day.day - 1, 18);
  late final DateTime end = DateTime(day.year, day.month, day.day, 22);
  late final DateTime inBed = DateTime(day.year, day.month, day.day - 1, 22, 50);
  late final DateTime sleepOnset =
      DateTime(day.year, day.month, day.day - 1, 23, 10);
  late final DateTime sleepOffset = DateTime(day.year, day.month, day.day, 6, 50);
  late final DateTime runStart = DateTime(day.year, day.month, day.day, 17, 30);
  late final DateTime runEnd = DateTime(day.year, day.month, day.day, 18, 10);

  static int sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

  // ── truth ────────────────────────────────────────────────────────────────
  final hr = <int, int>{}; // second -> bpm
  final rr = <int, List<int>>{}; // second -> beats ending in that second
  final accel = <int, (double, double, double)>{}; // second -> g
  final steps = <int, int>{}; // second -> steps in that second
  final stage = <int, Stage>{}; // second -> stage, only inside the night

  /// Minutes asleep (light + deep + rem) between onset and offset.
  late final int tstMin;

  /// Minutes of deep and of REM sleep in the truth hypnogram.
  int get deepMin => stage.values.where((s) => s == Stage.deep).length ~/ 60;
  int get remMin => stage.values.where((s) => s == Stage.rem).length ~/ 60;

  /// RMSSD (ms) over every in-sleep beat pair.
  late final double nightRmssd;

  /// Lowest 5-minute mean HR inside the night.
  late final double nightHrNadir;

  /// Breaths per minute while asleep.
  static const double sleepRespRate = 13.5;

  Stage _stageAt(int minuteIntoNight) {
    // (light, deep, light, rem) minutes per cycle.
    const cycles = [
      (20, 45, 10, 10),
      (20, 35, 10, 20),
      (25, 20, 15, 25),
      (30, 5, 15, 35),
      (30, 0, 10, 40),
    ];
    var m = minuteIntoNight;
    for (final (l1, d, l2, r) in cycles) {
      if (m < l1) return Stage.light;
      m -= l1;
      if (m < d) return Stage.deep;
      m -= d;
      if (m < l2) return Stage.light;
      m -= l2;
      if (m < r) return Stage.rem;
      m -= r;
    }
    return Stage.light;
  }

  void _build() {
    final rng = math.Random(20261004);
    double gauss() {
      final u = 1 - rng.nextDouble(), v = rng.nextDouble();
      return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
    }

    final t0 = sec(start), t1 = sec(end);
    final onset = sec(sleepOnset), offset = sec(sleepOffset);
    final bed = sec(inBed);
    final run0 = sec(runStart), run1 = sec(runEnd);
    // Brief awakenings: (start minute into night, minutes).
    const wakes = [(178, 4), (352, 6)];

    var drift = 0.0;
    var posture = (0.05, -0.98, 0.15); // lying on the back-ish
    var beatClockMs = t0 * 1000.0;
    var asleepSec = 0;
    final sleepBeats = <int>[];
    final hrMinute = <double>[];

    for (var t = t0; t < t1; t++) {
      drift = drift * 0.995 + gauss() * 0.15;
      Stage? st;
      if (t >= onset && t < offset) {
        final m = (t - onset) ~/ 60;
        st = _stageAt(m);
        for (final (ws, wl) in wakes) {
          if (m >= ws && m < ws + wl) st = Stage.wake;
        }
        stage[t] = st!;
        if (st != Stage.wake) asleepSec++;
      }

      // Heart rate.
      double h;
      if (st != null) {
        final progress = (t - onset) / (offset - onset);
        h = switch (st) {
              Stage.deep => 50.0,
              Stage.light => 54.0,
              Stage.rem => 59.0,
              Stage.wake => 64.0,
            } -
            3 * progress;
      } else if (t >= bed && t < onset) {
        h = 62;
      } else if (t >= run0 && t < run1 + 300) {
        final into = t - run0;
        h = into < 300
            ? 75 + 75 * into / 300
            : t < run1
                ? 150 + 4 * math.sin(into / 40)
                : 150 - 55 * (t - run1) / 300;
      } else {
        final hourOfDay = DateTime.fromMillisecondsSinceEpoch(t * 1000).hour;
        h = 70 + 5 * math.sin((hourOfDay - 10) / 24 * 2 * math.pi);
      }
      h += drift;
      hr[t] = h.round().clamp(40, 190);

      // Posture / acceleration.
      final asleep = st != null;
      if (asleep && (t - onset) % 5400 == 0 && t != onset) {
        // A posture change at each cycle boundary.
        posture = (rng.nextDouble() * 0.6 - 0.3, -0.9, rng.nextDouble() * 0.6 - 0.3);
      }
      final moving = asleep
          ? ((t - onset) % 5400 < 20 && t != onset) || st == Stage.wake
          : true;
      final amp = !moving
          ? 0.003
          : (t >= run0 && t < run1)
              ? 0.45
              : asleep
                  ? 0.05
                  : (t >= bed ? 0.01 : 0.08);
      final (gx, gy, gz) = asleep || t >= bed
          ? posture
          : (0.1 * math.sin(t / 900), -0.2, 0.97);
      accel[t] = (gx + gauss() * amp, gy + gauss() * amp, gz + gauss() * amp);

      // Steps: a walking minute every ~10 awake minutes, running cadence.
      if (!asleep && t < bed || t >= offset) {
        if (t >= run0 && t < run1) {
          steps[t] = 3; // ~170 spm
        } else if (!asleep && (t ~/ 60) % 10 == 0) {
          steps[t] = 2; // a brisk walking minute
        }
      }

      // Beats ending inside this second, with RSA.
      final resp = asleep ? sleepRespRate : 15.0;
      final rsaMs = switch (st) {
        Stage.deep => 38.0,
        Stage.light => 28.0,
        Stage.rem => 16.0,
        Stage.wake => 12.0,
        null => (t >= run0 && t < run1) ? 3.0 : 12.0,
      };
      final beats = <int>[];
      while (beatClockMs < (t + 1) * 1000) {
        final phase = 2 * math.pi * resp / 60 * (beatClockMs / 1000);
        final ms = (60000 / hr[t]! +
                rsaMs * math.sin(phase) +
                gauss() * (asleep ? 9 : 6))
            .round()
            .clamp(300, 1600);
        beatClockMs += ms;
        if (beatClockMs >= t * 1000) beats.add(ms);
      }
      rr[t] = beats;
      if (asleep && st != Stage.wake) sleepBeats.addAll(beats);
      if (asleep && (t - onset) % 60 == 0) hrMinute.add(hr[t]!.toDouble());
    }

    tstMin = asleepSec ~/ 60;
    var sq = 0.0;
    for (var i = 1; i < sleepBeats.length; i++) {
      final d = sleepBeats[i] - sleepBeats[i - 1];
      sq += d * d;
    }
    nightRmssd = math.sqrt(sq / (sleepBeats.length - 1));
    var nadir = 999.0;
    for (var i = 0; i + 5 <= hrMinute.length; i++) {
      final m = hrMinute.sublist(i, i + 5).reduce((a, b) => a + b) / 5;
      if (m < nadir) nadir = m;
    }
    nightHrNadir = nadir;
  }

  // ── renderings ───────────────────────────────────────────────────────────

  /// The primary band's decoded 1 Hz samples + their raw-record envelopes,
  /// in batches of [batch] seconds — what a WHOOP drain hands
  /// `LocalDb.commitSyncBatch`.
  Iterable<(List<RawRecord>, List<Sample>)> primaryBatches(
      {int batch = 3600}) sync* {
    final t0 = sec(start), t1 = sec(end);
    for (var b = t0; b < t1; b += batch) {
      final raws = <RawRecord>[];
      final samples = <Sample>[];
      for (var t = b; t < math.min(b + batch, t1); t++) {
        final counter = t - t0 + 1;
        raws.add(RawRecord(
          counter: counter,
          packetType: 0x2F,
          hex: 'synthetic${counter.toRadixString(16)}',
          capturedAt: t * 1000,
          recTs: t,
        ));
        final (ax, ay, az) = accel[t]!;
        samples.add(Sample(
          tsEpoch: t,
          counter: counter,
          hr: hr[t]!,
          rrIntervalsMs: rr[t]!,
          ax: ax,
          ay: ay,
          az: az,
        ));
      }
      yield (raws, samples);
    }
  }

  /// Truth for one local day: total steps.
  int stepsOn(DateTime d) {
    var n = 0;
    steps.forEach((t, s) {
      final x = DateTime.fromMillisecondsSinceEpoch(t * 1000);
      if (x.year == d.year && x.month == d.month && x.day == d.day) n += s;
    });
    return n;
  }

  /// The truth hypnogram as contiguous (startSec, endSec, stage) blocks.
  List<(int, int, Stage)> hypnogramBlocks() {
    final out = <(int, int, Stage)>[];
    final on = sec(sleepOnset), off = sec(sleepOffset);
    var s = on;
    for (var t = on + 1; t <= off; t++) {
      if (t == off || stage[t] != stage[s]) {
        out.add((s, t, stage[s]!));
        s = t;
      }
    }
    return out;
  }

  // ── Colmi rendering ──────────────────────────────────────────────────────

  /// A scripted Colmi ring holding this day, answering like the real wire.
  /// [now] is the sync instant (local).
  List<List<int>> colmiReply(List<int> w, DateTime now) {
    final cmd = w[0];
    DateTime dayAgo(int d) => DateTime(now.year, now.month, now.day - d);
    int bcd(int v) => ((v ~/ 10) << 4) | (v % 10);
    switch (cmd) {
      case kColmiCmdBattery:
        return [colmiFrame(cmd, [80])];
      case kColmiCmdActivityHistory:
        final d = dayAgo(w[1]);
        final slots = <int, int>{}; // quarter-hour -> steps
        steps.forEach((t, s) {
          final x = DateTime.fromMillisecondsSinceEpoch(t * 1000);
          if (x.year == d.year && x.month == d.month && x.day == d.day) {
            final q = x.hour * 4 + x.minute ~/ 15;
            slots[q] = (slots[q] ?? 0) + s;
          }
        });
        if (slots.isEmpty) return [colmiFrame(cmd, [0xff])];
        final keys = slots.keys.toList()..sort();
        return [
          colmiFrame(cmd, [0xf0]),
          for (var i = 0; i < keys.length; i++)
            colmiFrame(cmd, [
              bcd(d.year % 100), bcd(d.month), bcd(d.day), keys[i], i,
              keys.length, 0, 0, slots[keys[i]]! & 0xff,
              slots[keys[i]]! >> 8, 0, 0,
            ]),
        ];
      case kColmiCmdHrHistory:
        final ts = w[1] | (w[2] << 8) | (w[3] << 16) | (w[4] << 24);
        final probe = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
        final d = DateTime(probe.year, probe.month, probe.day);
        final values = <int>[];
        for (var slot = 0; slot < 288; slot++) {
          final at = sec(DateTime(d.year, d.month, d.day, 0, slot * 5));
          values.add(hr[at] ?? 0);
        }
        // Page 1 holds 9 slots after a 4-byte timestamp, later pages 13.
        final pages = <List<int>>[
          colmiFrame(cmd, [1, 0, 0, 0, 0, ...values.sublist(0, 9)]),
        ];
        for (var i = 9, p = 2; i < 288; i += 13, p++) {
          pages.add(colmiFrame(
              cmd, [p, ...values.sublist(i, math.min(i + 13, 288))]));
        }
        return [colmiFrame(cmd, [0, pages.length + 1]), ...pages];
      case kColmiCmdHrvHistory:
      case kColmiCmdStressHistory:
        final d = dayAgo(w[1]);
        final values = <int>[];
        for (var slot = 0; slot < 48; slot++) {
          final at = sec(DateTime(d.year, d.month, d.day, 0, slot * 30));
          final b = rr[at];
          values.add(b == null
              ? 0
              : cmd == kColmiCmdHrvHistory
                  ? (stage.containsKey(at) ? 45 : 30)
                  : (stage.containsKey(at) ? 15 : 35));
        }
        return [
          colmiFrame(cmd, [0, 5, 30]),
          colmiFrame(cmd, [1, w[1], ...values.sublist(0, 12)]),
          for (var p = 2, i = 12; p <= 4; p++, i += 13)
            colmiFrame(cmd, [p, ...values.sublist(i, math.min(i + 13, 48))]),
        ];
      case kColmiCmdBigData:
        switch (w[1]) {
          case kColmiBigSleep:
            final blocks = hypnogramBlocks();
            int code(Stage s) => switch (s) {
                  Stage.light => kColmiStageLight,
                  Stage.deep => kColmiStageDeep,
                  Stage.rem => kColmiStageRem,
                  Stage.wake => kColmiStageAwake,
                };
            final pairs = <int>[];
            for (final (a, b, s) in blocks) {
              var mins = (b - a) ~/ 60;
              while (mins > 0) {
                final m = math.min(mins, 255);
                pairs.addAll([code(s), m]);
                mins -= m;
              }
            }
            final startMin = sleepOnset.hour * 60 + sleepOnset.minute;
            final endMin = sleepOffset.hour * 60 + sleepOffset.minute;
            final daysAgo = DateTime(now.year, now.month, now.day)
                .difference(DateTime(day.year, day.month, day.day))
                .inDays;
            return [
              colmiBigDataRequest(kColmiBigSleep, [
                1, daysAgo, pairs.length + 4, startMin & 0xff, startMin >> 8,
                endMin & 0xff, endMin >> 8, ...pairs,
              ]),
            ];
          case kColmiBigSpo2:
            final daysAgo = DateTime(now.year, now.month, now.day)
                .difference(DateTime(day.year, day.month, day.day))
                .inDays;
            return [
              colmiBigDataRequest(kColmiBigSpo2, [
                daysAgo,
                for (var h = 0; h < 24; h++) ...(h < 7 ? [94, 98] : [96, 99]),
                if (daysAgo != 0) ...[0, for (var h = 0; h < 24; h++) ...[0, 0]],
              ]),
            ];
        }
        return const [];
    }
    return const [];
  }

  // ── Ultrahuman rendering ─────────────────────────────────────────────────

  /// One 32-byte record every 5 minutes across the whole window, at ring
  /// indices 1..n (the ring numbers from 1).
  List<List<int>> ultrahumanRecords() {
    final out = <List<int>>[];
    var index = 1;
    for (var t = sec(start); t < sec(end); t += 300, index++) {
      final b = ByteData(32);
      b.setUint32(0, t, Endian.little);
      b.setUint8(4, hr[t]!);
      b.setUint8(5, stage.containsKey(t) ? 48 : 32);
      b.setUint8(6, stage.containsKey(t) ? 96 : 98);
      b.setUint8(7, kUltrahumanHrQualityLegacy);
      b.setUint32(8, t, Endian.little);
      final skin = stage.containsKey(t) ? 35.2 : 33.6;
      b.setFloat32(12, skin, Endian.little);
      b.setFloat32(16, 22.0, Endian.little); // ambient
      b.setUint32(20, t, Endian.little);
      var s = 0;
      for (var k = t; k < t + 300; k++) {
        s += steps[k] ?? 0;
      }
      b.setUint16(26, s, Endian.little);
      b.setUint8(28, stage.containsKey(t) ? 38 : 89);
      b.setUint8(29, 1); // temperature quality
      b.setUint16(30, index, Endian.little);
      out.add(b.buffer.asUint8List());
    }
    return out;
  }

  /// A scripted Ultrahuman ring holding [ultrahumanRecords].
  List<List<int>> ultrahumanReply(List<int> w) {
    final records = ultrahumanRecords();
    List<int> resp(int op, int result, List<int> payload) =>
        [op, result, payload.length ~/ kUltrahumanRecordLen, ...payload, 0, 0];
    switch (w[0]) {
      case kUltrahumanOpGetEarliestIndex:
        return [resp(w[0], kUltrahumanResultOk, [1, 0])];
      case kUltrahumanOpGetLatestIndex:
        final last = records.length;
        return [resp(w[0], kUltrahumanResultOk, [last & 0xff, last >> 8])];
      case kUltrahumanOpGetRecordings:
        final from = (w[1] | (w[2] << 8)) - 1;
        if (from >= records.length) {
          return [resp(w[0], kUltrahumanResultEmpty, const [])];
        }
        final out = <List<int>>[];
        for (var i = from; i < records.length; i += 7) {
          final chunk = records.sublist(i, math.min(i + 7, records.length));
          out.add(resp(w[0], kUltrahumanResultOk, [for (final r in chunk) ...r]));
        }
        if ((records.length - from) % 7 == 0) {
          out.add(resp(w[0], kUltrahumanResultEmpty, const []));
        }
        return out;
    }
    return const [];
  }

  // ── Mi Band 2/3 rendering ────────────────────────────────────────────────

  List<int>? _miPending;

  /// A scripted Mi Band 2/3 answering the activity fetch (control and data
  /// characteristics) with one 4-byte record per minute of this day:
  /// kind (deep 11, light/REM 9, awake-in-night 12, else 1), intensity,
  /// steps, HR. Returns (characteristic, bytes) notifications.
  List<(String, List<int>)> miBandReply(String char, List<int> w, DateTime now) {
    if (char != kHuamiActivityControlChar) return const [];
    if (w[0] == 0x01 && w.length >= 10) {
      final since = DateTime(w[2] | (w[3] << 8), w[4], w[5], w[6], w[7]);
      final from = math.max(sec(since), sec(start));
      final to = math.min(sec(end), sec(now));
      final recs = <int>[];
      for (var t = from - from % 60; t + 60 <= to; t += 60) {
        final st = stage[t];
        final kind = switch (st) {
          Stage.deep => kHuamiKindDeepSleep,
          Stage.light || Stage.rem => kHuamiKindLightSleep,
          Stage.wake => 12,
          null => 1,
        };
        var s = 0;
        for (var k = t; k < t + 60; k++) {
          s += steps[k] ?? 0;
        }
        recs.addAll([kind, st == null ? 40 : 5, math.min(s, 255), hr[t]!]);
      }
      _miPending = recs;
      final first = DateTime.fromMillisecondsSinceEpoch(
          (from - from % 60) * 1000);
      final tz = (first.timeZoneOffset.inMinutes ~/ 15) & 0xff;
      final n = recs.length ~/ 4; // the header counts minute samples
      return [
        (kHuamiActivityControlChar, [
          0x10, 0x01, 0x01, n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, 0,
          first.year & 0xff, first.year >> 8, first.month, first.day,
          first.hour, first.minute, 0, tz,
        ]),
      ];
    }
    if (w.length == 1 && w[0] == 0x02) {
      final recs = _miPending ?? const <int>[];
      final out = <(String, List<int>)>[];
      for (var i = 0, c = 0; i < recs.length; i += 16, c++) {
        out.add((kHuamiActivityDataChar,
            [c & 0xff, ...recs.sublist(i, math.min(i + 16, recs.length))]));
      }
      out.add((kHuamiActivityControlChar, [0x10, 0x02, 0x01]));
      return out;
    }
    return const [];
  }

  // ── Garmin rendering ─────────────────────────────────────────────────────

  /// This day as a Garmin watch would store it: a monitoring FIT file (HR
  /// and cumulative walking steps each minute, resetting at local midnight),
  /// a sleep FIT file (one level record per stage change) and an HRV status
  /// file. Directory index -> (sub-type, file timestamp, bytes).
  Map<int, (int, int, Uint8List)> garminFiles() {
    final monitor = FitWriter()
      ..define(0, kFitMsgMonitoring,
          [(253, 4, 0x86), (5, 1, 0x00), (3, 4, 0x86), (27, 1, 0x02)]);
    var cycles = 0;
    DateTime? day;
    for (var t = sec(start); t < sec(end); t += 60) {
      final x = DateTime.fromMillisecondsSinceEpoch(t * 1000);
      final d = DateTime(x.year, x.month, x.day);
      if (d != day) {
        day = d;
        cycles = 0;
      }
      for (var k = t; k < t + 60; k++) {
        cycles += steps[k] ?? 0;
      }
      monitor.data(0, [...u32le(fitSec(t)), 6, ...u32le(cycles), hr[t]!]);
    }
    final sleep = FitWriter()
      ..define(0, kFitMsgSleepLevel, [(253, 4, 0x86), (0, 1, 0x00)]);
    for (final (a, _, st) in hypnogramBlocks()) {
      final level = switch (st) {
        Stage.wake => 1,
        Stage.light => 2,
        Stage.deep => 3,
        Stage.rem => 4,
      };
      sleep.data(0, [...u32le(fitSec(a)), level]);
    }
    // Night over: a record with no level ends the last stage.
    sleep.data(0, [...u32le(fitSec(sec(sleepOffset))), 0xff]);
    final hrv = FitWriter()
      ..define(0, kFitMsgHrvStatusSummary, [(253, 4, 0x86), (1, 2, 0x84)])
      ..data(0, [...u32le(fitSec(sec(sleepOffset))), ...u16le(45 * 128)]);
    return {
      1: (kGarminFitMonitor, sec(end), monitor.build()),
      2: (kGarminFitSleep, sec(sleepOffset), sleep.build()),
      3: (kGarminFitHrvStatus, sec(sleepOffset), hrv.build()),
    };
  }
}
