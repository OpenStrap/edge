import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import 'substrate.dart';

class PreparedDerivationDay {
  final String date;
  final int endSec;
  final double confidence;
  final List<String> flags;
  final Map<String, dynamic> sleepJson;
  final List<String> hypnoStages;
  final int sleepOnsetSec;
  final int sleepOffsetSec;
  final Substrate daySub;
  final Substrate sleepSub;

  const PreparedDerivationDay({
    required this.date,
    required this.endSec,
    required this.confidence,
    required this.flags,
    required this.sleepJson,
    required this.hypnoStages,
    required this.sleepOnsetSec,
    required this.sleepOffsetSec,
    required this.daySub,
    required this.sleepSub,
  });

  Map<String, dynamic> toJson() => {
    'date': date,
    'end_sec': endSec,
    'confidence': confidence,
    'flags': flags,
    'sleep_json': sleepJson,
    'hypno_stages': hypnoStages,
    'sleep_onset_sec': sleepOnsetSec,
    'sleep_offset_sec': sleepOffsetSec,
    'day_sub': daySub.toJson(),
    'sleep_sub': sleepSub.toJson(),
  };

  static PreparedDerivationDay fromJson(Map<String, dynamic> m) {
    List<String> strs(String k) =>
        ((m[k] as List?) ?? const []).map((e) => e.toString()).toList();
    return PreparedDerivationDay(
      date: m['date'] as String? ?? '',
      endSec: (m['end_sec'] as num?)?.toInt() ?? 0,
      confidence: (m['confidence'] as num?)?.toDouble() ?? 0,
      flags: strs('flags'),
      sleepJson: ((m['sleep_json'] as Map?) ?? const {})
          .cast<String, dynamic>(),
      hypnoStages: strs('hypno_stages'),
      sleepOnsetSec: (m['sleep_onset_sec'] as num?)?.toInt() ?? 0,
      sleepOffsetSec: (m['sleep_offset_sec'] as num?)?.toInt() ?? 0,
      daySub: Substrate.fromJson(
        ((m['day_sub'] as Map?) ?? const {}).cast<String, dynamic>(),
      ),
      sleepSub: Substrate.fromJson(
        ((m['sleep_sub'] as Map?) ?? const {}).cast<String, dynamic>(),
      ),
    );
  }
}

class PreparedDerivationPayload {
  final int dataNowSec;
  final List<PreparedDerivationDay> days;

  const PreparedDerivationPayload({
    required this.dataNowSec,
    required this.days,
  });

  Map<String, dynamic> toJson() => {
    'data_now_sec': dataNowSec,
    'days': [for (final day in days) day.toJson()],
  };

  static PreparedDerivationPayload fromJson(Map<String, dynamic> m) {
    final rows = ((m['days'] as List?) ?? const []);
    return PreparedDerivationPayload(
      dataNowSec: (m['data_now_sec'] as num?)?.toInt() ?? 0,
      days: [
        for (final row in rows)
          PreparedDerivationDay.fromJson(
            ((row as Map?) ?? const {}).cast<String, dynamic>(),
          ),
      ],
    );
  }
}

