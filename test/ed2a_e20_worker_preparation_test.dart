@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/ed2a_recalc_fixture.dart';

String get _mainIsolate => Isolate.current.debugName ?? 'unnamed';
Future<Map<String, Object?>> _sessionReads() async {
  final r = await LocalDb.sessionHrReadsForTest(edStart, edStart + 1200);
  return {'stats': r.stats, 'samples': r.samples};
}

void main() {
  final sql = <String>[];
  setUpAll(edInit);
  setUp(() async {
    await edFresh('ed2a_e20.db');
    // Log the real join, rather than counting calls to a mock query function.
    await LocalDb.close();
    // ignore: experimental_member_use
    databaseFactoryOrNull = SqfliteDatabaseFactoryLogger(databaseFactoryFfi,
      options: SqfliteLoggerOptions(type: SqfliteDatabaseFactoryLoggerType.invoke,
        log: (event) {
          if (event is! SqfliteLoggerInvokeEvent) return;
          void collect(Object? v) {
            if (v is Map) {
              if (v['sql'] case final String s) sql.add(s);
              for (final x in v.values) { collect(x); }
            } else if (v is List) {
              for (final x in v) { collect(x); }
            }
          }
          collect(event.arguments);
        }));
    await LocalDb.instance;
    sql.clear();
  });
  tearDown(() async {
    debugDisableWearableWorker = false;
    debugOnWearableConstruction = null;
    LocalDb.debugDisableSessionWindowsWorker = false;
    LocalDb.debugOnSessionWindowsConstruction = null;
    await edDrop();
    databaseFactory = databaseFactoryFfi;
  });

  for (final family in ['garmin', 'colmi', 'oura', 'ultrahuman', 'pebble', 'miband234']) {
    test('$family construction runs off the caller isolate with exact output', () async {
      final id = '$family-a';
      await edRows(edStart, edStart + 1200, id: id, family: family, source: family, hr: 71, az: 0);
      debugDisableWearableWorker = true;
      final inline = await wearableSubstrate((id, family), edStart, edStart + 1199);
      expect(inline.isEmpty, isFalse, reason: 'fixture must enter a real builder');
      final locations = <String>[];
      debugOnWearableConstruction = locations.add;
      debugDisableWearableWorker = false;
      final worker = await wearableSubstrate((id, family), edStart, edStart + 1199);
      expect(jsonEncode(worker.toJson()), jsonEncode(inline.toJson()));
      final a = prepareDerivationPayload(inline, targetDay: edDay).days.single;
      final b = prepareDerivationPayload(worker, targetDay: edDay).days.single;
      expect(jsonEncode(edBundle(b)), jsonEncode(edBundle(a)));
      expect(locations, isNotEmpty, reason: 'actual construction must report execution location');
      expect(locations, everyElement(isNot(_mainIsolate)),
          reason: 'row construction still executes on the UI/caller isolate');
    });
  }

  test('two wearable devices at one second remain separate (passing guard)', () async {
    await edRows(edStart, edStart + 1200, id: 'a', family: 'garmin', source: 'garmin', hr: 65, az: 0);
    await edRows(edStart, edStart + 1200, id: 'b', family: 'garmin', source: 'garmin', hr: 95, az: 0);
    for (final id in ['a', 'b']) {
      debugDisableWearableWorker = true;
      final inline = await wearableSubstrate((id, 'garmin'), edStart, edStart + 1199);
      debugDisableWearableWorker = false;
      final worker = await wearableSubstrate((id, 'garmin'), edStart, edStart + 1199);
      expect(jsonEncode(worker.toJson()), jsonEncode(inline.toJson()));
      expect(worker.hr.toSet(), {id == 'a' ? 65 : 95});
      expect(worker.deviceIds, {id});
    }
  });

  test('two straps keep owner, beat timing and session overlay exact (guard)', () async {
    LocalDb.sessionSensorSources = {'ble_hrs', 'polar'};
    LocalDb.sessionWearableSource = 'garmin';
    await edRows(edStart, edStart + 1200, id: 'watch', family: 'garmin', source: 'garmin', hr: 70, az: 0);
    await edRows(edStart + 100, edStart + 700, id: 'strap-a', family: 'ble_hrs', source: 'ble_hrs', hr: 150, az: 0);
    await edRows(edStart + 100, edStart + 300, id: 'strap-b', family: 'polar', source: 'polar', hr: 180, az: 0);
    await edSession(start: edStart, end: edStart + 800);
    final db = await LocalDb.instance;
    for (final (id, source, rr) in [('strap-a', 'ble_hrs', 850), ('strap-b', 'polar', 900)]) {
      for (var i = 0; i < (id == 'strap-a' ? 3 : 1); i++) {
        final t = edStart + 150 + i;
        await db.insert('decoded_rr', {'device_id': id, 'source': source,
          'ts_ms': t * 1000, 'rec_ts': t, 'rr_ts_ms': t * 1000,
          'beat_ts_ms': t * 1000 - 123, 'rr_ms': rr, 'beat_index': 0});
      }
    }
    debugDisableWearableWorker = true;
    final inline = await wearableSubstrate(('watch', 'garmin'), edStart, edStart + 1199);
    debugDisableWearableWorker = false;
    final worker = await wearableSubstrate(('watch', 'garmin'), edStart, edStart + 1199);
    expect(jsonEncode(worker.toJson()), jsonEncode(inline.toJson()));
    expect(worker.hr, isNot(contains(180)), reason: 'minority source must not mix into a session');
    expect(worker.rrMs, [850, 850, 850]);
    expect(worker.rrTsMs.first, (edStart + 150) * 1000 - 123);
  });

  test('existing two-device fixture: on/off worker derive JSON is byte-identical (guard)', () async {
    await edExistingFixture();
    debugDisableWearableWorker = true;
    final inline = await wearableSubstrate(('oura-a1b2c3d4', 'oura'), 1577923200, 1577952000);
    debugDisableWearableWorker = false;
    final worker = await wearableSubstrate(('oura-a1b2c3d4', 'oura'), 1577923200, 1577952000);
    expect(inline.isEmpty, isFalse);
    expect(jsonEncode(worker.toJson()), jsonEncode(inline.toJson()));
    expect(worker.skinTemp.where((v) => v > 0), isNotEmpty);
    expect(jsonEncode(edBundle(prepareDerivationPayload(worker, targetDay: edLabel(worker.tsSec.last)).days.single)),
        jsonEncode(edBundle(prepareDerivationPayload(inline, targetDay: edLabel(inline.tsSec.last)).days.single)));
  });

  Future<void> sessionFixture() async {
    LocalDb.sessionSensorSources = {'ble_hrs', 'polar'};
    LocalDb.sessionWearableSource = 'garmin';
    await edSession();
    await edRows(edStart, edStart + 1200, id: 'watch', family: 'garmin', source: 'garmin', hr: 70);
    await edRows(edStart + 100, edStart + 700, id: 'strap-a', family: 'ble_hrs', source: 'ble_hrs', hr: 150);
    await edRows(edStart + 100, edStart + 300, id: 'strap-b', family: 'polar', source: 'polar', hr: 180);
  }

  test('combined session stats and samples use one SELECT', () async {
    await sessionFixture();
    sql.clear();
    final r = await _sessionReads();
    expect((r['samples'] as Map)['s1'], isNotEmpty);
    final joins = sql.where((s) => s.contains('JOIN decoded_onehz') && s.contains('FROM sessions'));
    expect(joins, hasLength(1), reason: 'stats and samples currently reread the same window twice');
  });

  test('session grouping executes off the caller isolate with exact JSON', () async {
    await sessionFixture();
    LocalDb.debugDisableSessionWindowsWorker = true;
    final inline = await _sessionReads();
    final locations = <String>[];
    LocalDb.debugOnSessionWindowsConstruction = locations.add;
    LocalDb.debugDisableSessionWindowsWorker = false;
    final worker = await _sessionReads();
    expect(jsonEncode(worker), jsonEncode(inline));
    expect(locations, isNotEmpty);
    expect(locations, everyElement(isNot(_mainIsolate)),
        reason: 'grouping and owner selection still loop over rows on the caller');
  });

  test('workout repository uses the combined read in its actual list flow', () async {
    await sessionFixture();
    final repo = LocalRepositoryImpl(getProfileMap: () => edProfile.toMap());
    sql.clear();
    final got = await repo.getWorkouts(range: 'all');
    expect(got['workouts'], isNotEmpty);
    final joins = sql.where((s) => s.contains('JOIN decoded_onehz') && s.contains('FROM sessions'));
    expect(joins, hasLength(1), reason: 'GREEN must wire the real getWorkouts consumer too');
  });

  test('bounded session aggregates and empty windows stay exact (guard)', () async {
    await sessionFixture();
    LocalDb.debugDisableSessionWindowsWorker = true;
    final inline = await LocalDb.sessionHrReadsForTest(edStart, edStart + 1200,
        maxHrCeiling: 140, minHrFloor: 80);
    LocalDb.debugDisableSessionWindowsWorker = false;
    final worker = await LocalDb.sessionHrReadsForTest(edStart, edStart + 1200,
        maxHrCeiling: 140, minHrFloor: 80);
    expect(jsonEncode({'stats': worker.stats, 'samples': worker.samples}),
        jsonEncode({'stats': inline.stats, 'samples': inline.samples}));
    expect(worker.stats['s1']!['min_hr'], 150);
    expect(worker.stats['s1']!['max_hr'], 70);
    expect(worker.samples['s1'], containsAll([70, 150]));
    final empty = await LocalDb.sessionHrReadsForTest(edStart - 100, edStart - 1);
    expect(empty.stats, isEmpty);
    expect(empty.samples, isEmpty);
  });

  test('session windows keep two-device ownership and last-second samples (guard)', () async {
    await sessionFixture();
    final inline = await _sessionReads();
    LocalDb.debugDisableSessionWindowsWorker = false;
    final worker = await _sessionReads();
    expect(jsonEncode(worker), jsonEncode(inline));
    final samples = (worker['samples'] as Map)['s1'] as List;
    expect(samples, isNot(contains(180)));
    expect(samples.first, 70);
    expect(samples.last, 70, reason: 'inclusive session end must survive preparation');
    final stats = (worker['stats'] as Map)['s1'] as Map;
    expect(stats['n'], 1101);
  });
}
