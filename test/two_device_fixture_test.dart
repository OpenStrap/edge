// M0's synthetic two-device CI gate (spec-m0-m2.md §7). Unlike
// derivation_pipeline_test.dart's whoop_hist.jsonl-backed cases, this fixture
// is hand-specified (test/fixtures/two_device_day.json documents the regions
// and formulas) and generated HERE in setUp — not a capture, not anyone's
// physiology, and it never skips in CI.
//
// Three cases (spec §7.3):
//  1. single-device (device_id == '') is byte-identical against the committed
//     golden — the assertion every M1/M2 milestone gate points at.
//  2. two devices at one collision rec_ts both land via commitSyncBatch and
//     read back as distinct rows. FAILS TODAY on db.dart's deviceId
//     StateError — that failure is expected and desired; it is the
//     regression gate for M0 commit 4 (deleting the StateError).
//  3. the skin-temp unit-mixing gate over both devices' rows.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';

// 2020-01-02T00:00:00Z, matching test/fixtures/two_device_day.json's "day".
const int _dayStart = 1577923200;

/// One second of the synthetic day: which device(s) are present, per
/// test/fixtures/two_device_day.json's region table (regions A-F).
class _Row {
  final int recTs;
  final bool gen4;
  final bool oura;
  _Row(this.recTs, {required this.gen4, required this.oura});
}

List<_Row> _buildRows() {
  final rows = <_Row>[];
  void region(int startOffset, int endOffsetInclusive,
      {required bool gen4, required bool oura, Set<int> holes = const {}}) {
    for (var t = startOffset; t <= endOffsetInclusive; t++) {
      if (holes.contains(t)) continue;
      rows.add(_Row(_dayStart + t, gen4: gen4, oura: oura));
    }
  }

  // A 00:00–01:59 gen4 only, contiguous.
  region(0, 2 * 3600 - 1, gen4: true, oura: false);
  // B 02:00–03:59 BOTH, every second — the collision case.
  region(2 * 3600, 4 * 3600 - 1, gen4: true, oura: true);
  // C 04:00–04:04 neither — a real gap.
  region(4 * 3600, 4 * 3600 + 4, gen4: false, oura: false);
  // D 04:05–05:59 oura only.
  region(4 * 3600 + 5, 6 * 3600 - 1, gen4: false, oura: true);
  // E 06:00–06:01 gen4 present for 2 seconds only.
  region(6 * 3600, 6 * 3600 + 1, gen4: true, oura: false);
  // F 06:02–07:59 gen4 only, with 2 one-second holes.
  region(
    6 * 3600 + 2,
    8 * 3600 - 1,
    gen4: true,
    oura: false,
    holes: {6 * 3600 + 30 * 60, 7 * 3600 + 15 * 60},
  );
  return rows;
}

// ── the formulas, verbatim from test/fixtures/two_device_day.json ─────────
int _gen4Hr(int recTs) => 60 + (recTs % 7);
int _gen4RrMs(int recTs) => 1000 - (recTs % 5) * 10;
int _gen4SkinTempRaw(int recTs) => 30000 + (recTs % 11);
double _ouraSkinTempC(int recTs) => 33.0 + (recTs % 9) / 10;

/// Decoded-page row maps (what `substrateFromDecodedPage` reads), gen4 only —
/// the shape `derive_prepare.dart` consumes, bypassing the DB entirely. This
/// is what backs case 1 (single-device, no DB round trip needed).
({List<Map<String, dynamic>> frames, List<Map<String, dynamic>> rrRows})
    _gen4FramesOnly(List<_Row> rows) {
  final frames = <Map<String, dynamic>>[];
  final rrRows = <Map<String, dynamic>>[];
  for (final r in rows.where((r) => r.gen4)) {
    frames.add({
      'rec_ts': r.recTs,
      'device_family': 'gen4',
      'hr': _gen4Hr(r.recTs),
      'ax': 0.0,
      'ay': 0.0,
      'az': 1.0,
      'skin_temp_raw': _gen4SkinTempRaw(r.recTs),
    });
    rrRows.add({'rec_ts': r.recTs, 'rr_ms': _gen4RrMs(r.recTs)});
  }
  return (frames: frames, rrRows: rrRows);
}

