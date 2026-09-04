// The mandatory adapter-signal test (adapter.dart:251-257), adapted for
// WhoopFramedAdapter: `run()` is unwired in M1 (see whoop_gen4.dart's own
// header), so there is no BandEvent stream to replay. What CAN be verified
// without touching the sealed protocol package is that every declared signal
// maps to a real `decoded_onehz` column — cross-checked through the actual
// write path (LocalDb.commitSyncBatch), not the wire offsets.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart' show ReplayBandLink;
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/ble/adapters/whoop_gen4.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'whoop_gen4_signals_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('every declared signal appears as a populated decoded_onehz column',
      () async {
    final adapter = WhoopFramedAdapter(
      BleEngine(onRecord: (_, _) async {}, onState: (_) {}),
      kWhoopGen4,
    );

    final raw = RawRecord(
      counter: 1,
      packetType: 47,
      hex: '2f18aabbccdd',
      capturedAt: 1750000000000,
      recTs: 1750000000,
    );
    final sample = Sample(
      tsEpoch: 1750000000,
      counter: 1,
      hr: 62,
      rrIntervalsMs: const [820, 810],
      ax: 0.1,
      ay: 0.2,
      az: 0.98,
      spo2RedRaw: 12345,
      spo2IrRaw: 23456,
      skinTempRaw: 3456,
    );
    expect(sample.hasDecodedOneHz, isTrue,
        reason: 'the fixture must exercise the direct-write path, not a '
            're-decode of the (fake) hex');

    await LocalDb.commitSyncBatch([raw], [sample]);

    final db = await LocalDb.instance;
    final row = (await db.query('decoded_onehz')).single;

    // signal -> the column it actually feeds, per db.dart's _queueDecodedOneHz.
    const columnForSignal = <InputSignal, List<String>>{
      InputSignal.hr1Hz: ['hr'],
      InputSignal.rrIntervals: [], // checked against decoded_rr below instead
      InputSignal.accel1Hz: ['ax', 'ay', 'az'],
      InputSignal.ppgRedIr: ['spo2_red_raw', 'spo2_ir_raw'],
      InputSignal.skinTempRaw: ['skin_temp_raw'],
    };
    for (final signal in adapter.signals.keys) {
      for (final col in columnForSignal[signal] ?? const []) {
        expect(row[col], isNotNull,
            reason: '$signal declares $col, which must not be a '
                'permanently-empty card');
      }
    }
    // And the converse: every non-RR column this fixture set is covered by a
    // declared signal — nothing here is undeclared free data.
    expect(adapter.signals.keys.toSet(), columnForSignal.keys.toSet());

    final rr = await db.query('decoded_rr');
    expect(rr, hasLength(2),
        reason: 'InputSignal.rrIntervals declares beats that must land in '
            'decoded_rr');
  });

  test('run() is honestly unwired, not silently empty', () {
    final adapter = WhoopFramedAdapter(
      BleEngine(onRecord: (_, _) async {}, onState: (_) {}),
      kWhoopGen4,
    );
    expect(() => adapter.run(ReplayBandLink()), throwsUnsupportedError);
  });
}
