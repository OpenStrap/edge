// The WHOOP MG ECG store: schema presence and idempotence, the atomic
// reading+packet insert (and its all-or-nothing failure), the signed-i16
// BLOB / placeholder round trip, the manual delete cascade, raw R16 riding
// the safe-trim commit, and the ownership lists (salvage, backup restore,
// wipe). Runs the REAL LocalDb over sqflite_common_ffi.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List _i16le(List<int> v) {
  final out = Uint8List(v.length * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < v.length; i++) {
    bd.setInt16(2 * i, v[i], Endian.little);
  }
  return out;
}

List<int> _fromI16le(Uint8List b) {
  final bd = ByteData.sublistView(b);
  return [
    for (var i = 0; i + 1 < b.length; i += 2) bd.getInt16(i, Endian.little),
  ];
}

Map<String, Object?> _reading(String id, {int startTs = 1787823754}) => {
  'id': id,
  'device_id': '',
  'source': 'mg_labrador',
  'wrist': 'right',
  'start_ts': startTs,
  'end_ts': startTs + 30,
  'strap_terminal_ts': startTs + 30,
  'strap_terminal_subsec': 100,
  'result_code': 1,
  'category': 'sinusRhythm',
  'avg_hr': 77,
  'quality': 3,
  'unreadable_mask': 0,
  'interruptions': 0,
  'sample_rate_hz': 100,
  'sample_unit': 'filtered_input_referred_uv',
  'sample_count': 5,
  'min_uv': -531,
  'max_uv': 731,
  'rms_uv': 126.773,
  'missing_segments': 1,
  'status': 'completed',
  'notes': null,
  'created_at': 1787823784000,
};

