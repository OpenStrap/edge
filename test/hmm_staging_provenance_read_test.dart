import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/series_codec.dart';

const _day = '2026-05-20';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getLibraryPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}

Future<void> _put(String day, Map<String, dynamic> staging, {bool nap = false}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'date': day,
        'sleep_source': 'auto',
        if (nap) 'sleep_periods': {'periods': [
          {'onset_ts': 1779278400, 'wake_ts': 1779280200,
            'duration_min': 30, 'is_main': false},
        ]},
        'sleep': {
          'accounting': {
            'value': {
              'tst_sec': 25200,
              'waso_sec': 600,
              'light_sec': 15000,
              'deep_sec': 4800,
              'rem_sec': 5400,
            },
          },
          ...staging,
        },
      }),
      windowJson: '{}',
    );

const _fallback = <String, dynamic>{
  'staging_method': 'hmm',
  'staging_effective_method': 'cardio',
  'staging_fallback': 'hmm_unavailable',
  'staging_fallback_sec': 28437,
  'staging_note': 'claim and fallback',
};

const _keys = [
  'staging_method',
  'staging_effective_method',
  'staging_fallback',
  'staging_fallback_sec',
];

Map<String, Object?> _picked(Map<String, dynamic> night) => {
      for (final k in _keys)
        if (night.containsKey(k)) k: night[k],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalRepositoryImpl repo;
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('openstrap_hmm_prov_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_hmm_provenance_read_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = await LocalDb.instance;
    await db.delete('day_result');
  });

  // why: stored provenance must survive reads and exports without fabrication.
  // # catches: dropping or blindly casting the stored provenance keys.
  test('the night map carries the provenance of a fallback night', () async {
    await _put(_day, _fallback);
    final n = await repo.getDaySleepV2(_day);
    expect(_picked(n), {
      'staging_method': 'hmm',
      'staging_effective_method': 'cardio',
      'staging_fallback': 'hmm_unavailable',
      'staging_fallback_sec': 28437,
    });
  });

  // why: stored provenance must survive reads and exports without fabrication.
  // # catches: dropping or blindly casting the stored provenance keys.
  test('an ordinary experimental night has the method and no fallback',
      () async {
    await _put(_day, {
      'staging_method': 'hmm',
      'staging_effective_method': 'hmm',
    });
    final n = await repo.getDaySleepV2(_day);
    expect(_picked(n), {
      'staging_method': 'hmm',
      'staging_effective_method': 'hmm',
    });
  });

  // why: stored provenance must survive reads and exports without fabrication.
  // # catches: dropping or blindly casting the stored provenance keys.
  test('an older payload without the keys reads as before: nothing invented',
      () async {
    await _put(_day, {'staging_note': 'old'});
    final n = await repo.getDaySleepV2(_day);
    expect(n['has_sleep'], isTrue);
    expect(_picked(n), isEmpty);
    // An older experimental night: the requested method is all it has.
    await _put('2026-05-21', {'staging_method': 'hmm'});
    expect(_picked(await repo.getDaySleepV2('2026-05-21')),
        {'staging_method': 'hmm'});
  });

  // why: stored provenance must survive reads and exports without fabrication.
  // # catches: dropping or blindly casting the stored provenance keys.
  test('an unknown fallback value is passed on as text, never as a method',
      () async {
    await _put(_day, {
      ..._fallback,
      'staging_fallback': 'hmm_from_the_future',
    });
    final n = await repo.getDaySleepV2(_day);
    expect(n['staging_fallback'], 'hmm_from_the_future');
    expect(n['has_sleep'], isTrue, reason: 'the estimate is still shown');
  });

  // why: stored provenance must survive reads and exports without fabrication.
  // # catches: dropping or blindly casting the stored provenance keys.
  test('a hand-edited row degrades to unknown, never to a wrong value',
      () async {
    await _put(_day, {
      'staging_method': 'hmm',
      'staging_effective_method': 7,
      'staging_fallback': {'x': 1},
      'staging_fallback_sec': -5,
    });
    final n = await repo.getDaySleepV2(_day);
    expect(_picked(n), {'staging_method': 'hmm'});
    await _put('2026-05-21', {
      'staging_method': 'hmm',
      'staging_fallback': 'hmm_unavailable',
      'staging_fallback_sec': 'soon',
    });
    final m = await repo.getDaySleepV2('2026-05-21');
    expect(m['staging_fallback'], 'hmm_unavailable');
    expect(m.containsKey('staging_fallback_sec'), isFalse);
  });

  // why: a no-sleep result still explains why HMM abstained.
  test('no-sleep maps retain stored fallback provenance', () async {
    for (final nap in [false, true]) {
      await _put(_day, {
        ..._fallback,
        'accounting': {'value': <String, dynamic>{}},
      }, nap: nap);
      final n = await repo.getDaySleepV2(_day);
      expect(n['has_sleep'], isFalse);
      expect(n['periods'], nap ? hasLength(1) : isNull);
      expect(_picked(n), {for (final k in _keys) k: _fallback[k]});
    }
  });

  Future<Map<String, dynamic>> storedSleep(String dbPath, String day) async {
    final out = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final rows = await out.query('day_result',
          where: 'day_id = ?', whereArgs: [day]);
      expect(rows, hasLength(1));
      final payload = SeriesCodec.decodePayloadJson(
          rows.single['payload_json'] as String)!;
      return (payload['sleep'] as Map).cast<String, dynamic>();
    } finally {
      await out.close();
    }
  }

  // why: stored provenance must survive reads and exports without fabrication.
  // # catches: dropping or blindly casting the stored provenance keys.
  test('a selected-day export carries the keys and a restore brings them back',
      () async {
    await _put(_day, _fallback);
    await _put('2026-05-22', {'staging_method': 'cardio'});
    final path = await LocalDb.exportDaysDb({_day});
    addTearDown(() => databaseFactory.deleteDatabase(path));
    final sleep = await storedSleep(path, _day);
    for (final k in _keys) {
      expect(sleep[k], _fallback[k], reason: k);
    }

    final db = await LocalDb.instance;
    await db.delete('day_result');
    await LocalDb.importFromDbFile(path);
    expect(_picked(await repo.getDaySleepV2(_day)), {
      for (final k in _keys) k: _fallback[k],
    });
  });

  // why: stored provenance must survive reads and exports without fabrication.
  // # catches: dropping or blindly casting the stored provenance keys.
  test('a full export carries the keys and a restore brings them back',
      () async {
    await _put(_day, _fallback);
    final path = await LocalDb.exportCopy();
    addTearDown(() => databaseFactory.deleteDatabase(path));
    final sleep = await storedSleep(path, _day);
    for (final k in _keys) {
      expect(sleep[k], _fallback[k], reason: k);
    }

    final db = await LocalDb.instance;
    await db.delete('day_result');
    await LocalDb.importFromDbFile(path);
    expect(_picked(await repo.getDaySleepV2(_day)), {
      for (final k in _keys) k: _fallback[k],
    });
  });
}
