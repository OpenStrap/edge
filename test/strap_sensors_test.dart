// Workout sensors (a Bluetooth heart-rate strap, a Polar sensor, a Coros
// watch) as session sources: how their beats are timed when they arrive,
// which sensor a session is when two are worn, what a session read keeps
// around a strap put on late, and that a derive loads the sensor flags
// itself.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/ultrahuman_inputs.dart'
    show kUltrahumanFamily;
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart'
    show WearableDisplay;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

/// Hands the host [samples] as one batch, as a sensor's adapter would.
class _Feed extends BandAdapter {
  const _Feed(this.entry, this.samples);
  @override
  final BandEntry entry;
  final List<NeutralSample> samples;
  @override
  Map<InputSignal, Duration> get signals => const {};
  @override
  Stream<BandEvent> run(BandLink link) async* {
    yield SampleBatch(samples);
  }
}

/// Banks [samples] as [entry]'s, through the real host.
Future<void> _bank(BandEntry entry, List<NeutralSample> samples) async {
  final host = BandHost(adapter: _Feed(entry, samples), deviceId: entry.id);
  await host.run(ReplayBandLink());
  await host.stop();
}

NeutralSample _s(int t, {int? hr, List<int> rr = const []}) => NeutralSample(
    anchor: TimeAnchor.arrival, tsEpoch: t, hr: hr, rrMs: rr);

/// A wearable's sparse day: [hr] at each of [ts], nothing else.
Substrate _sparse(List<int> ts, int hr, {String? family}) => Substrate(
      tsSec: ts,
      hr: List.filled(ts.length, hr),
      rrTsMs: const [],
      rrMs: const [],
      ax: List.filled(ts.length, 0),
      ay: List.filled(ts.length, 0),
      az: List.filled(ts.length, 0),
      spo2Red: List.filled(ts.length, 0),
      spo2Ir: List.filled(ts.length, 0),
      skinTemp: List.filled(ts.length, 0),
      skinContact: List.filled(ts.length, 0),
      deviceFamily: family,
    );

