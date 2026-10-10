// An Oura ring as the ACTIVE WEARABLE, no primary band at all: four synthetic
// days (test/support/synthetic_day.dart) synced through the real Oura link,
// derived by the real engine off the ring's heart rate, beats, temperature
// events and its own hypnogram, and served cell by cell as Oura's column of
// the metric x device table (lib/compute/inputs/oura_inputs.dart). Each cell must come back in
// its class (ours / device / estimated / unavailable) with a value the truth
// makes plausible.
//
// The ring is a script answering with frames hand-built to the layouts the
// protocol package's Oura wire format documents. It proves the wiring, not
// a real ring (rule R6).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ble/oura_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/oura_inputs.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/strap_day.dart' show strapRestingBeats;
import 'support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
final SyntheticDay _truth = _days.last;
const String _dayId = '2026-10-04';
const Set<String> _dayIds = {
  '2026-10-01',
  '2026-10-02',
  '2026-10-03',
  _dayId,
};
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
const String _ringId = 'oura-synthetic';
const List<int> _key = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];

Map _payload(Map<String, Object?> row) =>
    jsonDecode(row['payload_json'] as String) as Map;

List<int> _frame(int tag, List<int> payload) => [tag, payload.length, ...payload];

List<int> _u32(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

List<int> _event(int tag, int ds, List<int> body) =>
    _frame(tag, [..._u32(ds), ...body]);

/// The ring's 2-bit stage code for a truth stage.
int _code(Stage s) => switch (s) {
      Stage.deep => 0,
      Stage.light => 1,
      Stage.rem => 2,
      Stage.wake => 3,
    };

/// The ring's own RMSSD and SpO2 in the synthetic history.
const int _ringRmssd = 40, _ringSpo2 = 96;

/// The 14-byte beat body carrying six intervals, as the ring packs them.
List<int> _ibiBody(List<int> ibis) => [
      for (final i in ibis) i >> 3,
      for (final i in ibis) 0x80 | (i & 1),
      ((ibis[0] >> 1) & 3) << 6 |
          ((ibis[1] >> 1) & 3) << 4 |
          ((ibis[2] >> 1) & 3) << 2 |
          ((ibis[3] >> 1) & 3),
      ((ibis[4] >> 1) & 3) << 6 | ((ibis[5] >> 1) & 3) << 4,
    ];

/// The four days as one ring's history, in ring order: a clock anchor, a
/// temperature event every 5 minutes (finger skin while asleep, cooler
/// awake; the 4th night 1 °C over the three before it), a heart rate every
/// 5 minutes (a pair with the ring's RMSSD while asleep, a short burst
/// awake), SpO2 through each night, the 4th night's beats six to an event,
/// and each night's hypnogram as 52-epoch pages, each stamped at its end,
/// closed by a sleep-summary record that starts the next period.
List<List<int>> _history() {
  final t0 = SyntheticDay.sec(_days.first.start) - 60;
  int ds(int t) => 1000 + (t - t0) * 10;
  final events = <(int, List<int>)>[
    (ds(t0), _event(kOuraEvtTimeSync, ds(t0), _u32(t0))),
  ];
  for (var t = SyntheticDay.sec(_days.first.start);
      t < SyntheticDay.sec(_days.last.end);
      t += 300) {
    final night = _days.where((d) => d.stage.containsKey(t)).firstOrNull;
    final c = night == null
        ? 3360
        : 3520 + 10 * (night.day.day % 3) + (night == _truth ? 100 : 0);
    events.add((ds(t), _event(kOuraEvtTempPeriod, ds(t), [c & 0xff, c >> 8])));
    final d = _days.lastWhere((d) => d.hr.containsKey(t));
    if (night == null) {
      final a = ds(t + 150);
      events.add((a, _event(kOuraEvtAohr, a, [1, 0, 2, d.hr[t]!, 1, d.hr[t]!, 1])));
    } else {
      var sum = 0;
      for (var k = t; k < t + 300; k++) {
        sum += d.hr[k]!;
      }
      final end = ds(t + 299);
      events.add((end, _event(kOuraEvtHrv, end, [sum ~/ 300, _ringRmssd])));
      events.add((end + 1,
          _event(kOuraEvtSpo2, end + 1, [0, _ringSpo2, _ringSpo2, 0xff])));
    }
  }
  final beats = <int>[];
  for (var t = SyntheticDay.sec(_truth.sleepOnset);
      t < SyntheticDay.sec(_truth.sleepOffset);
      t++) {
    for (final ms in _truth.rr[t]!) {
      beats.add(ms);
      if (beats.length < 6) continue;
      // Never on a second another reading holds: rows are one per second.
      if (!const {0, 150, 299}.contains((t - t0 - 60) % 300)) {
        events.add((ds(t) + 2,
            _event(kOuraEvtIbiAmplitude, ds(t) + 2, _ibiBody(beats))));
      }
      beats.clear();
    }
  }
  for (final d in _days) {
    final on = SyntheticDay.sec(d.sleepOnset);
    final n = (SyntheticDay.sec(d.sleepOffset) - on) ~/ 120 * 4;
    final codes = [for (var i = 0; i < n; i++) _code(d.stage[on + 30 * i]!)];
    for (var page = 0; page * 52 < n; page++) {
      final c = codes.skip(page * 52).take(52).toList();
      final end = on + (page * 52 + c.length) * 30;
      events.add((
        ds(end),
        _event(kOuraEvtSleepPhaseData, ds(end), [
          page,
          for (var i = 0; i < c.length; i += 4)
            c[i] << 6 | c[i + 1] << 4 | c[i + 2] << 2 | c[i + 3],
        ]),
      ));
    }
    final close = ds(on + n * 30) + 1;
    events.add((close, _event(kOuraEvtSleepSummary1, close, const [])));
  }
  events.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final e in events) e.$2];
}