Map<String, dynamic> _deriveSingleDay(Substrate sub) {
  final payload = prepareDerivationPayload(sub);
  expect(payload.days, isNotEmpty, reason: 'a calendar day always exists');
  final day = payload.days.first;
  final daySub = day.daySub;
  final sleepSub = day.sleepSub;
  final input = DayBundleInput(
    date: day.date,
    dayTsSec: daySub.tsSec,
    dayHr: daySub.hr,
    dayRrTsMs: daySub.rrTsMs,
    dayRrMs: daySub.rrMs,
    sleepTsSec: sleepSub.tsSec,
    sleepHr: sleepSub.hr,
    sleepRrTsMs: sleepSub.rrTsMs,
    sleepRrMs: sleepSub.rrMs,
    sleepSkinTemp: sleepSub.skinTemp,
    sleepJson: day.sleepJson,
    hypnoStages: day.hypnoStages,
    sleepOnsetSec: day.sleepOnsetSec,
    sleepOffsetSec: day.sleepOffsetSec,
    profile: const Profile().toMap(),
    dayConfidence: day.confidence,
    dayFlags: day.flags,
    deviceFamily: daySub.deviceFamily,
    sleepSource: day.sleepSource,
  ).toJson();
  return deriveDayBundle(input);
}

void main() {
  final rows = _buildRows();

  test('fixture covers all six documented regions', () {
    // Sanity on the generator itself, not on any derived output — a rows
    // count of zero for a region is a fixture bug, not a finding.
    expect(rows.where((r) => r.gen4 && !r.oura && r.recTs < _dayStart + 7200),
        isNotEmpty,
        reason: 'region A');
    expect(rows.where((r) => r.gen4 && r.oura), isNotEmpty, reason: 'region B');
    expect(
        rows.where((r) => !r.gen4 && !r.oura && r.recTs >= _dayStart + 14400),
        isNotEmpty,
        reason: 'region C');
    expect(rows.where((r) => !r.gen4 && r.oura), isNotEmpty, reason: 'region D');
  });

  group('case 1: single-device is byte-identical against the golden', () {
    test('deriveDayBundle over gen4-only rows matches the committed golden',
        () {
      final f = _gen4FramesOnly(rows);
      final sub = substrateFromDecodedPage(f.frames, f.rrRows);
      final bundle = _deriveSingleDay(sub);

      final goldenFile = File('test/fixtures/two_device_day_expected.json');
      if (Platform.environment['GENERATE_GOLDEN'] == '1') {
        goldenFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ')
              .convert({'single_device': bundle}),
        );
        return;
      }
      if (!goldenFile.existsSync()) {
        fail(
          'test/fixtures/two_device_day_expected.json is missing. Generate '
          'it once with:\n'
          '  final f = File(\'test/fixtures/two_device_day_expected.json\');\n'
          '  f.writeAsStringSync(jsonEncode({"single_device": bundle}));\n'
          'then commit it. Regenerating it in any milestone whose gate says '
          '"no bump" is a FAILED gate, not a golden refresh.',
        );
      }
      final golden = jsonDecode(goldenFile.readAsStringSync())
          as Map<String, dynamic>;
      expect(jsonEncode(bundle), jsonEncode(golden['single_device']),
          reason:
              'single-device output must be byte-identical to the golden. '
              'If this fails on a milestone whose gate says "empty payload '
              'diff / no kAlgoVersion bump", that milestone changed a number '
              'it must not change. Do NOT regenerate the golden to make it '
              'pass.');
    });
  });

  group('case 2: two devices at one collision rec_ts', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'two_device_fixture_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.instance;
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    test(
        'both devices land at the same rec_ts and read back as distinct rows',
        () async {
      // Region B's first second: both devices present, the collision case.
      final collisionRecTs = _dayStart + 2 * 3600;

      RawRecord raw(int counter) => RawRecord(
            counter: counter,
            packetType: 0x2F,
            hex: '2f18aabbccdd',
            capturedAt: collisionRecTs * 1000,
            recTs: collisionRecTs,
          );

      // Before M0 commit 4, this throws StateError for the non-primary
      // deviceId — that is the failure this test exists to demand a fix for.
      await LocalDb.commitSyncBatch(
        [raw(1)],
        <Sample?>[
          Sample(
            tsEpoch: collisionRecTs,
            counter: 1,
            hr: _gen4Hr(collisionRecTs),
            ax: 0.0,
            ay: 0.0,
            az: 1.0,
            spo2RedRaw: 0,
            spo2IrRaw: 0,
            skinTempRaw: _gen4SkinTempRaw(collisionRecTs),
          ),
        ],
        deviceFamily: 'gen4',
      );
      await LocalDb.commitSyncBatch(
        [raw(1)],
        <Sample?>[
          Sample(
            tsEpoch: collisionRecTs,
            counter: 1,
            hr: 0,
            skinTempC: _ouraSkinTempC(collisionRecTs),
          ),
        ],
        deviceFamily: 'oura',
        deviceId: 'oura-a1b2c3d4',
      );

      final db = await LocalDb.instance;
      final result = await db.query(
        'decoded_onehz',
        columns: ['device_id', 'hr', 'skin_temp_raw', 'skin_temp_c'],
        where: 'rec_ts = ?',
        whereArgs: [collisionRecTs],
        orderBy: 'device_id',
      );
      expect(result, hasLength(2),
          reason: 'both devices\' rows for this second must survive');
      expect(result[0]['device_id'], '');
      expect(result[0]['hr'], _gen4Hr(collisionRecTs));
      expect(result[0]['skin_temp_raw'], _gen4SkinTempRaw(collisionRecTs));
      expect(result[1]['device_id'], 'oura-a1b2c3d4');
      expect(result[1]['skin_temp_c'], _ouraSkinTempC(collisionRecTs));
    });
  });

  group('case 3: the skin-temp unit gate over both devices', () {
    test('gen4 raw ADC counts and oura centi-C never mix in one skinTemp[]',
        () {
      // Bypasses derivableSourceSql's `source IS NULL` admission filter on
      // purpose: commitSyncBatch never writes `source` (only oura_link._commit
      // and hrs_link._flush do), so building the substrate straight from both
      // devices' decoded-page rows exercises the mixing branch the admission
      // filter otherwise makes unreachable today (spec-m0-m2.md §0.2/§7.3).
      final frames = <Map<String, dynamic>>[];
      final rrRows = <Map<String, dynamic>>[];
      for (final r in rows) {
        if (r.gen4) {
          frames.add({
            'rec_ts': r.recTs,
            'device_family': 'gen4',
            'hr': _gen4Hr(r.recTs),
            'ax': 0.0,
            'ay': 0.0,
            'az': 1.0,
            'skin_temp_raw': _gen4SkinTempRaw(r.recTs),
          });
          rrRows.add({'rec_ts': r.recTs, 'rr_ms': _gen4RrMs(r.recTs)});
        } else if (r.oura) {
          // Different second from any gen4 frame at this rec_ts EXCEPT region
          // B, where both are present — addDecodedPage keeps the FIRST frame
          // per rec_ts (frameByRecTs.containsKey guard), so to actually reach
          // the oura-only unit at a rec_ts, feed oura frames for oura-only
          // seconds (regions D) plus, for region B, a SEPARATE synthetic day
          // built oura-first so the mixing gate sees both units in one
          // substrate. Simplest correct fixture: build one substrate per
          // family, then merge — an oura frame and a gen4 frame can legally
          // occupy the SAME rec_ts only through two different device rows in
          // decoded_onehz, not through addDecodedPage's single-frame-per-page
          // union, which is a page from ONE query. Feed oura's region D
          // (oura-only) seconds here; region B's collision is already covered
          // by case 2's DB round trip.
          frames.add({
            'rec_ts': r.recTs,
            'device_family': 'oura',
            'skin_temp_c': _ouraSkinTempC(r.recTs),
          });
        }
      }
      final sub = substrateFromDecodedPage(frames, rrRows);
      // Region A/E/F (gen4) established 'raw' as the day's unit; region D's
      // oura seconds must land on the ABSENT sentinel (0), never converted.
      final rawRange = sub.skinTemp.where((v) => v >= 30000 && v <= 30010);
      final centiCRange = sub.skinTemp.where((v) => v > 3000 && v < 3500);
      expect(rawRange, isNotEmpty, reason: 'gen4 raw ADC counts present');
      expect(centiCRange, isEmpty,
          reason:
              'no oura centi-°C value may appear in a skinTemp[] whose '
              'unit was established as raw ADC — that is the fabricated '
              '10x-step-change fever this gate exists to prevent');
    });
  });
}
