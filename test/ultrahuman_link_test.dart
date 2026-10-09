// The Ultrahuman HOST: a scripted ring in, database rows out, through the
// REAL adapter, the real [BandHost], the real cursor persistence and real
// sqlite. Pins where each decoded thing lands and that the day-anchored
// bookmark keeps a day's totals whole across sessions.

import 'dart:io' show pid;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/gatt_link.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ble/ultrahuman_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'ultrahuman-0a1b2c3d';
final DateTime _today = DateTime(2026, 10, 4);
int _sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

List<int> _rec(DateTime at, {required int hr, required int steps}) {
  // Bytes 30-31 (the ring's own index) are stamped by [_ring].
  final b = ByteData(32);
  final ts = _sec(at);
  b.setUint32(0, ts, Endian.little);
  b.setUint8(4, hr);
  b.setUint8(5, 45);
  b.setUint8(6, 97);
  b.setUint8(7, kUltrahumanHrQualityLegacy);
  b.setUint32(8, ts, Endian.little);
  b.setFloat32(12, 34.6, Endian.little);
  b.setFloat32(16, 34.4, Endian.little);
  b.setUint32(20, ts, Endian.little);
  b.setUint16(26, steps, Endian.little);
  b.setUint8(28, 51);
  b.setUint8(29, 1);
  return b.buffer.asUint8List();
}