Map<String, Object?> _packet(
  int seq,
  List<int> samples, {
  bool placeholder = false,
}) => {
  'sequence': seq,
  'strap_seconds': 1787823754 + seq,
  'strap_subsec': 12,
  'sample_count': samples.length,
  'samples': _i16le(samples),
  'inner_hex': placeholder ? '' : '2b11${seq.toRadixString(16)}',
  'is_placeholder': placeholder ? 1 : 0,
};

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_ecg_db_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test(
    'fresh schema has the three tables, the index and the coach view',
    () async {
      final names = await LocalDb.tableNames();
      expect(
        names,
        containsAll(['ecg_reading', 'ecg_reading_packet', 'ecg_raw_packet']),
      );
      final db = await LocalDb.instance;
      final views = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='view' AND name='v_ecg_readings'",
      );
      expect(views, hasLength(1));
      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
    },
  );

  test('reading + packets insert atomically and round-trip signed samples '
      'and the placeholder', () async {
    await LocalDb.insertEcgReading(_reading('r1'), [
      _packet(100, [-1, 1, 32767, -32768, 0]),
      _packet(101, const [], placeholder: true),
      _packet(102, [-5396, 3377]),
    ]);
    final row = (await LocalDb.ecgReading('r1'))!;
    expect(row['category'], 'sinusRhythm');
    expect(row['avg_hr'], 77);
    expect(row['sample_unit'], 'filtered_input_referred_uv');
    final packets = await LocalDb.ecgReadingPackets('r1');
    expect(packets.map((p) => p['ordinal']), [0, 1, 2]);
    expect(_fromI16le(packets[0]['samples'] as Uint8List), [
      -1,
      1,
      32767,
      -32768,
      0,
    ]);
    expect(packets[1]['is_placeholder'], 1);
    expect((packets[1]['samples'] as Uint8List), isEmpty);
    expect(packets[1]['sequence'], 101);
    expect(_fromI16le(packets[2]['samples'] as Uint8List), [-5396, 3377]);
    expect(packets[2]['inner_hex'], '2b1166');
  });

  test('a failing packet insert rolls the reading back too', () async {
    final bad = _packet(1, [1])..remove('sample_count'); // NOT NULL violation
    await expectLater(
      LocalDb.insertEcgReading(_reading('r_bad'), [
        _packet(0, [1]),
        bad,
      ]),
      throwsA(anything),
    );
    expect(await LocalDb.ecgReading('r_bad'), isNull);
    expect(await LocalDb.ecgReadingPackets('r_bad'), isEmpty);
  });

  test('re-saving the same reading id is refused, not merged', () async {
    await expectLater(
      LocalDb.insertEcgReading(_reading('r1'), const []),
      throwsA(anything),
    );
    expect(
      await LocalDb.ecgReadingPackets('r1'),
      hasLength(3),
      reason: 'the original packets are untouched',
    );
  });

  test('listEcgReadings is newest first and carries no packets', () async {
    await LocalDb.insertEcgReading(
      _reading('r2', startTs: 1787900000),
      const [],
    );
    final rows = await LocalDb.listEcgReadings();
    expect(rows.map((r) => r['id']).take(2), ['r2', 'r1']);
    expect(rows.first.containsKey('samples'), isFalse);
  });

  test(
    'the coach view is summary-only: local date, duration, no identity',
    () async {
      final db = await LocalDb.instance;
      final v = await db.query(
        'v_ecg_readings',
        where: 'id = ?',
        whereArgs: ['r1'],
      );
      expect(v, hasLength(1));
      final r = v.first;
      expect(r['duration_s'], 30);
      expect(r['date'], hasLength(10));
      // 2026-08-27 19:42/19:43 in Europe/Berlin; whatever the host zone, the
      // label is the LOCAL day of that instant.
      final local = DateTime.fromMillisecondsSinceEpoch(1787823754 * 1000);
      final expected =
          '${local.year}-${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
      expect(r['date'], expected);
      expect(r.containsKey('device_id'), isFalse);
      expect(r.containsKey('notes'), isFalse);
      expect(r.containsKey('samples'), isFalse);
      expect(r.containsKey('inner_hex'), isFalse);
    },
  );

  test(
    'deleteEcgReading cascades to its packets only and detaches raw rows',
    () async {
      await LocalDb.commitSyncBatch(
        const [],
        const <Sample?>[],
        ecgRawPackets: [
          const EcgRawPacket(
            hex: '2f10aa01',
            deviceId: '',
            sequence: 100,
            strapSeconds: 1787823854,
            strapSubsec: 12,
            capturedAt: 1787823854000,
          ),
        ],
      );
      final db = await LocalDb.instance;
      await db.update(
        'ecg_raw_packet',
        {'reading_id': 'r1'},
        where: 'hex = ?',
        whereArgs: ['2f10aa01'],
      );
      await LocalDb.deleteEcgReading('r1');
      expect(await LocalDb.ecgReading('r1'), isNull);
      expect(await LocalDb.ecgReadingPackets('r1'), isEmpty);
      expect(await LocalDb.ecgReadingPackets('r2'), isEmpty);
      expect(
        await LocalDb.ecgReading('r2'),
        isNotNull,
        reason: 'other readings survive',
      );
      final raw = await db.query(
        'ecg_raw_packet',
        where: 'hex = ?',
        whereArgs: ['2f10aa01'],
      );
      expect(raw, hasLength(1), reason: 'raw R16 is independent evidence');
      expect(raw.first['reading_id'], isNull);
    },
  );

  test(
    'raw R16 rides commitSyncBatch with the trim cursor, idempotently',
    () async {
      const pkt = EcgRawPacket(
        hex: '2f10bb02',
        deviceId: '',
        sequence: 24016883,
        strapSeconds: 1787928472,
        strapSubsec: 19334,
        capturedAt: 1787928473000,
      );
      await LocalDb.commitSyncBatch(
        const [],
        const <Sample?>[],
        trimToken: '0102030405060708',
        ecgRawPackets: [pkt, pkt],
      );
      expect(await LocalDb.ecgRawPacketCount(), 2); // the one above + this
      expect(await LocalDb.getCursor('strap_trim'), '0102030405060708');
      // Same bytes again: no duplicate.
      await LocalDb.commitSyncBatch(
        const [],
        const <Sample?>[],
        ecgRawPackets: [pkt],
      );
      expect(await LocalDb.ecgRawPacketCount(), 2);
    },
  );

  test('ownership: the ECG tables are salvaged, restored and wiped', () async {
    expect(
      LocalDb.salvageTablesForTest,
      containsAllInOrder([
        'ecg_reading',
        'ecg_reading_packet',
        'ecg_raw_packet',
      ]),
    );
    expect(
      LocalDb.restoreTablesForTest,
      containsAllInOrder([
        'ecg_reading',
        'ecg_reading_packet',
        'ecg_raw_packet',
      ]),
    );
    final deleted = await LocalDb.wipeAll();
    expect(deleted, greaterThan(0));
    expect(await LocalDb.listEcgReadings(), isEmpty);
    expect(await LocalDb.ecgRawPacketCount(), 0);
  });

  test('re-opening runs the repair pass idempotently', () async {
    await LocalDb.close();
    final db = await LocalDb.instance;
    final names = await LocalDb.tableNames();
    expect(
      names,
      containsAll(['ecg_reading', 'ecg_reading_packet', 'ecg_raw_packet']),
    );
    final v = await db.rawQuery('PRAGMA user_version');
    expect(v.first.values.first, LocalDb.schemaVersion);
  });
}
