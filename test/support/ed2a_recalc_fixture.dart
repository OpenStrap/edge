// Shared ED-2a inputs. No cache or invalidation policy lives in this harness.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const edProfile = Profile(ageYears: 35, weightKg: 75, heightCm: 178,
    sex: 'male', restingHrManual: 54);
const edDay = '2020-01-02';
final edStart = DateTime(2020, 1, 2, 10).millisecondsSinceEpoch ~/ 1000;

void edInit() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

Future<void> edDrop() async {
  await LocalDb.close();
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  LocalDb.sessionSensorSources = {};
  LocalDb.sessionWearableSource = null;
  DerivationEngine.debugSecondHalfHook = null;
  DerivationEngine.debugRunning = false;
}

Future<void> edFresh(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  await edDrop();
  SharedPreferences.setMockInitialValues({});
  await LocalDb.instance;
}

Future<void> edRows(int from, int to, {int hr = 170, String id = '',
    String family = 'gen4', String? source, double az = 1.3}) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var ts = from; ts < to; ts++) {
    batch.insert('decoded_onehz', {'device_id': id, 'ts_ms': ts * 1000,
      'rec_ts': ts, 'counter': ts, 'hr': hr, 'ax': 0.0, 'ay': 0.0,
      'az': az, 'device_family': family, 'source': source},
      conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

Future<void> edSession({String id = 's1', String status = 'done',
    int? start, int? end}) => LocalDb.putSession({'id': id, 'type': 'run',
  'status': status, 'start_ts': start ?? edStart,
  'end_ts': end ?? edStart + 1100, 'source': 'manual',
  'created_at': edStart * 1000});

// The committed two_device_day.json region table and formulas, also used by
// two_device_fixture_test.dart. Keep the fixture intact for exactness laws.
Future<void> edExistingFixture() async {
  final spec = jsonDecode(File('test/fixtures/two_device_day.json').readAsStringSync()) as Map;
  const start = 1577923200;
  int offset(String time) {
    final c = time.split(':').map(int.parse).toList();
    return c[0] * 3600 + c[1] * 60 + c[2];
  }
  final db = await LocalDb.instance;
  final b = db.batch();
  for (final region in spec['regions'] as List) {
    final r = region as Map;
    final holes = {for (final h in (r['holes'] as List?) ?? []) offset(h as String)};
    for (var i = offset(r['start'] as String); i <= offset(r['end'] as String); i++) {
      if (holes.contains(i)) continue;
      final ts = start + i;
      for (final family in r['devices'] as List) {
        final primary = family == 'gen4';
        final id = primary ? '' : 'oura-a1b2c3d4';
        b.insert('decoded_onehz', {'device_id': id, 'ts_ms': ts * 1000,
          'rec_ts': ts, 'counter': ts, 'device_family': family,
          'hr': primary ? 60 + ts % 7 : null,
          'ax': primary ? 0.0 : null, 'ay': primary ? 0.0 : null,
          'az': primary ? 1.0 : null,
          'skin_temp_raw': primary ? 30000 + ts % 11 : null,
          'skin_temp_c': primary ? null : 33.0 + ts % 9 / 10},
          conflictAlgorithm: ConflictAlgorithm.replace);
        if (primary) {
          b.insert('decoded_rr', {'device_id': '', 'ts_ms': ts * 1000,
            'rec_ts': ts, 'rr_ts_ms': ts * 1000, 'beat_index': 0, 'rr_ms': 1000 - ts % 5 * 10},
            conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }
  }
  await b.commit(noResult: true);
}

Map<String, dynamic> edBundle(PreparedDerivationDay day) {
  final d = day.daySub, s = day.sleepSub;
  return deriveDayBundle(DayBundleInput(date: day.date,
    dayTsSec: d.tsSec, dayHr: d.hr, dayRrTsMs: d.rrTsMs, dayRrMs: d.rrMs,
    sleepTsSec: s.tsSec, sleepHr: s.hr, sleepRrTsMs: s.rrTsMs,
    sleepRrMs: s.rrMs, sleepSkinTemp: s.skinTemp, sleepJson: day.sleepJson,
    hypnoStages: day.hypnoStages, sleepOnsetSec: day.sleepOnsetSec,
    sleepOffsetSec: day.sleepOffsetSec, profile: edProfile.toMap(),
    dayConfidence: day.confidence, dayFlags: day.flags,
    deviceFamily: d.deviceFamily, sleepSource: day.sleepSource).toJson());
}

Future<String> edPreparedOutput(DerivationEngine engine) async {
  final prepared = await engine.debugPrepareDay(edDay);
  expect(prepared, isNotNull);
  expect(prepared!.daySub.isEmpty, isFalse, reason: 'fixture must reach compute');
  return jsonEncode({'prepared': prepared.toJson(), 'bundle': edBundle(prepared),
    'profile': (await LocalDb.baseline('sleep_user_profile'))?['payload_json']});
}

// Strip only operational timestamps, never metric values, absence, notes,
// confidence, profile state or version. JSON property order stays observable.
Future<String> edStored(String day) async {
  final db = await LocalDb.instance;
  final rows = await db.query('day_result', where: 'day_id = ?',
      whereArgs: [day], orderBy: 'algo_version');
  expect(rows, isNotEmpty, reason: 'the real derive must have persisted a day');
  return jsonEncode({'day_result': [for (final row in rows) {
    for (final e in row.entries)
      if (e.key == 'payload_json') e.key: jsonEncode(
          (jsonDecode(e.value as String) as Map)..remove('computed_at'))
      else if (e.key != 'computed_at') e.key: e.value,
  }], 'metric_series': await db.query('metric_series', where: 'date = ?',
      whereArgs: [day], orderBy: 'key'),
    'profile': (await LocalDb.baseline('sleep_user_profile'))?['payload_json']});
}

Future<void> edOwnership({String id = 'other',
    List<String> signals = const ['hr1Hz', 'rrIntervals']}) async {
  final db = await LocalDb.instance;
  for (final signal in signals) {
    await db.insert('device_coverage', {'device_id': id, 'signal': signal,
      'start_ts': edStart, 'end_ts': edStart + 600},
      conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('signal_priority', {'signal': signal, 'device_id': id,
      'rank': 0, 'user_set': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('signal_priority', {'signal': signal, 'device_id': '',
      'rank': 1, 'user_set': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

String edLabel(int second) => dayLabelOf(DateTime.fromMillisecondsSinceEpoch(second * 1000));
Substrate edSmallSub({int? start, int count = 1200}) => Substrate.fromJson({
  'ts_sec': [for (var i = 0; i < count; i++) (start ?? edStart) + i],
  'hr': List<int>.filled(count, 60),
  'ax': List<double>.filled(count, 0), 'ay': List<double>.filled(count, 0),
  'az': List<double>.filled(count, 1), 'device_family': 'gen4',
});

// Same libc seam used by the fork's zone regressions. No process spawning or
// Dart clock substitution: production DateTime resolves each instant's zone.
typedef _Setenv = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
void edSetZone(String zone) {
  final libc = DynamicLibrary.process();
  final key = 'TZ'.toNativeUtf8(), value = zone.toNativeUtf8();
  try {
    expect(libc.lookupFunction<_Setenv, _SetenvDart>('setenv')(key, value, 1), 0);
    libc.lookupFunction<Void Function(), void Function()>('tzset')();
  } finally { calloc.free(key); calloc.free(value); }
}

Future<void> edPriorityOrder(List<String> ids) async {
  final db = await LocalDb.instance;
  for (var rank = 0; rank < ids.length; rank++) {
    await db.insert('signal_priority', {'signal': 'hr1Hz', 'device_id': ids[rank],
      'rank': rank, 'user_set': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
