// A Bluetooth heart-rate strap on a wearable's day, shared by every
// wearable's synthetic test: optionally a 20-minute session at noon, and
// the night worn at rest. The same checks run on each column, so a strap
// does the same thing whatever wearable it sits beside.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

import 'synthetic_day.dart';

/// A strap at rest over `[from, to)`: beats around 1200 ms swinging with
/// breathing (a 4 s sine, +-30 ms) plus a small deterministic jitter, each
/// notification carrying the beats that ended in its second, RR in 1/1024 s
/// as the Heart Rate Measurement sends it. Returns the notifications and the
/// RMSSD of the intervals as sent.
(List<(int, List<int>)>, double) strapRestingBeats(int from, int to) {
  final bySec = <int, List<int>>{};
  final sent = <double>[];
  var ms = 0.0;
  var seed = 7;
  while (from + ms ~/ 1000 < to) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    final rr = 1200 + 30 * math.sin(2 * math.pi * ms / 4000) + seed % 11 - 5;
    final units = (rr * 1024 / 1000).round();
    ms += units * 1000 / 1024;
    sent.add(units * 1000 / 1024);
    bySec.putIfAbsent(from + ms ~/ 1000, () => []).add(units);
  }
  var ssd = 0.0;
  for (var i = 1; i < sent.length; i++) {
    ssd += (sent[i] - sent[i - 1]) * (sent[i] - sent[i - 1]);
  }
  return (
    [
      for (final MapEntry(key: t, value: rrs) in bySec.entries)
        (t, [0x10, 50, for (final r in rrs) ...[r & 0xff, r >> 8]]),
    ],
    math.sqrt(ssd / (sent.length - 1)),
  );
}

/// Wears strap [strapId] on [truth]'s day [dayId] of the active wearable:
/// overnight at rest, plus (with [session]) 20 minutes at 150 bpm at noon
/// recovering 30 bpm a minute. With its flag on, the night's HRV is ours off
/// the strap's beats, with the wearable's own value beside it when
/// [deviceHrv]; every beat-only number is stored as the strap's; a session
/// is ours at 1 Hz. Flag off again, the HRV row returns to what it was.
Future<void> checkStrapDay(
  String strapId,
  SyntheticDay truth,
  String dayId,
  Profile profile, {
  required bool deviceHrv,
  bool session = false,
}) async {
  Future<Map<String, Map<String, Object?>>> cells() async {
    await DerivationEngine().runDays(profile, {dayId}, force: true);
    return (await dayCells(dayId))!;
  }

  final hrvBefore = (await cells())['hrv']!['class'];
  expect(hrvBefore, deviceHrv ? 'device' : 'unavailable');

  await LocalDb.upsertDevice(id: strapId, adapterId: 'ble_hrs');
  final (night, rmssd) = strapRestingBeats(
      SyntheticDay.sec(truth.sleepOnset), SyntheticDay.sec(truth.sleepOffset));
  final start = SyntheticDay.sec(
      DateTime(truth.day.year, truth.day.month, truth.day.day, 12));
  final end = start + 20 * 60;
  int bpm(int t) =>
      t <= end ? 150 : (150 - 30 * (t - end) / 60).round().clamp(100, 150);
  await HrsLink.instance.ingestForTest(strapId, [
    ...night,
    if (session)
      for (var t = start; t <= end + kStrapTailSec; t++) (t, [0x00, bpm(t)]),
  ]);
  if (session) {
    await LocalDb.putSession({
      'id': '$strapId-session',
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'created_at': end,
    });
  }

  await useDevice(strapId, 'ble_hrs', true);
  final c = await cells();
  expect(c['hrv'],
      allOf(containsPair('class', 'ours'), containsPair('method', 'rr_strap')));
  expect(c['hrv']!['value'] as num, closeTo(rmssd, rmssd * 0.15),
      reason: 'the RMSSD of the beats the strap sent');
  expect(c['hrv']!.containsKey('device_value'), deviceHrv,
      reason: "the wearable's own HRV sits beside ours");
  // Every beat-only row is ours off the strap, whatever the wearable alone
  // serves: breathing at the beats' 4 s swing, 15 a minute.
  for (final row in ['respiratory_rate', 'stress', 'irregular_rhythm']) {
    expect(c[row],
        allOf(containsPair('class', 'ours'), containsPair('method', 'rr_strap')),
        reason: row);
  }
  expect(c['respiratory_rate']!['value'] as num, closeTo(15, 1));
  expect(c['irregular_rhythm']!['value'], 0, reason: 'a regular rhythm');
  if (session) {
    expect(c['workouts_with_strap'],
        allOf(containsPair('class', 'ours'), containsPair('value', 1),
            containsPair('method', 'hr_1hz')));
    expect(c['hrr'], containsPair('method', 'hr_1hz'));
    expect(c['hrr']!['value'] as num, closeTo(30, 3));
  }
  final stored = {
    for (final r in await (await LocalDb.instance).query('metric_method',
        where: 'date = ?', whereArgs: [dayId]))
      r['key'] as String: r['method'],
  };
  for (final k in ['rmssd', 'sdnn', ...kStrapBeatSeriesKeys]) {
    if (stored.containsKey(k)) expect(stored[k], 'rr_strap', reason: k);
  }
  expect(stored['rmssd'], 'rr_strap');
  if (session) expect(stored['hrr_tau_s'], 'hr_1hz');

  await useDevice(strapId, 'ble_hrs', false);
  expect((await cells())['hrv']!['class'], hrvBefore);
}