const int _t0 = 1_800_000_040;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'strap_sensors_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    LocalDb.sessionSensorSources = const {};
    LocalDb.sessionWearableSource = null;
  });

  tearDown(() async {
    LocalDb.sessionSensorSources = const {};
    LocalDb.sessionWearableSource = null;
    await LocalDb.close();
  });

  test('beats sent one per sample in one second keep their own times',
      () async {
    await _bank(kPolarPmd, [
      for (final rr in const [810, 820, 790, 805]) _s(_t0, hr: 74, rr: [rr]),
    ]);
    final rr = await (await LocalDb.instance)
        .query('decoded_rr', orderBy: 'beat_index');
    final ends = [for (final r in rr) r['beat_ts_ms'] as int];
    expect(ends, hasLength(4));
    for (var i = 1; i < ends.length; i++) {
      expect(ends[i] - ends[i - 1], rr[i]['rr_ms'],
          reason: 'each beat ends one interval after the one before');
    }
    expect(ends.last, _t0 * 1000 + 500, reason: 'anchored on the arrival');
  });

  test('a beat after a flagged or dropped record is not stamped early',
      () async {
    // The middle record's interval was not banked, but its time passed: the
    // next beat ends two intervals after the first, so the HRV gap check
    // sees the hole instead of two contiguous beats.
    await _bank(kPolarPmd, [
      _s(_t0, hr: 74, rr: [800]),
      _s(_t0, hr: 74),
      NeutralSample(
          anchor: TimeAnchor.arrival,
          tsEpoch: _t0,
          hr: 74,
          rrMs: const [800],
          gapMs: 800),
    ]);
    final rr = await (await LocalDb.instance)
        .query('decoded_rr', orderBy: 'beat_index');
    final ends = [for (final r in rr) r['beat_ts_ms'] as int];
    expect(ends, hasLength(2));
    expect(ends[1] - ends[0], 1600);
  });

  test('a late chain re-anchored never starts before the last beat', () async {
    // Fast beats arriving faster than the arrival second allows: anchored on
    // the arrival alone, the second notification's first beat would end
    // before the first notification's last one, and a time-ordered read
    // would interleave the two.
    await _bank(kBleHrs, [
      _s(_t0, hr: 150, rr: [800, 800]),
      _s(_t0 + 1, hr: 150, rr: [800, 800, 800]),
    ]);
    final rr = await (await LocalDb.instance)
        .query('decoded_rr', orderBy: 'rr_ts_ms, beat_index');
    final ends = [for (final r in rr) r['beat_ts_ms'] as int];
    expect(ends, hasLength(5));
    for (var i = 1; i < ends.length; i++) {
      expect(ends[i] - ends[i - 1], rr[i]['rr_ms']);
    }
  });

  test('a Coros watch gets no developer toggle; the straps do', () async {
    // No workout arms a Coros watch, so its flag feeds no number.
    for (final e in [kCoros, kBleHrs, kPolarPmd]) {
      await LocalDb.upsertDevice(
          id: '${e.id}-1', adapterId: e.id, remoteId: '${e.id}-r');
    }
    addTearDown(() => WearableDisplay.instance.devices = const []);
    await WearableDisplay.instance.loadDevices();
    expect(WearableDisplay.instance.devices.map((d) => d.adapter).toSet(),
        {kBleHrs.id, kPolarPmd.id});
  });

  test('two sensors worn together are never blended', () async {
    LocalDb.sessionSensorSources = {kBleHrs.id, kPolarPmd.id};
    await _bank(kBleHrs, [
      for (var t = _t0; t <= _t0 + 600; t++) _s(t, hr: 150, rr: [400]),
    ]);
    await _bank(kPolarPmd, [
      for (var t = _t0 + 100; t <= _t0 + 200; t++) _s(t, hr: 100, rr: [600]),
    ]);
    await LocalDb.putSession({
      'id': 'both',
      'start_ts': _t0,
      'end_ts': _t0 + 600,
      'type': 'run',
      'status': 'done',
      'created_at': _t0 + 600,
    });
    final sub = await withStrapSessions(
        _sparse([_t0 - 600, _t0 + 1200], 70), _t0 - 3600, _t0 + 3600);
    expect({for (var i = 0; i < sub.length; i++) sub.hr[i]}, {70, 150},
        reason: "the session is the strap that recorded most of it");
    expect(sub.rrMs.toSet(), {400},
        reason: "one sensor's beats, never the two interleaved");
    final stats = (await LocalDb.sessionHrStats(_t0 - 1, _t0 + 1))['both']!;
    expect(stats['min_hr'], 150, reason: 'the workout card agrees');
  });

  test('a strap put on late leaves the minutes before it to the wrist',
      () async {
    LocalDb.sessionSensorSources = {kBleHrs.id};
    LocalDb.sessionWearableSource = kGarmin.id;
    await _bank(kGarmin, [
      for (var t = _t0; t <= _t0 + 1200; t += 60) _s(t, hr: 90),
    ]);
    await _bank(kBleHrs, [
      for (var t = _t0 + 600; t <= _t0 + 1200; t++) _s(t, hr: 150),
    ]);
    await LocalDb.putSession({
      'id': 'late',
      'start_ts': _t0,
      'end_ts': _t0 + 1200,
      'type': 'run',
      'status': 'done',
      'created_at': _t0 + 1200,
    });
    final rows = await LocalDb.hrSamplesInRange(_t0, _t0 + 1200);
    expect([for (final r in rows) if (r['hr'] == 90) r['rec_ts']],
        [for (var t = _t0; t < _t0 + 600; t += 60) t],
        reason: "the watch's minutes before the strap's first second only");
    expect(rows.where((r) => r['hr'] == 150), hasLength(601));
    final stats = (await LocalDb.sessionHrStats(_t0 - 1, _t0 + 1))['late']!;
    expect(stats['n'], 611);
    expect(stats['min_hr'], 90);
    expect((await LocalDb.sessionHrSamplesBySession(_t0 - 1, _t0 + 1))['late'],
        hasLength(611));
    // The derive lays the same split over the watch's day.
    final sub = await withStrapSessions(
        _sparse([for (var t = _t0; t <= _t0 + 1200; t += 60) t], 90),
        _t0 - 3600,
        _t0 + 3600);
    expect(sub.length, 611);
  });

  test("a strap's scored session serves no score once its flag is off",
      () async {
    LocalDb.sessionSensorSources = {kBleHrs.id};
    await _bank(kBleHrs, [
      for (var t = _t0; t <= _t0 + 600; t++) _s(t, hr: 150),
    ]);
    await LocalDb.putSession({
      'id': 'strap',
      'start_ts': _t0,
      'end_ts': _t0 + 600,
      'type': 'run',
      'status': 'done',
      'calories': 120.0,
      'strain': 9.5,
      'max_hr': 150,
      'avg_hr': 150,
      'vo2max_estimate': 48.0,
      'hrr_bpm': 30,
      'trace_json': '[]',
      'created_at': _t0 + 600,
    });
    Future<Map<String, dynamic>> served() async =>
        (await LocalDb.sessionsInRange(_t0 - 1, _t0 + 1)).single;
    Future<Map<String, dynamic>> viewed() async {
      await LocalDb.refreshSessionScoreMask();
      return (await (await LocalDb.instance)
              .rawQuery('SELECT * FROM v_sessions'))
          .single;
    }

    expect((await served())['calories'], 120.0);
    expect((await viewed())['strain'], 9.5);
    LocalDb.sessionSensorSources = const {};
    final off = await served();
    for (final c in [
      'calories',
      'strain',
      'max_hr',
      'avg_hr',
      'vo2max_estimate',
      'trace_json',
    ]) {
      expect(off[c], isNull, reason: '$c: flag off, nothing of the strap');
    }
    // The coach's SQL and the CSV export read v_sessions, not sessionsInRange.
    final view = await viewed();
    for (final c in ['calories', 'strain', 'max_hr', 'hrr_bpm']) {
      expect(view[c], isNull, reason: 'v_sessions $c: flag off');
    }
    expect(view['type'], 'run');
    expect(off['type'], 'run', reason: 'the workout itself stays');
    expect((await LocalDb.session('strap'))!['calories'], 120.0,
        reason: 'stored as it was, so flag on serves it again');
    LocalDb.sessionSensorSources = {kBleHrs.id};
    expect((await served())['strain'], 9.5);
    expect((await viewed())['strain'], 9.5);
  });

  test("a strap's stamped session stays empty with its flag off, beside a "
      "wearable's minutes and after its raw is pruned", () async {
    LocalDb.sessionSensorSources = {kBleHrs.id};
    LocalDb.sessionWearableSource = kGarmin.id;
    await _bank(kGarmin, [
      for (var t = _t0; t <= _t0 + 600; t += 60) _s(t, hr: 90),
    ]);
    await _bank(kBleHrs, [
      for (var t = _t0 + 120; t <= _t0 + 600; t++) _s(t, hr: 150),
    ]);
    await LocalDb.putSession({
      'id': 'stamped',
      'start_ts': _t0,
      'end_ts': _t0 + 600,
      'type': 'run',
      'status': 'done',
      'calories': 120.0,
      'strain': 9.5,
      'max_hr': 150,
      'zone_min_json': '[0,0,10,0,0]',
      'created_at': _t0 + 600,
    });
    // Opening it with the flag on scores it from the strap and stamps it.
    await LocalRepositoryImpl(getProfileMap: () => {'age': 30})
        .getWorkout('stamped');
    Future<Map<String, dynamic>> served() async =>
        (await LocalDb.sessionsInRange(_t0 - 1, _t0 + 1)).single;
    expect((await served())['strain'], isNotNull);

    LocalDb.sessionSensorSources = const {};
    for (final c in ['calories', 'strain', 'max_hr', 'zone_min_json']) {
      expect((await served())[c], isNull,
          reason: "$c: the watch's flag-on minutes do not unmask the strap's");
    }
    await (await LocalDb.instance).delete('decoded_onehz');
    LocalDb.sessionWearableSource = null;
    expect((await served())['strain'], isNull,
        reason: 'the stamp outlives the raw');
    LocalDb.sessionSensorSources = {kBleHrs.id};
    expect((await served())['strain'], isNotNull);
  });

  test('a session two straps scored is served empty when either flag is off',
      () async {
    await LocalDb.putSession({
      'id': 'both',
      'start_ts': _t0,
      'end_ts': _t0 + 600,
      'type': 'run',
      'status': 'done',
      'strain': 9.5,
      'created_at': _t0 + 600,
    });
    await LocalDb.stampSessionSensor('both', kBleHrs.id);
    await LocalDb.stampSessionSensor('both', kPolarPmd.id);
    expect(await LocalDb.sessionSensorsOf('both'), {kBleHrs.id, kPolarPmd.id});
    Future<Object?> strain() async =>
        (await LocalDb.sessionsInRange(_t0 - 1, _t0 + 1)).single['strain'];
    LocalDb.sessionSensorSources = {kBleHrs.id, kPolarPmd.id};
    expect(await strain(), isNotNull);
    LocalDb.sessionSensorSources = {kPolarPmd.id};
    expect(await strain(), isNull, reason: 'the first strap still scored it');
  });

  test("a sweep with the strap's flag off keeps its stamped score for flag on",
      () async {
    // Recent, so the drain sweep's window holds it.
    final t0 = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;
    final db = await LocalDb.instance;
    // The band saw the first ten minutes only.
    for (var t = t0; t < t0 + 600; t++) {
      await db.insert('decoded_onehz', {
        'device_id': 'band',
        'ts_ms': t * 1000,
        'rec_ts': t,
        'counter': t - t0,
        'hr': 80,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
      });
    }
    await LocalDb.putSession({
      'id': 'strap',
      'start_ts': t0,
      'end_ts': t0 + 1800,
      'type': 'run',
      'status': 'done',
      'calories': 320.0,
      'strain': 12.5,
      'max_hr': 170,
      'zone_min_json': '[0,0,5,20,5]',
      'created_at': t0 + 1800,
    });
    await LocalDb.stampSessionSensor('strap', kBleHrs.id);
    LocalDb.sessionSensorSources = const {};
    await LocalRepositoryImpl(getProfileMap: () => {'age': 30})
        .rescoreRecentSessions();
    await LocalRepositoryImpl(getProfileMap: () => {'age': 30})
        .getWorkout('strap');
    final stored = (await LocalDb.session('strap'))!;
    expect(stored['strain'], 12.5, reason: "the band's minutes overwrote it");
    expect(stored['calories'], 320.0);
    expect(stored['zone_min_json'], '[0,0,5,20,5]');
    LocalDb.sessionSensorSources = {kBleHrs.id};
    expect((await LocalDb.sessionsInRange(t0 - 1, t0 + 1)).single['strain'],
        12.5);
  });

  test("turning a strap's flag off re-derives the band day its session's "
      'calories were credited to', () async {
    const day = '2026-10-04';
    const profile =
        Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
    for (final (raws, samples)
        in SyntheticDay(DateTime(2026, 10, 4)).primaryBatches()) {
      await LocalDb.commitSyncBatch(raws, samples);
    }
    // The band off the wrist for the workout; the strap scored it.
    final s0 = DateTime(2026, 10, 4, 15).millisecondsSinceEpoch ~/ 1000;
    final db = await LocalDb.instance;
    await db.delete('decoded_onehz',
        where: 'rec_ts >= ? AND rec_ts <= ?', whereArgs: [s0, s0 + 2700]);
    await LocalDb.putSession({
      'id': 'strap',
      'start_ts': s0,
      'end_ts': s0 + 2700,
      'type': 'run',
      'status': 'done',
      'calories': 300.0,
      'strain': 11.0,
      'created_at': s0 + 2700,
    });
    await LocalDb.stampSessionSensor('strap', kBleHrs.id);
    await LocalDb.setCursor(wearableEnabledCursor(kBleHrs.id), '1');
    await refreshSessionSensorSources();
    Future<double> calories() async => ((await db.query('metric_series',
            where: "date = ? AND key = 'calories'", whereArgs: [day]))
        .single['value'] as num)
        .toDouble();
    await DerivationEngine().runDays(profile, {day}, force: true);
    final on = await calories();
    onWearableDaysChanged =
        (days) => DerivationEngine().runDays(profile, days, force: true);
    try {
      await setWearableEnabled(kBleHrs.id, false);
    } finally {
      onWearableDaysChanged = null;
    }
    expect(await calories(), closeTo(on - 300, 1),
        reason: "flag off: the strap's kcal leave the day");
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a Coros watch is no session source, its flag on or not', () async {
    await LocalDb.setCursor(wearableEnabledCursor(kCoros.id), '1');
    await LocalDb.setCursor(wearableEnabledCursor(kBleHrs.id), '1');
    await refreshSessionSensorSources();
    expect(LocalDb.sessionSensorSources, {kBleHrs.id});
  });

  test('a derive loads the sensor flags itself (a headless wake)', () async {
    await LocalDb.setCursor(wearableEnabledCursor(kPolarPmd.id), '1');
    expect(LocalDb.sessionSensorSources, isEmpty);
    await DerivationEngine().runDays(
        Profile.fromMap(const {'age': 32, 'weight_kg': 72.0, 'sex': 'm'}),
        {'2026-10-04'});
    expect(LocalDb.sessionSensorSources, {kPolarPmd.id});
  });

  test("a strap's seconds on a ring's day stand for their own minute only",
      () {
    const t = 1_800_000_000 - 1_800_000_000 % 300;
    final ring = [
      for (var s = t; s < t + 7200; s += 300)
        if (s < t + 3600 || s > t + 4800) s,
    ];
    final strap = [for (var s = t + 3600; s <= t + 4800; s++) s];
    final ts = [...ring, ...strap]..sort();
    final sub = Substrate(
      tsSec: ts,
      hr: [for (final s in ts) s >= t + 3600 && s <= t + 4800 ? 150 : 60],
      rrTsMs: const [],
      rrMs: const [],
      ax: List.filled(ts.length, 0),
      ay: List.filled(ts.length, 0),
      az: List.filled(ts.length, 0),
      spo2Red: List.filled(ts.length, 0),
      spo2Ir: List.filled(ts.length, 0),
      skinTemp: List.filled(ts.length, 0),
      skinContact: List.filled(ts.length, 0),
      deviceFamily: kUltrahumanFamily,
    );
    final w = DerivationEngine.debugPerMinuteMeanWake(sub);
    final byMin = {
      for (var i = 0; i < w.keys.length; i++) w.keys[i]: w.hr[i],
    };
    final last = (t + 4800) ~/ 60;
    for (var m = last + 1; m < last + 5; m++) {
      expect(byMin[m], isNot(150), reason: 'minute ${m - last} past the strap');
    }
    expect(byMin[(t + 3300) ~/ 60 + 4], 60,
        reason: "a ring reading still stands for the minutes up to the next");
  });

  test("a ring reading just after a strap's seconds stands for its minutes",
      () {
    const t = 1_800_000_000 - 1_800_000_000 % 300;
    final strap = [for (var s = t; s <= t + 600; s++) s];
    final ring = [for (var s = t + 630; s < t + 3600; s += 300) s];
    final ts = [...strap, ...ring];
    final sub = Substrate(
      tsSec: ts,
      hr: [for (final s in ts) s <= t + 600 ? 150 : 60],
      rrTsMs: const [],
      rrMs: const [],
      ax: List.filled(ts.length, 0),
      ay: List.filled(ts.length, 0),
      az: List.filled(ts.length, 0),
      spo2Red: List.filled(ts.length, 0),
      spo2Ir: List.filled(ts.length, 0),
      skinTemp: List.filled(ts.length, 0),
      skinContact: List.filled(ts.length, 0),
      deviceFamily: kUltrahumanFamily,
    );
    final w = DerivationEngine.debugPerMinuteMeanWake(sub);
    final byMin = {
      for (var i = 0; i < w.keys.length; i++) w.keys[i]: w.hr[i],
    };
    // Its own minute it shares with the strap's last second.
    for (var k = 1; k < 5; k++) {
      expect(byMin[(t + 630) ~/ 60 + k], 60,
          reason: '30 s after the strap, minute $k of the ring reading');
    }
  });
}