/// A ring holding [records] at indices 1..n (it numbers from 1), answering
/// `0x04` from the requested index in frames of up to 7 records.
List<List<int>> Function(int, List<int>) _ring(List<List<int>> unstamped) =>
    (int _, List<int> w) {
      final records = [
        for (var i = 0; i < unstamped.length; i++)
          [...unstamped[i].sublist(0, 30), (i + 1) & 0xff, (i + 1) >> 8],
      ];
      List<int> resp(int op, int result, List<int> payload) => [
            op,
            result,
            payload.length ~/ kUltrahumanRecordLen,
            ...payload,
            0,
            0,
          ];
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
            final chunk =
                records.sublist(i, (i + 7).clamp(0, records.length));
            out.add(resp(w[0], kUltrahumanResultOk,
                [for (final r in chunk) ...r]));
          }
          if (out.isNotEmpty &&
              (records.length - from) % 7 == 0) {
            out.add(resp(w[0], kUltrahumanResultEmpty, const []));
          }
          return out;
      }
      return const [];
    };

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    // Per process: another run of this file (a parallel checkout or agent)
    // must not delete this one's DB mid-test.
    LocalDb.dbName = 'ultrahuman_link_test_$pid.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
  });

  final yesterday = _today.subtract(const Duration(days: 1));
  final first = [
    _rec(yesterday.add(const Duration(hours: 23)), hr: 55, steps: 50),
    _rec(_today.add(const Duration(hours: 2)), hr: 51, steps: 0),
    _rec(_today.add(const Duration(hours: 8)), hr: 70, steps: 300),
  ];

  Future<num?> stepsOn(DateTime day) async {
    final rows = await LocalDb.observationsForDay(
        '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}');
    final hit = rows.where((r) => r['key'] == 'steps');
    return hit.isEmpty ? null : hit.single['value'] as num;
  }

  test('HR lands in decoded_onehz under source ultrahuman, outside derivation',
      () async {
    await UltrahumanLink.instance.ingestForTest(_deviceId, _ring(first),
        nowSeconds: () => _sec(_today.add(const Duration(hours: 12))));
    final db = await LocalDb.instance;
    final rows = await db.query('decoded_onehz', orderBy: 'rec_ts');
    expect(rows.map((r) => r['hr']), [55, 51, 70]);
    expect(rows.every((r) => r['source'] == kUltrahuman.id), isTrue);
    expect(kDerivableSources, isNot(contains(kUltrahuman.id)));
    expect(await stepsOn(yesterday), 50);
    expect(await stepsOn(_today), 300);
  });

  test('a later session re-reads today from its first record, so the daily '
      'total stays whole', () async {
    await UltrahumanLink.instance.ingestForTest(_deviceId, _ring(first),
        nowSeconds: () => _sec(_today.add(const Duration(hours: 12))));
    expect(await LocalDb.getCursorInt('ultrahuman_cursor:$_deviceId'), 2,
        reason: 'index 2 is the first record of today');

    final later = [
      ...first,
      _rec(_today.add(const Duration(hours: 15)), hr: 88, steps: 1000),
    ];
    await UltrahumanLink.instance.ingestForTest(_deviceId, _ring(later),
        nowSeconds: () => _sec(_today.add(const Duration(hours: 16))));
    // 300 + 1000, not just the 1000 this session newly saw.
    expect(await stepsOn(_today), 1300);
    // Yesterday was not touched by the second session and keeps its value.
    expect(await stepsOn(yesterday), 50);
    final db = await LocalDb.instance;
    expect((await db.query('decoded_onehz')).length, 4,
        reason: 're-reading today re-banks the same seconds, not duplicates');
    final archive = await db.query('raw_archive');
    expect(archive.length, 4, reason: 'raw_archive is keyed on the bytes');
  });

  test('each archived record carries the ring\'s own index as its counter',
      () async {
    await UltrahumanLink.instance.ingestForTest(_deviceId, _ring(first),
        nowSeconds: () => _sec(_today.add(const Duration(hours: 12))));
    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive', orderBy: 'counter');
    expect(archive.map((r) => r['counter']), [1, 2, 3]);
  });

  group('enabling the reply notification', () {
    FlutterBluePlusException err(int code) => FlutterBluePlusException(
        ErrorPlatform.android, 'setNotifyValue', code, 'gatt');

    test('an auth refusal on Android bonds, then retries exactly once',
        () async {
      var enables = 0, bonds = 0;
      await UltrahumanLink.enableNotifyWithBondRetry(
        () async {
          if (++enables == 1) throw err(5);
          return true;
        },
        () async => bonds++,
        isAndroid: true,
      );
      expect((enables, bonds), (2, 1));
    });

    test('a second refusal fails the sync instead of draining silently',
        () async {
      var bonds = 0;
      await expectLater(
        UltrahumanLink.enableNotifyWithBondRetry(
          () async => throw err(137),
          () async => bonds++,
          isAndroid: true,
        ),
        throwsA(isA<FlutterBluePlusException>()),
      );
      expect(bonds, 1);
    });

    test('a non-auth error, or any error on iOS, is not retried', () async {
      var bonds = 0;
      for (final (code, android) in [(133, true), (5, false)]) {
        await expectLater(
          UltrahumanLink.enableNotifyWithBondRetry(
            () async => throw err(code),
            () async => bonds++,
            isAndroid: android,
          ),
          throwsA(isA<FlutterBluePlusException>()),
        );
      }
      expect(bonds, 0);
    });
  });

  group('finding and writing to the ring', () {
    test('the ring is matched by its advertised name, either prefix', () {
      final m = kUltrahuman.nameMatcher!;
      expect(m('uh_a1b2c3'), isTrue);
      expect(m('up_0042'), isTrue);
      expect(m('r02_1234'), isFalse);
      // A prefix, not a substring: other devices carry these letters too.
      expect(m('setup_12'), isFalse);
      expect(m('backup_x'), isFalse);
    });

    test('a scan that includes the ring drops the OS-level service filter',
        () {
      expect(HrsLink.scanServiceFilter([kUltrahuman]), isEmpty);
      expect(HrsLink.scanServiceFilter([kBleHrs, kUltrahuman]), isEmpty);
      expect(HrsLink.scanServiceFilter([kBleHrs]), [Guid(kBleHrs.service)]);
    });

    test('a characteristic that only takes write-without-response gets it',
        () {
      expect(
          GattBandLink.writeWithoutResponseFor(
              const CharacteristicProperties(writeWithoutResponse: true)),
          isTrue);
      expect(
          GattBandLink.writeWithoutResponseFor(const CharacteristicProperties(
              write: true, writeWithoutResponse: true)),
          isFalse);
      expect(
          GattBandLink.writeWithoutResponseFor(
              const CharacteristicProperties(write: true)),
          isFalse);
    });
  });
}