void derivationPrepareWorker(SendPort mainSendPort) {
  final port = ReceivePort();
  final state = _PrepareAccumulator();
  String? targetDay;
  mainSendPort.send(port.sendPort);
  port.listen((message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'page') {
      final frames = ((message['frames'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (frames.isNotEmpty) {
        final rr = ((message['rr'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        state.addDecodedPage(frames, rr);
        return;
      }
      final hexes = ((message['hexes'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      state.addRawPage(hexes);
      return;
    }
    if (type == 'config') {
      targetDay = message['target_day']?.toString();
      return;
    }
    if (type == 'finish') {
      try {
        final payload = prepareDerivationPayload(
          state.buildSubstrate(),
          targetDay: targetDay,
        );
        mainSendPort.send({'type': 'result', 'payload': payload.toJson()});
      } catch (e, st) {
        mainSendPort.send({'type': 'error', 'error': '$e\n$st'});
      } finally {
        port.close();
      }
    }
  });
}

@visibleForTesting
PreparedDerivationPayload prepareDerivationPayload(
  Substrate sub, {
  String? targetDay,
}) {
  if (sub.isEmpty || sub.lastTs == null) {
    return const PreparedDerivationPayload(dataNowSec: 0, days: []);
  }
  final days = <PreparedDerivationDay>[];
  for (final day in calendarDays(sub)) {
    if (targetDay != null && day.date != targetDay) continue;
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
                  : (s == ana.SleepStage.rem ? 'rem' : 'light'),
          ];
    final win = day.sleep.window;
    final onsetSec = win == null
        ? 0
        : (win.onsetMs != null
              ? (win.onsetMs! / 1000).round()
              : (sleepSub.firstTs ?? 0));
    final offsetSec = win == null
        ? 0
        : (win.offsetMs != null
              ? (win.offsetMs! / 1000).round() + 1
              : ((sleepSub.lastTs ?? -1) + 1));
    days.add(
      PreparedDerivationDay(
        date: day.date,
        endSec: day.endSec,
        confidence: day.confidence,
        flags: List<String>.from(day.flags),
        sleepJson: day.sleep.toJson(),
        hypnoStages: hypno,
        sleepOnsetSec: onsetSec,
        sleepOffsetSec: offsetSec,
        daySub: daySub,
        sleepSub: sleepSub,
      ),
    );
  }
  return PreparedDerivationPayload(dataNowSec: sub.lastTs!, days: days);
}

class _PrepareAccumulator {
  final List<int> tsSec = [];
  final List<int> hr = [];
  final List<double> rrTsMs = [];
  final List<double> rrMs = [];
  final List<double> ax = [];
  final List<double> ay = [];
  final List<double> az = [];
  final List<int> spo2Red = [];
  final List<int> spo2Ir = [];
  final List<int> skinTemp = [];

  void addRawPage(List<String> hexes) {
    if (hexes.isEmpty) return;
    final sub = decodeSubstrate(hexes);
    if (sub.isEmpty) return;
    tsSec.addAll(sub.tsSec);
    hr.addAll(sub.hr);
    rrTsMs.addAll(sub.rrTsMs);
    rrMs.addAll(sub.rrMs);
    ax.addAll(sub.ax);
    ay.addAll(sub.ay);
    az.addAll(sub.az);
    spo2Red.addAll(sub.spo2Red);
    spo2Ir.addAll(sub.spo2Ir);
    skinTemp.addAll(sub.skinTemp);
  }

  void addDecodedPage(
    List<Map<String, dynamic>> frames,
    List<Map<String, dynamic>> rrRows,
  ) {
    if (frames.isEmpty) return;
    final rrByCounter = <int, List<Map<String, dynamic>>>{};
    for (final row in rrRows) {
      final counter = (row['counter'] as num?)?.toInt();
      if (counter == null) continue;
      rrByCounter.putIfAbsent(counter, () => <Map<String, dynamic>>[]).add(row);
    }
    for (final row in frames) {
      final recTs = (row['rec_ts'] as num?)?.toInt();
      if (recTs == null || recTs <= 0) continue;
      tsSec.add(recTs);
      hr.add((row['hr'] as num?)?.toInt() ?? 0);
      ax.add((row['ax'] as num?)?.toDouble() ?? 0);
      ay.add((row['ay'] as num?)?.toDouble() ?? 0);
      az.add((row['az'] as num?)?.toDouble() ?? 0);
      spo2Red.add((row['spo2_red_raw'] as num?)?.toInt() ?? 0);
      spo2Ir.add((row['spo2_ir_raw'] as num?)?.toInt() ?? 0);
      skinTemp.add((row['skin_temp_raw'] as num?)?.toInt() ?? 0);
      final counter = (row['counter'] as num?)?.toInt();
      if (counter == null) continue;
      final beats = rrByCounter[counter];
      if (beats == null) continue;
      for (final beat in beats) {
        final rr = (beat['rr_ms'] as num?)?.toDouble();
        if (rr == null || rr <= 0) continue;
        rrTsMs.add((beat['rr_ts_ms'] as num?)?.toDouble() ?? recTs * 1000.0);
        rrMs.add(rr);
      }
    }
  }

  Substrate buildSubstrate() => Substrate(
    tsSec: tsSec,
    hr: hr,
    rrTsMs: rrTsMs,
    rrMs: rrMs,
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: spo2Red,
    spo2Ir: spo2Ir,
    skinTemp: skinTemp,
  );
}
