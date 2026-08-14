// The safe-trim invariant, for records that decode only PARTIALLY.
//
// THE BUG THIS PINS. A WHOOP 5.0 history record decodes to heart rate and time
// but carries no accelerometer / RR / SpO2 where 4.0 keeps them, so its Sample
// leaves those null. That made it fail `Sample.hasDecodedOneHz`, which sent
// `_decodeOneHzSample` on to re-decode the raw hex with the GEN4 decoder — which
// cannot read a gen5 record either. It returned null, `_queueDecodedOneHz` wrote
// nothing, and the very same transaction still advanced `strap_trim`.
//
// Net effect: the band was told (via the HISTORY_END ACK) that it could erase
// records that had never reached `decoded_onehz` — the table derivation actually
// reads. Every gen5 sync would have looked like it worked and banked nothing.
//
// Two things have to hold, and both are tested here:
//   1. a partial sample still produces a `decoded_onehz` row, so the data the
//      band is about to erase is genuinely captured;
//   2. gen4 behaviour is completely unchanged — a complete sample still wins,
//      and a genuinely undecodable record still writes no row.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

/// What the gen5 decoder can honestly produce: time, counter, HR, skin temp.
/// Accel / RR / SpO2 stay null — absent, not zero.
Sample _gen5Partial(int ts, int counter) =>
    Sample(tsEpoch: ts, counter: counter, hr: 77, skinTempRaw: 3302);

/// A fully-decoded gen4 sample, for the control cases.
Sample _gen4Complete(int ts, int counter) => Sample(
  tsEpoch: ts,
  counter: counter,
  hr: 61,
  rrIntervalsMs: const [900, 910],
  ax: 0.1,
  ay: 0.2,
  az: 0.97,
  spo2RedRaw: 1234,
  spo2IrRaw: 5678,
  skinTempRaw: 3100,
);

/// Hex that no decoder in this repo can read — stands in for a gen5 inner,
/// whose real bytes the gen4 decoder also refuses.
RawRecord _raw(int ts, int counter) => RawRecord(
  counter: counter,
  packetType: 47,
  hex: 'aa$counter${'00' * 8}',
  capturedAt: ts * 1000,
  recTs: ts,
);

Future<int> _oneHzCount() async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM decoded_onehz');
  return (rows.first['n'] as int?) ?? 0;
}

Future<Map<String, Object?>?> _oneHzAt(int recTs) async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    'SELECT * FROM decoded_onehz WHERE rec_ts = ?',
    [recTs],
  );
  return rows.isEmpty ? null : rows.first;
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('openstrap_gen5_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  setUp(() async {
    final db = await LocalDb.instance;
    // raw_records / decoded_rr are created lazily on first insert, so on the
    // first pass they do not exist yet. Missing is as clean as empty.
    for (final t in ['decoded_onehz', 'decoded_rr', 'raw_records']) {
      try {
        await db.delete(t);
      } catch (_) {/* table not created yet */}
    }
  });

  tearDownAll(() async {
    await LocalDb.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('a PARTIAL sample still lands in decoded_onehz', () async {
    // The regression itself. Pre-fix this committed zero rows while still
    // advancing the trim cursor — the band erases, we keep nothing.
    const ts = 1577582585;
    await LocalDb.commitSyncBatch([_raw(ts, 10)], [_gen5Partial(ts, 10)]);

    final row = await _oneHzAt(ts);
    expect(row, isNotNull,
        reason: 'a partial decode must still be banked before the ACK');
    expect(row!['hr'], 77);
    expect(row['counter'], 10);
  });

  test('the partial row carries the fields we DID decode', () async {
    const ts = 1577582600;
    await LocalDb.commitSyncBatch([_raw(ts, 11)], [_gen5Partial(ts, 11)]);

    final row = (await _oneHzAt(ts))!;
    expect(row['hr'], 77);
    expect(row['skin_temp_raw'], 3302);
  });

  test('undecoded motion columns are zero-filled, NOT invented', () async {
    // Documents the cost of the fix rather than hiding it: the decoded_onehz
    // schema has no null motion, so an absent axis is stored as 0. Anything
    // reading these columns for a gen5 record is reading a placeholder, not a
    // measurement — which is exactly why the raw frame is also archived.
    const ts = 1577582610;
    await LocalDb.commitSyncBatch([_raw(ts, 12)], [_gen5Partial(ts, 12)]);

    final row = (await _oneHzAt(ts))!;
    expect(row['ax'], 0);
    expect(row['ay'], 0);
    expect(row['az'], 0);
    expect(row['spo2_red_raw'], 0);
    expect(row['spo2_ir_raw'], 0);
  });

  test('a COMPLETE sample is unchanged — gen4 keeps every field', () async {
    const ts = 1577582700;
    await LocalDb.commitSyncBatch([_raw(ts, 20)], [_gen4Complete(ts, 20)]);

    final row = (await _oneHzAt(ts))!;
    expect(row['hr'], 61);
    expect(row['spo2_red_raw'], 1234);
    expect(row['spo2_ir_raw'], 5678);
    expect(row['skin_temp_raw'], 3100);
    expect((row['az'] as num).toDouble(), closeTo(0.97, 1e-9));
  });

  test('a complete sample still writes its RR beats', () async {
    const ts = 1577582800;
    await LocalDb.commitSyncBatch([_raw(ts, 21)], [_gen4Complete(ts, 21)]);

    final db = await LocalDb.instance;
    final rr = await db.rawQuery(
      'SELECT rr_ms FROM decoded_rr WHERE rec_ts = ? ORDER BY beat_index',
      [ts],
    );
    expect(rr.map((r) => r['rr_ms']).toList(), [900, 910]);
  });

  test('a record with NO sample at all still writes no row', () async {
    // The other half of the contract: the fix must not turn "undecodable" into
    // a fabricated row. Nothing decoded ⇒ nothing banked (it goes to the
    // durable archive instead, which ble_engine owns).
    const ts = 1577582900;
    await LocalDb.commitSyncBatch([_raw(ts, 30)], [null]);
    expect(await _oneHzCount(), 0);
  });

  test('partial and complete samples coexist in one batch', () async {
    // A real gen5 offload is a burst; a mixed batch must bank both kinds.
    const a = 1577583000, b = 1577583001;
    await LocalDb.commitSyncBatch(
      [_raw(a, 40), _raw(b, 41)],
      [_gen5Partial(a, 40), _gen4Complete(b, 41)],
    );

    expect(await _oneHzCount(), 2);
    expect((await _oneHzAt(a))!['hr'], 77);
    expect((await _oneHzAt(b))!['hr'], 61);
  });
}
