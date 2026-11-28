// Gen5 v18 samples must land in `decoded_onehz` via the preferred-sample
// fallback in LocalDb._decodeOneHzSample — they lack gen4 optics so R24
// decode fails, but they are honest 1 Hz substrate rows. R10-lite hr-only
// records must stay excluded.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _buildR10LiteInner({required int ts, required int counter, required int hr}) {
  final inner = Uint8List(18);
  inner[0] = PacketType.historicalData;
  inner[1] = Record.r10;
  inner.buffer.asByteData().setUint32(3, counter, Endian.little);
  inner.buffer.asByteData().setUint32(7, ts, Endian.little);
  inner[17] = hr;
  return inner;
}

/// Synthetic gen5 v18 lenient inner: valid unix@7 + HR, gravity fails gate.
Uint8List _buildGen5V18LenientInner({
  required int unix,
  required int counter,
  required int hr,
  List<int> rrMs = const [],
}) {
  final inner = Uint8List(112);
  inner[0] = PacketType.historicalData;
  inner[1] = 18;
  inner[2] = 0x80;
  inner[3] = counter & 0xff;
  inner[4] = (counter >> 8) & 0xff;
  inner[5] = (counter >> 16) & 0xff;
  inner[6] = (counter >> 24) & 0xff;
  inner.buffer.asByteData().setUint32(7, unix, Endian.little);
  inner[14] = hr;
  inner[15] = rrMs.length.clamp(0, 4).toInt();
  final view = inner.buffer.asByteData();
  for (var i = 0; i < rrMs.length && i < 4; i++) {
    view.setInt16(16 + 2 * i, rrMs[i], Endian.little);
  }
  view.setFloat32(33, 0.5, Endian.little);
  view.setFloat32(37, 0.05, Endian.little);
  view.setFloat32(41, 0.05, Endian.little);
  view.setFloat32(45, 0.05, Endian.little);
  return inner;
}