/// A ring that authenticates and serves [history] 200 events a batch, one
/// batch per history request.
List<List<int>> Function(int, List<int>) _ring(List<List<int>> history) {
  var next = 0;
  List<int> summary(int n, int left) =>
      _frame(0x11, [n, 0, ..._u32(left)]);
  return (_, w) {
    if (w[0] == 0x2f && w[2] == 0x2b) {
      return [_frame(0x2f, [0x2c, ...List.filled(15, 7)])];
    }
    if (w[0] == 0x2f && w[2] == 0x2d) return [_frame(0x2f, [0x2e, 0])];
    if (w[0] != 0x10) return const [];
    final batch = history.skip(next).take(200).toList();
    next += batch.length;
    return [...batch, summary(batch.length, history.length - next)];
  };
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'synthetic_oura_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: _ringId,
        adapterId: kOuraFamily,
        remoteId: 'AA:BB:CC:00:00:07',
        label: 'oura');
    final now = SyntheticDay.sec(DateTime(2026, 10, 4, 22, 30));
    await OuraLink.instance
        .ingestForTest(_ringId, _key, _ring(_history()), nowSeconds: () => now);
  });

  tearDownAll(() async => LocalDb.close());

  test('the sync banks the temperature and the four nights', () async {
    final db = await LocalDb.instance;
    final temps = await db.rawQuery(
        "SELECT COUNT(*) AS n FROM decoded_onehz WHERE device_id = '$_ringId' "
        'AND skin_temp_c > 0 AND hr IS NULL');
    expect((temps.first['n'] as num).toInt(), greaterThan(1000));
    final from = SyntheticDay.sec(DateTime(2026, 10, 4, 1));
    final sub = await ouraSubstrate(_ringId, from, from + 3599);
    expect(sub.tsSec.length, 12, reason: 'one heart rate every 5 minutes');
    expect(sub.skinTemp.toSet(), {3630}, reason: 'asleep, the 4th night');
    expect(sub.hr.every((h) => h >= 40 && h <= 70), isTrue,
        reason: 'asleep: ${sub.hr}');
    expect(sub.rrMs.length, greaterThan(2000),
        reason: "an hour of the 4th night's beats");
    expect((await LocalDb.vendorSleepNights(from - 86400, from + 86400)),
        isNotEmpty);
  });

  test('flag off: the ring moves no number and serves no column', () async {
    expect(await LocalDb.lastDecodedRecTs(), isNull, reason: 'no WHOOP rows');
    await LocalDb.setCursor(kActiveWearableCursor, _ringId);
    // Rule R6: not even its own hypnogram stages the night it alone saw.
    expect(
        await DerivationEngine().runDays(_profile, {_dayId}, force: true), 0);
    expect(await LocalDb.dayResult(_dayId), isNull);
    expect(await dayCells(_dayId), isNull);
  });

  test('flag on: every Oura cell derives, stores and serves in its class',
      () async {
    await LocalDb.setCursor(wearableEnabledCursor(kOuraFamily), '1');
    for (var i = 0; i < 2; i++) {
      expect(
          await DerivationEngine().runDays(_profile, _dayIds, force: true), 4);
    }
    final cells = (await dayCells(_dayId))!;
    // ignore: avoid_print
    print(const JsonEncoder.withIndent('  ').convert(cells));
    String cls(String row) => cells[row]!['class'] as String;
    num v(String row) => cells[row]!['value'] as num;

    expect({for (final r in cells.keys) r: cls(r)}, {
      'sleep_window': 'ours',
      'efficiency_awakenings': 'ours',
      'sleep_stages': 'device',
      'naps': 'unavailable',
      'sleep_debt_need_sri': 'ours',
      'resting_hr': 'ours',
      'nadir_dip': 'ours',
      'hrv': 'ours',
      'respiratory_rate': 'ours',
      'spo2': 'device',
      'stress': 'ours',
      'skin_temp': 'ours',
      'readiness': 'estimated',
      'irregular_rhythm': 'unavailable',
      'steps': 'unavailable',
      'strain': 'unavailable',
      'calories': 'unavailable',
      'movement': 'unavailable',
      'auto_workouts': 'unavailable',
      'workouts_with_strap': 'unavailable',
      'hrr': 'unavailable',
      'baselines_load_illness': 'ours',
      'circadian': 'ours',
    });
    for (final r in cells.keys) {
      if (cls(r) == 'unavailable') {
        expect(cells[r]!['reason'], isNotEmpty, reason: r);
      }
    }
    for (final r in ['steps', 'movement', 'naps', 'strain', 'calories']) {
      expect(cells[r]!['reason'], Why.notDecoded.name, reason: r);
    }

    // Ours off its 5-minute HR, as on the other rings.
    expect(cells['resting_hr']!['method'], 'hr_5min');
    expect((v('resting_hr') - _truth.nightHrNadir).abs(), lessThanOrEqualTo(6));
    expect(v('nadir_dip'), inInclusiveRange(40, v('resting_hr')));
    expect(v('baselines_load_illness'), closeTo(v('resting_hr'), 3));
    expect(v('circadian'), inInclusiveRange(0, 24));
    expect(cells['readiness']!['method'], 'rhr_only_partial');

    // HRV, respiration and stress ours off the ring's own beats; its own
    // RMSSD over the night beside ours, and its SpO2 labelled as its.
    expect(cells['hrv']!['method'], kRrRingMethod);
    expect(v('hrv'), closeTo(_truth.nightRmssd, _truth.nightRmssd * 0.15),
        reason: 'the RMSSD of the beats the ring sent');
    expect(cells['hrv']!['device_value'], _ringRmssd);
    expect(cells['respiratory_rate']!['method'], kRrRingMethod);
    expect(v('respiratory_rate'), closeTo(SyntheticDay.sleepRespRate, 1.5));
    expect(cells['stress']!['method'], kRrRingMethod);
    expect(v('spo2'), _ringSpo2);

    // The night is the ring's own hypnogram, our HR-led window beside it;
    // efficiency is ours off the ring's stages.
    final full = _payload((await LocalDb.dayResult(_dayId))!);
    expect(full['sleep_source'], 'vendor_staged');
    expect(full['device_family'], kOuraFamily);
    final night = _truth.sleepOffset.difference(_truth.sleepOnset).inMinutes;
    expect(cells['sleep_window']!['method'], 'hr_5min');
    expect(v('sleep_window'), (full['hr_sleep_window'] as Map)['in_bed_min']);
    expect(((cells['sleep_window']!['device_value'] as num) - night).abs(),
        lessThanOrEqualTo(1), reason: 'onset to wake, at 30-second epochs');
    expect((v('sleep_window') - night).abs(), lessThanOrEqualTo(25 + 20));
    expect(cells['efficiency_awakenings']!['method'], 'device_stages');
    expect(v('efficiency_awakenings'),
        closeTo(100 * _truth.tstMin / night, 0.5));
    expect((v('sleep_stages') - _truth.deepMin).abs(), lessThanOrEqualTo(1),
        reason: "the ring's deep minutes, at 30-second epochs");
    expect(v('sleep_debt_need_sri'), inInclusiveRange(0, 2));
    final xm = await crossDayAsOf(_dayId);
    expect(((xm['regularity'] as Map)['value'] as Map)['sri'], 100);

    // Skin temperature: ours, the deviation off the ring's own nights.
    expect(cells['skin_temp']!['method'], kOuraSkinMethod);
    // Nights 1-3 at 35.30, 35.40, 35.20 °C (sample SD 0.10), the 4th at
    // 36.30: one degree over the mean, ten SDs.
    expect(v('skin_temp'), closeTo(10, 0.05),
        reason: 'the 4th night is 100 centi-°C over a mean with SD 10');
    expect(cells['skin_temp']!['provisional'], isTrue);
    final sc = full['scalars'] as Map;
    expect(sc['skin_temp_adc'], closeTo(3630, 5),
        reason: "the night's readings, one at the window's edge awake");
    expect(sc['worn_min'], greaterThan(20 * 60),
        reason: 'a reading every 5 minutes, all day, is a day worn');
    expect(sc['skin_temp_coverage_frac'], closeTo(1, 0.02),
        reason: 'a reading every 5 minutes covers the night');
    expect(
        ((full['baselines'] as Map)['skin_temp'] as Map)['baseline'] as num,
        closeTo(3530, 5),
        reason: 'centi-°C, a weighted fold of 3530, 3540, 3520 (the night '
            'itself, 3630, is not in it)');

    // Every stored metric says how it was made, and a row the column marks
    // unavailable is never stored as ours.
    final stored = await (await LocalDb.instance)
        .query('metric_method', where: 'date = ?', whereArgs: [_dayId]);
    final methods = {for (final r in stored) r['key'] as String: r['family']};
    final classes = {for (final r in stored) r['key'] as String: r['class']};
    expect(methods, isNotEmpty);
    expect(methods.values.toSet().difference({'hr_5min', 'device'}), isEmpty);
    for (final MapEntry(:key, :value) in classes.entries) {
      final c = kOuraColumn[kSeriesKeyRow[key]];
      if (c != null &&
          c.ours == null &&
          c.device == null &&
          c.estimated == null) {
        expect(value, 'unavailable', reason: key);
      }
    }
    for (final k in ['strain', 'calories', 'irregular_rhythm_flag']) {
      if (classes.containsKey(k)) expect(classes[k], 'unavailable', reason: k);
    }
    expect(classes['rhr'], 'ours');
    expect(classes['skin_temp_z'], 'ours');
    expect(classes['tst_min'], 'device');
    final how = {for (final r in stored) r['key'] as String: r['method']};
    expect(how['rmssd'], kRrRingMethod);
    expect(how['resp_rate'], kRrRingMethod);

    // The day timeline: one row per stage over the staged night (not one
    // per hypnogram page), and the ring's night RMSSD as its column serves.
    final rows = await timelineObservations(
        await LocalDb.observationsForDay(_dayId),
        date: _dayId);
    final ring = [for (final r in rows) if (r['device_id'] == _ringId) r];
    final keys = [for (final r in ring) r['vendor_key']];
    expect(keys.where((k) => k == 'sleep_deep_min').length, 1, reason: '$keys');
    expect(keys.where((k) => k == 'hrv_avg').length, 1, reason: '$keys');
    num row(String k) => ring.firstWhere((r) => r['vendor_key'] == k)['value']
        as num;
    expect((row('sleep_deep_min') - _truth.deepMin).abs(), lessThanOrEqualTo(1));
    expect(row('hrv_avg'), cells['hrv']!['device_value']);
    expect(row('spo2_avg'), _ringSpo2);
    // A nap waking on the same date is a period of its own, not the night
    // the derive staged: the timeline's stage rows stay the cells'.
    final nap = SyntheticDay.sec(
        DateTime(_truth.day.year, _truth.day.month, _truth.day.day, 14));
    await LocalDb.putVendorSleepEpochs([VendorEpoch(nap, nap + 1800, 'deep')],
        deviceId: _ringId, source: 'oura');
    final withNap = await timelineObservations(
        await LocalDb.observationsForDay(_dayId),
        date: _dayId);
    expect(
        withNap.firstWhere((r) =>
            r['device_id'] == _ringId &&
            r['vendor_key'] == 'sleep_deep_min')['value'],
        row('sleep_deep_min'));
    await (await LocalDb.instance).delete('vendor_sleep_epoch',
        where: 'device_id = ? AND start_ts >= ?', whereArgs: [_ringId, nap]);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a strap's session on the ring's day is ours at 1 Hz; the night's "
      "HRV stays the ring's own beats", () async {
    const strapId = 'hrs-oura-session';
    await LocalDb.upsertDevice(id: strapId, adapterId: 'ble_hrs');
    final start = SyntheticDay.sec(
        DateTime(_truth.day.year, _truth.day.month, _truth.day.day, 12));
    final end = start + 20 * 60;
    int bpm(int t) =>
        t <= end ? 150 : (150 - 30 * (t - end) / 60).round().clamp(100, 150);
    await HrsLink.instance.ingestForTest(strapId, [
      for (var t = start; t <= end + kStrapTailSec; t++) (t, [0x00, bpm(t)]),
    ]);
    await LocalDb.putSession({
      'id': '$strapId-session',
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'created_at': end,
    });
    Future<Map<String, Map<String, Object?>>> cells() async {
      await DerivationEngine().runDays(_profile, {_dayId}, force: true);
      return (await dayCells(_dayId))!;
    }

    await useDevice(strapId, 'ble_hrs', true);
    final c = await cells();
    expect(c['workouts_with_strap'],
        allOf(containsPair('class', 'ours'), containsPair('value', 1),
            containsPair('method', 'hr_1hz')));
    expect(c['hrr'], containsPair('method', 'hr_1hz'));
    expect(c['hrr']!['value'] as num, closeTo(30, 3));
    expect(c['hrv'], containsPair('method', kRrRingMethod));
    await useDevice(strapId, 'ble_hrs', false);
    expect((await cells())['workouts_with_strap']!['class'], 'unavailable');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("a strap worn on a night the ring sent no beats owns that night's "
      'beat rows, and they say so', () async {
    const strapId = 'hrs-oura-night';
    const night3 = '2026-10-03';
    final truth3 = _days[2];
    await LocalDb.upsertDevice(id: strapId, adapterId: 'ble_hrs');
    final (beats, _) = strapRestingBeats(SyntheticDay.sec(truth3.sleepOnset),
        SyntheticDay.sec(truth3.sleepOffset));
    await HrsLink.instance.ingestForTest(strapId, beats);
    Future<Map<String, Map<String, Object?>>> cells(String d) async {
      await DerivationEngine().runDays(_profile, {d}, force: true);
      return (await dayCells(d))!;
    }

    await useDevice(strapId, 'ble_hrs', true);
    final c = await cells(night3);
    for (final r in ['hrv', 'respiratory_rate', 'stress']) {
      expect(c[r], containsPair('method', kRrStrapMethod), reason: r);
    }
    final how = {
      for (final r in await (await LocalDb.instance).query('metric_method',
          where: 'date = ?', whereArgs: [night3]))
        r['key'] as String: r['method'],
    };
    expect(how['rmssd'], kRrStrapMethod);
    expect(how['resp_rate'], kRrStrapMethod);
    // The 4th night's beats are still the ring's own.
    expect((await cells(_dayId))['hrv'], containsPair('method', kRrRingMethod));
    // Never a promise the strap cannot keep on this ring.
    expect(c['irregular_rhythm']!['reason'], Why.beatsNotSeparated.name);

    await useDevice(strapId, 'ble_hrs', false);
    expect((await cells(night3))['hrv']!['method'], isNot(kRrStrapMethod));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the ring off, or another wearable active, takes its days away; '
      'made active again, they derive again', () async {
    expect(await LocalDb.dayResult(_dayId), isNotNull);
    final db = await LocalDb.instance;
    Future<void> cleared() async {
      for (final d in _dayIds) {
        expect(await LocalDb.dayResult(d), isNull, reason: d);
        for (final t in const ['metric_series', 'metric_method']) {
          expect(await db.query(t, where: 'date = ?', whereArgs: [d]),
              isEmpty, reason: '$t $d');
        }
      }
      // Rule R6 after served days too: a forced pass stages nothing off the
      // ring's banked hypnogram.
      expect(await DerivationEngine().runDays(_profile, _dayIds, force: true),
          0);
      expect(await dayCells(_dayId), isNull);
    }

    expect(await setWearableEnabled(kOuraFamily, false), containsAll(_dayIds));
    await cleared();

    // Flag back on, but another wearable is the active one.
    await LocalDb.setCursor(wearableEnabledCursor(kOuraFamily), '1');
    expect(await DerivationEngine().runDays(_profile, _dayIds, force: true), 4);
    await LocalDb.upsertDevice(
        id: 'garmin-other', adapterId: 'garmin', label: 'garmin');
    expect(await setActiveWearable('garmin-other'), containsAll(_dayIds));
    await cleared();

    expect(await setActiveWearable(_ringId), containsAll(_dayIds));
    // Twice, as above: the second pass reads the nights the first stored.
    for (var i = 0; i < 2; i++) {
      expect(
          await DerivationEngine().runDays(_profile, _dayIds, force: true), 4);
    }
    final cells = (await dayCells(_dayId))!;
    expect(cells['skin_temp']!['class'], 'ours');
    expect(cells['sleep_stages']!['class'], 'device');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('the pairing screen lists what the ring unlocks', () {
    final caps = capabilities(columnFor(kOuraFamily)!);
    expect(caps['skin_temp'], MetricClass.ours);
    expect(caps['sleep_stages'], MetricClass.device);
    expect(caps['resting_hr'], MetricClass.ours);
    expect(caps['hrv'], MetricClass.ours);
    expect(caps['spo2'], MetricClass.device);
    expect(caps['steps'], MetricClass.unavailable);
  });
}