/// A v18 inner the decoder ACCEPTS (unlike [_buildGen5V18LenientInner], whose
/// gravity vector deliberately fails the magnitude gate), so the whole
/// decode → map → persist path runs. [skinTempRaw] is the AS6221 i16 at body
/// 52; the two flag bytes are the readings T10 disproved.
Uint8List _buildGen5V18DecodableInner({
  required int unix,
  required int counter,
  required int skinTempRaw,
  int hrQualityFlags = 0,
  int sleepStateByte = 0,
}) {
  final inner = Uint8List(112);
  final view = inner.buffer.asByteData();
  inner[0] = PacketType.historicalData;
  inner[1] = 18;
  inner[2] = 0x80;
  view.setUint32(3, counter, Endian.little);
  view.setUint32(7, unix, Endian.little);
  inner[14] = 61; // heart rate
  inner[15] = 0; // no RR slots
  inner[28] = hrQualityFlags;
  view.setFloat32(33, 0.5, Endian.little);
  view.setFloat32(37, 0.0, Endian.little);
  view.setFloat32(41, 0.0, Endian.little);
  view.setFloat32(45, 1.0, Endian.little); // magSq 1.0 — inside the gate
  view.setInt16(65, skinTempRaw, Endian.little);
  inner[73] = sleepStateByte;
  return inner;
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_gen5_onehz_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('gen5 → decoded_onehz persistence', () {
  test('gen5 v18-shaped sample persists via preferred fallback (+ RR)', () async {
    // Real fixture inner — same bytes as gen5_sample_mapping_test.dart.
    final frameHex =
        'aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000'
        '000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000'
        '000000000000f7000901f10b0007010c020c000000000000000000000000000'
        '00000000000000000000100656f1e1e0000009d61a7c00000003e862817';
    final frame = Uint8List.fromList(
      List.generate(frameHex.length ~/ 2, (i) {
        return int.parse(frameHex.substring(i * 2, i * 2 + 2), radix: 16);
      }),
    );
    final parsed = parseFrame(frame, profile: BandProfile.gen5)!;
    final inner = parsed.inner;
    final sample = sampleFromGen5Historical(parseGen5Historical(inner));
    expect(sample, isNotNull);

    const recTs = 1780916150;
    final raw = RawRecord(
      counter: sample!.counter,
      packetType: PacketType.historicalData,
      hex: _bytesToHex(inner),
      capturedAt: recTs * 1000,
      recTs: recTs,
    );

    await LocalDb.commitSyncBatch([raw], [sample]);

    final db = await LocalDb.instance;
    final rows = await db.query(
      'decoded_onehz',
      where: 'rec_ts = ?',
      whereArgs: [recTs],
    );
    expect(rows.length, 1);
    expect(rows.first['hr'], 102);
    expect(rows.first['counter'], sample.counter);
    // MT-12: the aux temperature channels and the band's signal-quality figure
    // reach SQLite. Channel index, not a body part — nothing reads them.
    expect(rows.first['temp_ch2_c'], 24.7);
    expect(rows.first['temp_ch3_c'], 26.5);
    expect(rows.first['signal_quality_logvar'], isNotNull);
    // The record's own sub-second, and the band's own wake/sleep envelope
    // (raw 2-bit code, 0 = wake here). Both were decoded and dropped by the
    // mapper until now; both are stored and read by nothing. The envelope is
    // CORROBORATION, never a stage — see Sample.bandSleepState.
    expect(rows.first['ts_subsec'], 18022);
    expect(rows.first['band_sleep_state'], 0);
    // The band's own calibrated °C reading is real and is kept…
    expect((rows.first['skin_temp_c'] as num).toDouble(), closeTo(30.57, 1e-9));
    // …but this second stores NO wear state and NO HR-validity claim, even
    // though the capture's body-15 bit7 is SET and its body-60 bits 0-1 read
    // 0. Both of those readings are disproven (see sampleFromGen5Historical),
    // so the columns must be NULL rather than "valid" / "off wrist".
    expect(rows.first['on_wrist'], isNull);
    expect(rows.first['hr_valid'], isNull);

    final rr = await db.query(
      'decoded_rr',
      where: 'rec_ts = ?',
      whereArgs: [recTs],
    );
    expect(rr.length, 2);
    expect([for (final r in rr) r['rr_ms']], containsAll([602, 613]));
  });

  // Absent gravity is stored as NULL (schema v39), NOT as a real 0 g vector.
  // It used to be `?? 0` into a REAL NOT NULL column, which put a fabricated
  // measurement in the durable ledger. `derive_prepare` maps the NULL back to
  // the positional absent marker exact (0,0,0) — no real gravity vector has
  // zero magnitude, and every decoder that emits one gates on magSq >= 0.25 —
  // and `Substrate.accelPresentAt` is what stops THAT being read as a
  // measurement. See substrate_accel_absence_test.dart: without it, a night of
  // these scores as perfect immobility and fabricates a staged sleep window.
  test('v18 sample with null accel persists with the accel ABSENT', () async {
    const unix = 1785801600;
    const counter = 42;
    final inner = _buildGen5V18LenientInner(unix: unix, counter: counter, hr: 72);
    // Built directly rather than decoded: what this test pins is the
    // PERSISTENCE of a null-accel sample, independent of which decoder produced
    // it. Protocol emits exactly this shape for a v18 whose gravity vector
    // fails the magnitude gate — the rest of the second is kept.
    final sample = Sample(tsEpoch: unix, counter: counter, hr: 72);
    expect(sample.ax, isNull);

    final raw = RawRecord(
      counter: counter,
      packetType: PacketType.historicalData,
      hex: _bytesToHex(inner),
      capturedAt: unix * 1000,
      recTs: unix,
    );
    await LocalDb.commitSyncBatch([raw], [sample]);

    final db = await LocalDb.instance;
    final rows = await db.query(
      'decoded_onehz',
      where: 'rec_ts = ?',
      whereArgs: [unix],
    );
    expect(rows.length, 1);
    expect(rows.first['hr'], 72);
    expect(rows.first['ax'], isNull);
    expect(rows.first['ay'], isNull);
    expect(rows.first['az'], isNull);
    // gen5 has no equivalent of the gen4 optical/thermal ADCs, so these are
    // ALWAYS absent there. Storing 0 made every gen5 temperature and SpO2
    // metric a computation over a constant zero series.
    expect(rows.first['spo2_red_raw'], isNull);
    expect(rows.first['spo2_ir_raw'], isNull);
    expect(rows.first['skin_temp_raw'], isNull);
  });

  // The -50.00 °C sentinel is the sensor saying "I have nothing", and it must
  // reach the ledger as NULL. Stored verbatim it is a number 70 °C below any
  // wrist sitting in a column readers are entitled to treat as a temperature —
  // the exact shape of the fabrication AGENTS.md §3.3 forbids. Nulling one
  // field never costs the second: HR and the counter still land.
  test('a v18 second whose skin temp is the sentinel stores NULL, not -50',
      () async {
    const unix = 1785900000;
    const counter = 77;
    final inner = _buildGen5V18DecodableInner(
      unix: unix,
      counter: counter,
      skinTempRaw: -5000, // the AS6221 unavailable/error code
      hrQualityFlags: 0xFF, // every disproven bit set…
      sleepStateByte: 0x03, // …on both bytes
    );
    final sample = sampleFromGen5Historical(parseGen5Historical(inner));
    expect(sample, isNotNull);

    await LocalDb.commitSyncBatch([
      RawRecord(
        counter: counter,
        packetType: PacketType.historicalData,
        hex: _bytesToHex(inner),
        capturedAt: unix * 1000,
        recTs: unix,
      ),
    ], [
      sample,
    ]);

    final db = await LocalDb.instance;
    final rows = await db.query(
      'decoded_onehz',
      where: 'rec_ts = ?',
      whereArgs: [unix],
    );
    expect(rows, hasLength(1));
    expect(rows.first['skin_temp_c'], isNull);
    expect(rows.first['on_wrist'], isNull);
    expect(rows.first['hr_valid'], isNull);
    expect(rows.first['hr'], 61, reason: 'the rest of the second survives');

    // …and it reads back absent through the typed seam too, rather than as a
    // temperature, an "off wrist" or an "HR invalid".
    final s = (await LocalDb.samplesInRange(unix, unix)).single;
    expect(s.skinTempC, isNull);
    expect(s.onWrist, isNull);
    expect(s.hrValid, isNull);
  });

  // A REAL sub-zero reading is a reading. The sentinel check is exact, so an
  // honest cold-wrist value must not be swallowed along with it.
  test('a genuine sub-zero skin temperature still persists', () async {
    const unix = 1785900060;
    const counter = 78;
    final inner = _buildGen5V18DecodableInner(
      unix: unix,
      counter: counter,
      skinTempRaw: -1234,
    );
    final sample = sampleFromGen5Historical(parseGen5Historical(inner));
    await LocalDb.commitSyncBatch([
      RawRecord(
        counter: counter,
        packetType: PacketType.historicalData,
        hex: _bytesToHex(inner),
        capturedAt: unix * 1000,
        recTs: unix,
      ),
    ], [
      sample,
    ]);

    final db = await LocalDb.instance;
    final rows = await db.query(
      'decoded_onehz',
      where: 'rec_ts = ?',
      whereArgs: [unix],
    );
    expect(
      (rows.single['skin_temp_c'] as num).toDouble(),
      closeTo(-12.34, 1e-9),
    );
  });

  test('R10-lite + complete preferred → no decoded_onehz row', () async {
    const ts = 1780000100;
    const counter = 99;
    final inner = _buildR10LiteInner(ts: ts, counter: counter, hr: 65);
    final preferred = Sample(
      tsEpoch: ts,
      counter: counter,
      hr: 65,
      ax: 0.1,
      ay: -0.2,
      az: 0.95,
      spo2RedRaw: 100,
      spo2IrRaw: 200,
      skinTempRaw: 300,
    );
    expect(preferred.hasDecodedOneHz, isTrue);
    final raw = RawRecord(
      counter: counter,
      packetType: PacketType.historicalData,
      hex: _bytesToHex(inner),
      capturedAt: ts * 1000,
      recTs: ts,
    );

    await LocalDb.commitSyncBatch([raw], [preferred]);

    final db = await LocalDb.instance;
    final rows = await db.query(
      'decoded_onehz',
      where: 'rec_ts = ?',
      whereArgs: [ts],
    );
    expect(rows, isEmpty);
  });

  test('full gen4 R24 sample still persists', () async {
    const ts = 1780000200;
    const counter = 5001;
    final sample = Sample(
      tsEpoch: ts,
      counter: counter,
      hr: 70,
      rrIntervalsMs: [800],
      ax: 0.1,
      ay: -0.2,
      az: 0.95,
      spo2RedRaw: 100,
      spo2IrRaw: 200,
      skinTempRaw: 300,
    );
    // Minimal non-R10 historical hex — R24 decode won't match, but preferred
    // has full gen4 optics so _decodeOneHzSample returns it immediately.
    final raw = RawRecord(
      counter: counter,
      packetType: PacketType.historicalData,
      hex: '2f18' '00' * 20,
      capturedAt: ts * 1000,
      recTs: ts,
    );

    await LocalDb.commitSyncBatch([raw], [sample]);

    final db = await LocalDb.instance;
    final rows = await db.query(
      'decoded_onehz',
      where: 'rec_ts = ?',
      whereArgs: [ts],
    );
    expect(rows.length, 1);
    expect(rows.first['hr'], 70);
    expect(rows.first['spo2_red_raw'], 100);
  });
  });

  // CodeRabbit: the R10-lite case asserted only ABSENCE from `decoded_onehz`,
  // which would also pass if the record were dropped entirely. Retention in
  // `samples` is the other half of that contract.
  test('an R10-lite record is excluded from decoded_onehz but RETAINED in samples',
      () async {
    const ts = 1780000300;
    const counter = 4242;
    final inner = _buildR10LiteInner(ts: ts, counter: counter, hr: 71);
    final sample = Sample(tsEpoch: ts, counter: counter, hr: 71);
    final raw = RawRecord(
      counter: counter,
      packetType: PacketType.historicalData,
      hex: _bytesToHex(inner),
      capturedAt: ts * 1000,
      recTs: ts,
    );
    await LocalDb.commitSyncBatch([raw], [sample]);

    final db = await LocalDb.instance;
    expect(
      await db.query('decoded_onehz', where: 'rec_ts = ?', whereArgs: [ts]),
      isEmpty,
      reason: 'hr-only R10-lite is not 1 Hz substrate',
    );
    expect(
      await db.query('samples', where: 'counter = ?', whereArgs: [counter]),
      hasLength(1),
      reason: 'excluded from the substrate is NOT the same as discarded',
    );
  });

  test('an R10-lite record KEEPS its R-R beats — they have nowhere else to go',
      () async {
    const ts = 1780000320;
    const counter = 4343;
    final inner = _buildR10LiteInner(ts: ts, counter: counter, hr: 58);
    final sample = Sample(
      tsEpoch: ts,
      counter: counter,
      hr: 58,
      rrIntervalsMs: const [1010, 1030],
    );
    final raw = RawRecord(
      counter: counter,
      packetType: PacketType.historicalData,
      hex: _bytesToHex(inner),
      capturedAt: ts * 1000,
      recTs: ts,
    );
    await LocalDb.commitSyncBatch([raw], [sample]);

    final db = await LocalDb.instance;
    // Still out of the 1 Hz substrate — no accel, no optics.
    expect(
      await db.query('decoded_onehz', where: 'rec_ts = ?', whereArgs: [ts]),
      isEmpty,
    );
    // But the beats land. `samples` is (counter, ts, hr) and cannot hold them,
    // the record commits as decoded so it is never archived, and the band is
    // then acked to trim it — dropping them here was permanent, not degraded.
    final rr = await db.query('decoded_rr',
        where: 'rec_ts = ?', whereArgs: [ts], orderBy: 'beat_index ASC');
    expect([for (final r in rr) r['rr_ms']], [1010, 1030]);
    // Coverage claims only what was banked: the beats, never 1 Hz HR for a
    // second with no decoded_onehz row.
    final cov = await db.query('device_coverage',
        where: 'start_ts <= ? AND end_ts > ?', whereArgs: [ts, ts]);
    final signals = {for (final c in cov) c['signal']};
    expect(signals, contains('rrIntervals'));
    expect(signals, isNot(contains('hr1Hz')));
  });

  // Protects the hex-conversion fallback in `LocalDb._decodeOneHzSample`: when
  // the raw hex cannot be parsed, a timestamp-valid preferred Sample must still
  // reach `decoded_onehz` rather than the record being lost.
  test('unparseable raw hex still persists a timestamp-valid preferred Sample',
      () async {
    const ts = 1780000400;
    const counter = 5150;
    final raw = RawRecord(
      counter: counter,
      packetType: PacketType.historicalData,
      hex: 'zzzz-not-hex',
      capturedAt: ts * 1000,
      recTs: ts,
    );
    final sample = Sample(
      tsEpoch: ts,
      counter: counter,
      hr: 66,
      rrIntervalsMs: const [910],
    );
    await LocalDb.commitSyncBatch([raw], [sample]);

    final db = await LocalDb.instance;
    final rows =
        await db.query('decoded_onehz', where: 'rec_ts = ?', whereArgs: [ts]);
    expect(rows, hasLength(1));
    expect(rows.first['hr'], 66);
  });
}
