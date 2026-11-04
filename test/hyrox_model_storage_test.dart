// HYROX model, validation, storage invariants, and schema migration ladder
// integration — the mirror of the triathlon storage suite (PR #648).
//
// Runs against the real sqflite_ffi database — the repo standard for DB tests.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/state/hyrox_reconciler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/hyrox_plan.dart';
import 'package:openstrap_edge/data/hyrox_store.dart';

// exportDaysDb resolves the temp dir through path_provider, which needs a
// platform channel — fake it, same pattern as db_paged_import_export_test.
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

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tmp = await Directory.systemTemp.createTemp('openstrap_hyrox_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDownAll(() async {
    await LocalDb.close();
  });

  group('HyroxPlan pure model validation', () {
    test('a race plan builds the fixed eight rounds with station targets', () {
      final plan = HyroxPlan.race('hyrox');
      expect(plan.validate(), isNull);
      expect(plan.segments.length, 8);
      expect(plan.segments[0].kind, HyroxSegmentKind.hyroxRound);
      expect(plan.segments[0].station, HyroxStation.skierg);
      expect(plan.segments[0].roundIndex, 1);
      expect(plan.segments[0].plannedDistanceM, 1000.0);
      expect(plan.segments[0].plannedCal, 50);
      expect(plan.segments[1].station, HyroxStation.sledPush);
      expect(plan.segments[1].plannedDistanceM, 50.0);
      expect(plan.segments[4].station, HyroxStation.rowing);
      expect(plan.segments[5].station, HyroxStation.farmersCarry);
      expect(plan.segments[5].plannedDistanceM, 80.0); // 2x40 m
      expect(plan.segments[6].station, HyroxStation.sandbagLunges);
      expect(plan.segments[7].station, HyroxStation.wallBalls);
      expect(plan.segments[7].roundIndex, 8);
      expect(plan.segments[7].plannedReps, 100);
      expect(plan.segments[7].plannedDistanceM, isNull);
      expect(plan.needsGps, isFalse); // HYROX is an indoor arena event
    });

    test('the doubles preset is the same eight rounds', () {
      final plan = HyroxPlan.race('hyrox_doubles');
      expect(plan.validate(), isNull);
      expect(plan.preset, 'hyrox_doubles');
      expect(plan.segments.length, 8);
      expect(plan.segments[7].station, HyroxStation.wallBalls);
    });

    test('training and custom plans are free-form', () {
      final plan = HyroxPlan.training(const [
        HyroxSegmentPlan(
          kind: HyroxSegmentKind.hyroxRound,
          station: HyroxStation.wallBalls,
          plannedReps: 50,
        ),
        HyroxSegmentPlan(
          kind: HyroxSegmentKind.hyroxRound,
          station: HyroxStation.skierg,
          plannedCal: 25,
        ),
      ]);
      expect(plan.validate(), isNull);
      expect(plan.isTraining, isTrue);
      expect(plan.segments[0].roundIndex, isNull);

      final custom = HyroxPlan.custom(const [
        HyroxSegmentPlan(
          kind: HyroxSegmentKind.hyroxRound,
          station: HyroxStation.rowing,
          plannedDistanceM: 500,
        ),
      ]);
      expect(custom.validate(), isNull);
      expect(custom.preset, 'custom');
    });

    test('validation catches broken plans', () {
      final empty = HyroxPlan.training(const []);
      expect(empty.validate(), contains('at least one segment'));

      final negativeDistance = HyroxPlan.training(const [
        HyroxSegmentPlan(
          kind: HyroxSegmentKind.hyroxRound,
          station: HyroxStation.sledPush,
          plannedDistanceM: -50,
        ),
      ]);
      expect(negativeDistance.validate(), contains('finite and positive'));

      final zeroReps = HyroxPlan.training(const [
        HyroxSegmentPlan(
          kind: HyroxSegmentKind.hyroxRound,
          station: HyroxStation.wallBalls,
          plannedReps: 0,
        ),
      ]);
      expect(zeroReps.validate(), contains('rep count'));

      final badRound = HyroxPlan.training(const [
        HyroxSegmentPlan(
          kind: HyroxSegmentKind.hyroxRound,
          station: HyroxStation.skierg,
          roundIndex: 0,
        ),
      ]);
      expect(badRound.validate(), contains('round index'));

      final negativeGoal = HyroxPlan.training(const [
        HyroxSegmentPlan(
          kind: HyroxSegmentKind.hyroxRound,
          station: HyroxStation.skierg,
          goalSec: -5,
        ),
      ]);
      expect(negativeGoal.validate(), contains('goal time'));

      // A fixed preset must be exactly the canonical eight rounds in order.
      final wrongOrder = HyroxPlan(
        preset: 'hyrox',
        segments: [
          for (final st in kHyroxStationOrder.reversed)
            HyroxSegmentPlan(
              kind: HyroxSegmentKind.hyroxRound,
              station: st,
              roundIndex: kHyroxStationOrder.indexOf(st) + 1,
            ),
        ],
      );
      expect(wrongOrder.validate(), contains('eight stations in order'));
    });

    test('json round-trip preserves preset, stations and targets', () {
      final plan = HyroxPlan.race(
        'hyrox',
        goalSec: const {HyroxStation.wallBalls: 600},
      );
      final json = plan.toJson();
      expect(json['v'], 1);
      final roundTrip = HyroxPlan.fromJson(json);
      expect(roundTrip, isNotNull);
      expect(roundTrip!.preset, 'hyrox');
      expect(roundTrip.segments, hasLength(8));
      expect(roundTrip.segments[7].station, HyroxStation.wallBalls);
      expect(roundTrip.segments[7].plannedReps, 100);
      expect(roundTrip.segments[7].goalSec, 600);
      expect(roundTrip.segments[0].plannedCal, 50);
    });

    test('wrong-typed fields parse to null without throwing; newer v refused',
        () {
      final bad = HyroxPlan.fromJson({
        'v': 1,
        'preset': 'hyrox',
        'segments': [
          {
            'kind': 'hyrox_round',
            'station': 'skierg',
            'round_index': 'three', // wrong type -> null, not a crash
            'planned_distance_m': '1000', // wrong type -> null
            'planned_reps': 5,
            'planned_cal': null,
            'goal_sec': 300,
          },
        ],
      });
      expect(bad, isNotNull);
      expect(bad!.segments[0].roundIndex, isNull);
      expect(bad.segments[0].plannedDistanceM, isNull);
      expect(bad.segments[0].plannedReps, 5);

      expect(HyroxPlan.fromJson({'v': 99, 'preset': 'hyrox', 'segments': []}),
          isNull);
      expect(HyroxPlan.fromJson({'v': 0, 'preset': 'hyrox', 'segments': []}),
          isNull, reason: 'versions below 1 are refused too');
      expect(HyroxPlan.fromJson({'v': 1, 'preset': 42, 'segments': []}), isNull);
      expect(
        HyroxPlan.fromJson({
          'v': 1,
          'preset': 'hyrox',
          'segments': [
            {'kind': 'not_a_kind', 'station': 'skierg'},
          ],
        }),
        isNull,
      );
    });
  });

  group('HyroxDb storage seam', () {
    Future<Database> freshDb(String name) async {
      LocalDb.dbName = name;
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      return LocalDb.instance;
    }

    HyroxSession armedSession(String id, {int createdAt = 1, String preset = 'hyrox'}) {
      return HyroxSession(
        id: id,
        kind: 'race',
        preset: preset,
        status: 'armed',
        plan: HyroxPlan.race(preset),
        createdAt: createdAt,
        updatedAt: createdAt,
      );
    }

    test('create stores session and pre-populates all eight round rows',
        () async {
      final db = await freshDb('hx_create_test.db');
      await HyroxDb.create(db, armedSession('hx_create_1', createdAt: 1000));
      final read = await HyroxDb.byId(db, 'hx_create_1');
      expect(read, isNotNull);
      expect(read!.status, 'armed');
      expect(read.segments.length, 8);
      expect(read.segments[0].station, HyroxStation.skierg);
      expect(read.segments[0].roundIndex, 1);
      expect(read.segments[0].plannedDistanceM, 1000.0);
      expect(read.segments[0].startTs, isNull);
      expect(read.segments[7].station, HyroxStation.wallBalls);
      expect(read.plan?.preset, 'hyrox');
      await LocalDb.close();
    });

    test('activeSession returns the unfinalized active session', () async {
      final db = await freshDb('hx_active_test.db');
      await HyroxDb.create(db, armedSession('hx_active_1', createdAt: 1000));
      await HyroxDb.startSegment(
        db: db,
        sessionId: 'hx_active_1',
        ts: 2000,
        boundarySource: 'gesture',
      );
      final active = await HyroxDb.activeSession(db);
      expect(active, isNotNull);
      expect(active!.id, 'hx_active_1');
      expect(active.status, 'active');
      expect(active.startTs, 2000);
      await LocalDb.close();
    });

    test('segment save enforces the no-overlap boundary constraint', () async {
      final db = await freshDb('hx_contig_test.db');
      await HyroxDb.create(db, armedSession('hx_contig_1'));
      await HyroxDb.startSegment(
        db: db,
        sessionId: 'hx_contig_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      await HyroxDb.transitionSegment(
        db: db,
        sessionId: 'hx_contig_1',
        currentIdx: 0,
        transitionTs: 2000,
        boundarySource: 'gesture',
      );
      // Try to move round 0's end AFTER round 1's start: overlap, must fail.
      await expectLater(
        HyroxDb.saveSegment(
          db,
          (await HyroxDb.segments(db, 'hx_contig_1'))[0]
              .copyWith(endTs: 2100),
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      final segs = await HyroxDb.segments(db, 'hx_contig_1');
      expect(segs[0].endTs, 2000);
      await LocalDb.close();
    });

    test('finalizing freezes the session and rejects later writes', () async {
      final db = await freshDb('hx_finalize_test.db');
      await HyroxDb.create(db, armedSession('hx_fin_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_fin_1', ts: 1000, boundarySource: 'gesture');
      for (var i = 0; i < 7; i++) {
        await HyroxDb.transitionSegment(
          db: db,
          sessionId: 'hx_fin_1',
          currentIdx: i,
          transitionTs: 2000 + i * 600,
          boundarySource: 'gesture',
        );
      }
      await HyroxDb.finishSegment(
        db: db, sessionId: 'hx_fin_1', ts: 2000 + 7 * 600 + 600,
        boundarySource: 'gesture',
      );
      await HyroxDb.finalize(db, 'hx_fin_1');
      final fin = (await HyroxDb.byId(db, 'hx_fin_1'))!;
      expect(fin.isFinalized, isTrue);
      expect(fin.status, 'finalized');
      expect(fin.totalSec, 2000 + 7 * 600 + 600 - 1000);
      await expectLater(
        HyroxDb.transitionSegment(
          db: db,
          sessionId: 'hx_fin_1',
          currentIdx: 0,
          transitionTs: 9999,
          boundarySource: 'gesture',
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      await expectLater(
        HyroxDb.updateSession(
          db,
          HyroxSession(
            id: fin.id,
            kind: fin.kind,
            preset: fin.preset,
            status: 'discarded',
            plan: fin.plan,
            note: 'oops',
            createdAt: fin.createdAt,
            updatedAt: fin.updatedAt,
          ),
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    test('finalize refuses a session that never finished', () async {
      final db = await freshDb('hx_fin_refuse_test.db');
      await HyroxDb.create(db, armedSession('hx_finref_1'));
      await expectLater(
        HyroxDb.finalize(db, 'hx_fin_refuse_1'),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    test('hyrox tables participate in backup restore and salvage', () {
      expect(LocalDb.restoreTablesForTest,
          containsAllInOrder(['hyrox_session', 'hyrox_segment']));
      expect(LocalDb.salvageTablesForTest,
          containsAllInOrder(['hyrox_session', 'hyrox_segment']));
    });

    test('deleting a day works when no hyrox session exists', () async {
      await freshDb('hx_delete_day_test.db');
      await LocalDb.deleteDays({'2026-01-01'});
      await LocalDb.close();
    });

    test('band-only race: stored taps are reconciled into boundaries',
        () async {
      final db = await freshDb('hx_posthoc_test.db');
      final t0 = 1_000_000;
      await HyroxDb.create(db, armedSession('hx_posthoc_1', createdAt: t0 * 1000));

      Future<void> taps(int first, List<int> offsets) async {
        for (final o in offsets) {
          final ts = first + o;
          await db.insert('band_events', {
            'device_id': '',
            'hex': 'dtap_$ts',
            'event_id': 14,
            'name': 'DOUBLE_TAP',
            'ts': ts,
            'payload_json': '{}',
            'captured_at': ts * 1000,
          });
        }
      }

      // Start 10 min after arming; round 1 (skierg, 300 s floor) runs long
      // enough; then two more accepted bursts. A lone accidental bump and a
      // chained 0/6/12 s sequence must NOT count.
      await taps(t0 + 600, [0, 2, 4]); // accepted: race start
      await taps(t0 + 640, [0]); // lone tap: ignored
      await taps(t0 + 900, [0, 1, 2]); // accepted: closes round 1
      await taps(t0 + 960, [0, 6, 12]); // chained: NOT a burst (12 > 6 window)
      await taps(t0 + 1300, [0, 2, 4]); // accepted: closes round 2

      final reconciler = HyroxReconciler(db);
      final applied = await reconciler.reconcile('hx_posthoc_1', deviceId: '');

      expect(applied, hasLength(3));
      final segs = await HyroxDb.segments(db, 'hx_posthoc_1');
      expect(segs[0].startTs, t0 + 600);
      expect(segs[0].endTs, t0 + 900);
      expect(segs[0].boundarySource, 'posthoc');
      expect(segs[1].startTs, t0 + 900);
      expect(segs[1].endTs, t0 + 1300);
      expect(segs[2].startTs, t0 + 1300);
      expect(segs[2].endTs, isNull);
      final read = await HyroxDb.byId(db, 'hx_posthoc_1');
      expect(read!.startTs, t0 + 600);
      expect(read.status, 'active');

      // Idempotent: the same log a second time adds nothing.
      final again = await reconciler.reconcile('hx_posthoc_1', deviceId: '');
      expect(again, isEmpty);
      await LocalDb.close();
    });

    test('a burst under the round minimum is ignored', () async {
      final db = await freshDb('hx_floor_test.db');
      final t0 = 1_000_000;
      await HyroxDb.create(db, armedSession('hx_floor_1', createdAt: t0 * 1000));

      Future<void> taps(int first) async {
        for (final o in [0, 1, 2]) {
          final ts = first + o;
          await db.insert('band_events', {
            'device_id': '',
            'hex': 'dtap_$ts',
            'event_id': 14,
            'name': 'DOUBLE_TAP',
            'ts': ts,
            'payload_json': '{}',
            'captured_at': ts * 1000,
          });
        }
      }

      // Clears the gate 600 s after arming: this is the START, so no minimum
      // applies to it.
      await taps(t0 + 600);
      // 60 s later a second burst tries to end round 1 (skierg floor 300 s).
      // A round cannot be over, so it must be ignored.
      await taps(t0 + 660);

      final applied = await HyroxReconciler(db).reconcile('hx_floor_1', deviceId: '');
      expect(applied, hasLength(1));
      final segs = await HyroxDb.segments(db, 'hx_floor_1');
      expect(segs[0].startTs, t0 + 600);
      expect(segs[0].endTs, isNull);
      expect(segs[1].startTs, isNull);
      await LocalDb.close();
    });

    test('a discarded race is never rebuilt by the reconciler', () async {
      final db = await freshDb('hx_discarded_test.db');
      final t0 = 1_000_000;
      await HyroxDb.create(db, armedSession('hx_disc_1', createdAt: t0 * 1000));
      final current = (await HyroxDb.byId(db, 'hx_disc_1'))!;
      await HyroxDb.updateSession(
        db,
        HyroxSession(
          id: current.id,
          kind: current.kind,
          preset: current.preset,
          status: 'discarded',
          plan: current.plan,
          createdAt: current.createdAt,
          updatedAt: current.updatedAt,
        ),
      );
      for (final o in [0, 1, 2]) {
        final ts = t0 + 600 + o;
        await db.insert('band_events', {
          'device_id': '',
          'hex': 'dtap_$ts',
          'event_id': 14,
          'name': 'DOUBLE_TAP',
          'ts': ts,
          'payload_json': '{}',
          'captured_at': ts * 1000,
        });
      }
      final applied = await HyroxReconciler(db).reconcile('hx_disc_1', deviceId: '');
      expect(applied, isEmpty);
      expect((await HyroxDb.byId(db, 'hx_disc_1'))!.status, 'discarded');
      await LocalDb.close();
    });

    test('transition and boundary adjustment move both sides atomically',
        () async {
      final db = await freshDb('hx_adjbound_test.db');
      await HyroxDb.create(db, armedSession('hx_adjb_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_adjb_1', ts: 1000, boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_adjb_1', currentIdx: 0,
        transitionTs: 1600, boundarySource: 'gesture');
      await HyroxDb.adjustBoundary(
        db: db, sessionId: 'hx_adjb_1', idx: 0, newTs: 1700);
      final segs = await HyroxDb.segments(db, 'hx_adjb_1');
      expect(segs[0].endTs, 1700);
      expect(segs[1].startTs, 1700);
      // A human correction is 'manual' on BOTH rows.
      expect(segs[0].boundarySource, 'manual');
      expect(segs[1].boundarySource, 'manual');
      // Moving the boundary before round 0's start is refused.
      await expectLater(
        HyroxDb.adjustBoundary(
          db: db, sessionId: 'hx_adjb_1', idx: 0, newTs: 500),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    test('an out-of-order segment is refused by the timeline rule', () async {
      final db = await freshDb('hx_order_test.db');
      await HyroxDb.create(db, armedSession('hx_order_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_order_1', ts: 1000, boundarySource: 'gesture');
      // Round 2 has no start while round 1 never started: prefix rule.
      await expectLater(
        HyroxDb.saveSegment(
          db,
          (await HyroxDb.segments(db, 'hx_order_1'))[2]
              .copyWith(startTs: 1500, endTs: 1600),
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    test('finish only closes the final segment', () async {
      final db = await freshDb('hx_finish_test.db');
      await HyroxDb.create(db, armedSession('hx_finish_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_finish_1', ts: 1000, boundarySource: 'gesture');
      // Round 0 is open but is not the last: finishSegment must refuse.
      await expectLater(
        HyroxDb.finishSegment(
          db: db, sessionId: 'hx_finish_1', ts: 2000,
          boundarySource: 'gesture'),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    test('finalizing refuses an open segment in a finished session', () async {
      final db = await freshDb('hx_openfin_test.db');
      await HyroxDb.create(db, armedSession('hx_openfin_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_openfin_1', ts: 1000, boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_openfin_1', currentIdx: 0,
        transitionTs: 2000, boundarySource: 'gesture');
      // Force the status to finished while round 1 is still open: finalize
      // must refuse rather than freeze a lie.
      await db.update('hyrox_session', {'status': 'finished'},
          where: 'id = ?', whereArgs: ['hx_openfin_1']);
      await expectLater(
        HyroxDb.finalize(db, 'hx_openfin_1'),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    test('a plan field cannot be rewritten through saveSegment', () async {
      final db = await freshDb('hx_planimm_test.db');
      await HyroxDb.create(db, armedSession('hx_planimm_1'));
      await expectLater(
        HyroxDb.saveSegment(
          db,
          (await HyroxDb.segments(db, 'hx_planimm_1'))[0].copyWith(
            plannedReps: 999,
          ),
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    test('a workout cannot be linked twice, and a missing segment refuses',
        () async {
      final db = await freshDb('hx_link_test.db');
      await HyroxDb.create(db, armedSession('hx_link_1'));
      await HyroxDb.linkWorkout(db, 'hx_link_1', 0, 'w1');
      await expectLater(
        HyroxDb.linkWorkout(db, 'hx_link_1', 1, 'w1'),
        throwsA(isA<HyroxWriteError>()),
      );
      await expectLater(
        HyroxDb.linkWorkout(db, 'hx_link_1', 42, 'w2'),
        throwsA(isA<HyroxWriteError>()),
      );
      await expectLater(
        HyroxDb.linkWorkout(db, 'hx_link_1', 2, '  '),
        throwsA(isA<HyroxWriteError>()),
      );
      final segs = await HyroxDb.segments(db, 'hx_link_1');
      expect(segs[0].workoutId, 'w1');
      expect(segs[1].workoutId, isNull);
      await LocalDb.close();
    });

    test('deleting a day removes the race and its segments', () async {
      final db = await freshDb('hx_delete_rows_test.db');
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await HyroxDb.create(
          db, armedSession('hx_delete_1', createdAt: nowSec * 1000));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_delete_1', ts: nowSec - 60,
        boundarySource: 'gesture');
      await LocalDb.deleteDays({dayLabelOf(DateTime.now())});
      expect(await HyroxDb.byId(db, 'hx_delete_1'), isNull);
      expect(
        await db.query('hyrox_segment',
            where: 'session_id = ?', whereArgs: ['hx_delete_1']),
        isEmpty,
      );
      await LocalDb.close();
    });

    test('a fresh install creates the hyrox tables at the current schema',
        () async {
      final db = await freshDb('hx_schema_fresh_test.db');
      final names = await LocalDb.tableNames();
      expect(names, containsAll(['hyrox_session', 'hyrox_segment']));
      final v = await db.rawQuery('PRAGMA user_version');
      expect((v.first.values.first as num).toInt(), LocalDb.schemaVersion);
      expect(LocalDb.schemaVersion, 61);
      await LocalDb.close();
    });

    test('an install at v58 is upgraded to the current schema', () async {
      const name = 'hx_upgrade_58_test.db';
      LocalDb.dbName = name;
      final dir = await databaseFactory.getDatabasesPath();
      final path = p.join(dir, name);
      await databaseFactory.deleteDatabase(path);
      await LocalDb.instance;
      await LocalDb.close();

      // Rewind to v58 without the hyrox tables, exactly what a user who
      // installed before this PR has.
      final raw = await databaseFactory.openDatabase(path);
      await raw.execute('DROP TABLE hyrox_segment');
      await raw.execute('DROP TABLE hyrox_session');
      await raw.execute('PRAGMA user_version = 58');
      await raw.close();

      final db = await LocalDb.instance;
      final v = await db.rawQuery('PRAGMA user_version');
      expect((v.first.values.first as num).toInt(), LocalDb.schemaVersion,
          reason: 'the v61 ladder rung must run, not just the repair pass');
      final names = await LocalDb.tableNames();
      expect(names, containsAll(['hyrox_session', 'hyrox_segment']));
      await LocalDb.close();
    });

    test('updateSession cannot move the derived bounds', () async {
      final db = await freshDb('hx_bounds_test.db');
      await HyroxDb.create(db, armedSession('hx_bounds_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_bounds_1', ts: 1000, boundarySource: 'gesture');
      final current = (await HyroxDb.byId(db, 'hx_bounds_1'))!;
      await HyroxDb.updateSession(
        db,
        HyroxSession(
          id: current.id,
          kind: current.kind,
          preset: current.preset,
          status: 'active',
          plan: current.plan,
          startTs: 999999,
          endTs: 999999,
          note: 'felt good',
          createdAt: current.createdAt,
          updatedAt: current.updatedAt,
        ),
      );
      final read = (await HyroxDb.byId(db, 'hx_bounds_1'))!;
      expect(read.startTs, 1000);
      expect(read.endTs, isNull);
      expect(read.note, 'felt good');
      await LocalDb.close();
    });

    test('deleting the second day removes a race that crossed midnight',
        () async {
      final db = await freshDb('hx_midnight_test.db');
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final midnightSec = midnight.millisecondsSinceEpoch ~/ 1000;
      await HyroxDb.create(
          db, armedSession('hx_midnight_1', createdAt: (midnightSec - 600) * 1000));
      // Round 1 starts yesterday, round 2 starts today.
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_midnight_1', ts: midnightSec - 600,
        boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_midnight_1', currentIdx: 0,
        transitionTs: midnightSec + 60, boundarySource: 'gesture');

      await LocalDb.deleteDays({dayLabelOf(now)});
      expect(await HyroxDb.byId(db, 'hx_midnight_1'), isNull);
      await LocalDb.close();
    });

    test('a day export carries the race and restores it whole', () async {
      final db = await freshDb('hx_roundtrip_source.db');
      final now = DateTime.now();
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      await HyroxDb.create(
          db, armedSession('hx_export_1', createdAt: nowSec * 1000));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_export_1', ts: nowSec - 60,
        boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_export_1', currentIdx: 0,
        transitionTs: nowSec - 30, boundarySource: 'gesture');

      final path = await LocalDb.exportDaysDb({dayLabelOf(now)});
      expect(File(path).existsSync(), isTrue);

      // Import into a second, empty database.
      await LocalDb.close();
      LocalDb.dbName = 'hx_roundtrip_dest.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      final dest = await LocalDb.instance;
      final counts = await LocalDb.importFromDbFile(path);
      expect(counts['hyrox_session'], 1);
      expect(counts['hyrox_segment'], 8);

      final restored = await HyroxDb.byId(dest, 'hx_export_1');
      expect(restored, isNotNull);
      expect(restored!.segments, hasLength(8));
      expect(restored.segments[0].startTs, nowSec - 60);
      expect(restored.segments[1].startTs, nowSec - 30);
      expect(restored.plan?.preset, 'hyrox');
      await File(path).delete();
      await LocalDb.close();
    });

    test('create only accepts an armed plan without history', () async {
      final db = await freshDb('hx_create_inv_test.db');
      final plan = HyroxPlan.race('hyrox');
      // Not armed.
      await expectLater(
        HyroxDb.create(
          db,
          HyroxSession(
            id: 'hx_ci_1', kind: 'race', preset: 'hyrox', status: 'active',
            plan: plan, createdAt: 1, updatedAt: 1,
          ),
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      // Pre-filled bounds.
      await expectLater(
        HyroxDb.create(
          db,
          HyroxSession(
            id: 'hx_ci_2', kind: 'race', preset: 'hyrox', status: 'armed',
            plan: plan, startTs: 5, createdAt: 1, updatedAt: 1,
          ),
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      // Segment rows carrying history.
      await expectLater(
        HyroxDb.create(
          db,
          HyroxSession(
            id: 'hx_ci_3', kind: 'race', preset: 'hyrox', status: 'armed',
            plan: plan, createdAt: 1, updatedAt: 1,
            segments: [
              HyroxSegment(
                sessionId: 'hx_ci_3', idx: 0,
                kind: HyroxSegmentKind.hyroxRound, station: HyroxStation.skierg,
                roundIndex: 1, plannedDistanceM: 1000, plannedCal: 50,
                startTs: 100,
              ),
              for (var i = 1; i < 8; i++)
                HyroxSegment(
                  sessionId: 'hx_ci_3', idx: i,
                  kind: HyroxSegmentKind.hyroxRound,
                  station: kHyroxStationOrder[i], roundIndex: i + 1,
                  plannedDistanceM: kHyroxStationTargets[kHyroxStationOrder[i]]?.$1,
                  plannedReps: kHyroxStationTargets[kHyroxStationOrder[i]]?.$2,
                  plannedCal: kHyroxStationTargets[kHyroxStationOrder[i]]?.$3,
                ),
            ],
          ),
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      // Duplicate id.
      await HyroxDb.create(db, armedSession('hx_ci_4'));
      await expectLater(
        HyroxDb.create(db, armedSession('hx_ci_4')),
        throwsA(isA<HyroxWriteError>()),
      );
      // Session preset must match the frozen plan's preset.
      await expectLater(
        HyroxDb.create(
          db,
          HyroxSession(
            id: 'hx_ci_5', kind: 'race', preset: 'hyrox_doubles',
            status: 'armed', plan: HyroxPlan.race('hyrox'),
            createdAt: 1, updatedAt: 1,
          ),
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    test('adjustStart corrects a false start and refuses a started race',
        () async {
      final db = await freshDb('hx_adjstart_test.db');
      await HyroxDb.create(db, armedSession('hx_adjstart_1'));
      // False triple-tap at the start line starts the race at the wrong time.
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_adjstart_1', ts: 1000,
        boundarySource: 'gesture');
      // Not yet transitioned: the start is still correctable.
      await HyroxDb.adjustStart(
        db: db, sessionId: 'hx_adjstart_1', newTs: 1500);
      var segs = await HyroxDb.segments(db, 'hx_adjstart_1');
      expect(segs[0].startTs, 1500);
      expect(segs[0].boundarySource, 'manual');
      expect(segs[1].startTs, isNull);
      var read = await HyroxDb.byId(db, 'hx_adjstart_1');
      expect(read!.startTs, 1500);
      expect(read.status, 'active');

      // Once a segment has ENDED, the start is history and cannot move.
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_adjstart_1', currentIdx: 0,
        transitionTs: 2000, boundarySource: 'gesture');
      await expectLater(
        HyroxDb.adjustStart(
          db: db, sessionId: 'hx_adjstart_1', newTs: 1600),
        throwsA(isA<HyroxWriteError>()),
      );
      segs = await HyroxDb.segments(db, 'hx_adjstart_1');
      expect(segs[0].startTs, 1500);
      await LocalDb.close();
    });

    test('removeBoundary merges a false split and refuses a started tail',
        () async {
      final db = await freshDb('hx_rmb_test.db');
      await HyroxDb.create(db, armedSession('hx_rmb_1'));
      // round0 1000->1600, round1 1600->1700, round2 1700->3100, round3 open.
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_rmb_1', ts: 1000, boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_rmb_1', currentIdx: 0,
        transitionTs: 1600, boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_rmb_1', currentIdx: 1,
        transitionTs: 1700, boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_rmb_1', currentIdx: 2,
        transitionTs: 3100, boundarySource: 'gesture');
      // A later segment started: boundary 1 cannot be removed anymore.
      await expectLater(
        HyroxDb.removeBoundary(db: db, sessionId: 'hx_rmb_1', idx: 1),
        throwsA(isA<HyroxWriteError>()),
      );
      // Boundary 2 is the live edge: removing it merges round 3 into round 2.
      await HyroxDb.removeBoundary(db: db, sessionId: 'hx_rmb_1', idx: 2);
      final segs = await HyroxDb.segments(db, 'hx_rmb_1');
      expect(segs[2].startTs, 1700);
      expect(segs[2].endTs, isNull);
      expect(segs[2].boundarySource, 'manual');
      expect(segs[3].startTs, isNull);
      expect(segs[3].endTs, isNull);
      expect(segs.where((s) => s.isOpen).length, 1);
      await LocalDb.close();
    });

    test('an open segment from yesterday is deleted with today', () async {
      final db = await freshDb('hx_open_overlap_test.db');
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final midnightSec = midnight.millisecondsSinceEpoch ~/ 1000;
      await HyroxDb.create(db, armedSession('hx_open_overlap_1',
          createdAt: (midnightSec - 600) * 1000));
      // Round 1 started yesterday and is STILL OPEN at midnight (live session).
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_open_overlap_1', ts: midnightSec - 300,
        boundarySource: 'gesture');
      await LocalDb.deleteDays({dayLabelOf(now)});
      expect(await HyroxDb.byId(db, 'hx_open_overlap_1'), isNull);
      await LocalDb.close();
    });

    test('offline boundaries after the final segment are rejected', () async {
      final db = await freshDb('hx_offline_tail_test.db');
      await HyroxDb.create(db, armedSession('hx_tail_1'));
      // Boundary i closes round i (the first one also starts the race), so it
      // carries that round's station; a 9th boundary follows the final round.
      final bounds = [
        for (var i = 0; i < 8; i++)
          ReconcileBoundary(1000 + i * 1000, 3, HyroxSegmentKind.hyroxRound,
              kHyroxStationOrder[i]),
        const ReconcileBoundary(9999, 3, HyroxSegmentKind.hyroxRound,
            HyroxStation.wallBalls),
      ];
      await expectLater(
        db.transaction((txn) async {
          await HyroxDb.applyOfflineBoundariesInTx(
            txn,
            sessionId: 'hx_tail_1',
            boundaries: bounds,
          );
        }),
        throwsA(isA<HyroxWriteError>()),
      );
      final segs = await HyroxDb.segments(db, 'hx_tail_1');
      expect(segs[7].endTs, isNull, reason: 'the transaction rolled back');
      expect(segs[0].startTs, isNull, reason: 'nothing half-applied');
      await LocalDb.close();
    });

    test('a day export includes a race whose open segment overlaps it',
        () async {
      final db = await freshDb('hx_export_overlap_src.db');
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final midnightSec = midnight.millisecondsSinceEpoch ~/ 1000;
      await HyroxDb.create(db, armedSession('hx_export_overlap_1',
          createdAt: (midnightSec - 600) * 1000));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_export_overlap_1', ts: midnightSec - 300,
        boundarySource: 'gesture');
      final path = await LocalDb.exportDaysDb({dayLabelOf(now)});
      final exported = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(readOnly: true));
      final rows = await exported.query('hyrox_session',
          where: 'id = ?', whereArgs: ['hx_export_overlap_1']);
      final segs = await exported.query('hyrox_segment',
          where: 'session_id = ?', whereArgs: ['hx_export_overlap_1']);
      expect(rows, hasLength(1));
      expect(segs, hasLength(8));
      await exported.close();
      await File(path).delete();
      await LocalDb.close();
    });

    test('a pause between rounds is legal and reported separately', () async {
      final db = await freshDb('hx_pause_test.db');
      await HyroxDb.create(db, armedSession('hx_pause_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_pause_1', ts: 1000, boundarySource: 'gesture');
      // Round 0 ends at 2000; round 1 only starts at 5600 -> 3600 s pause.
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_pause_1', currentIdx: 0,
        transitionTs: 2000, boundarySource: 'gesture');
      await HyroxDb.saveSegment(
        db,
        (await HyroxDb.segments(db, 'hx_pause_1'))[1]
            .copyWith(startTs: 5600, endTs: 5660),
      );
      final read = (await HyroxDb.byId(db, 'hx_pause_1'))!;
      expect(read.movingSec, 1000 + 60); // round 0 + round 1
      expect(read.totalSec, 5660 - 1000);
      expect(read.pauseSec, (5660 - 1000) - (1000 + 60));
      await LocalDb.close();
    });

    test('an overlap between rounds is refused', () async {
      final db = await freshDb('hx_overlap_test.db');
      await HyroxDb.create(db, armedSession('hx_overlap_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_overlap_1', ts: 1000, boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_overlap_1', currentIdx: 0,
        transitionTs: 2000, boundarySource: 'gesture');
      await expectLater(
        HyroxDb.saveSegment(
          db,
          (await HyroxDb.segments(db, 'hx_overlap_1'))[0]
              .copyWith(endTs: 2100),
        ),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    test('a DNF (abandoned mid-race) finalizes with an open cut segment',
        () async {
      final db = await freshDb('hx_dnf_test.db');
      await HyroxDb.create(db, armedSession('hx_dnf_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_dnf_1', ts: 1000, boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_dnf_1', currentIdx: 0,
        transitionTs: 2000, boundarySource: 'gesture');
      // Athlete quits during round 2: round 2 stays open, later rounds untouched.
      final current = (await HyroxDb.byId(db, 'hx_dnf_1'))!;
      await HyroxDb.updateSession(
        db,
        HyroxSession(
          id: current.id, kind: current.kind, preset: current.preset,
          status: 'abandoned', plan: current.plan,
          createdAt: current.createdAt, updatedAt: current.updatedAt,
        ),
      );
      await HyroxDb.finalize(db, 'hx_dnf_1');
      final fin = (await HyroxDb.byId(db, 'hx_dnf_1'))!;
      expect(fin.isFinalized, isTrue);
      expect(fin.status, 'finalized');
      expect(fin.segments[1].endTs, isNull, reason: 'open segment stays open');
      expect(fin.segments[1].durationSec, isNull, reason: 'no invented time');
      expect(fin.segments[2].startTs, isNull);
      expect(fin.movingSec, 1000); // only round 1 was measured
      await LocalDb.close();
    });

    test('finalizing a never-started session is refused', () async {
      final db = await freshDb('hx_dnf_empty_test.db');
      await HyroxDb.create(db, armedSession('hx_dnf_empty_1'));
      final current = (await HyroxDb.byId(db, 'hx_dnf_empty_1'))!;
      await HyroxDb.updateSession(
        db,
        HyroxSession(
          id: current.id, kind: current.kind, preset: current.preset,
          status: 'abandoned', plan: current.plan,
          createdAt: current.createdAt, updatedAt: current.updatedAt,
        ),
      );
      await expectLater(
        HyroxDb.finalize(db, 'hx_dnf_empty_1'),
        throwsA(isA<HyroxWriteError>()),
      );
      await LocalDb.close();
    });

    // CodeRabbit follow-up: a finalized DNF whose open cut segment STARTS on
    // the later day must still be caught by that day's window (the segment
    // start branch), both on delete and on export.
    test('a DNF cut segment starting after midnight is deleted with the '
        'second day', () async {
      final db = await freshDb('hx_dnf_midnight_test.db');
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final midnightSec = midnight.millisecondsSinceEpoch ~/ 1000;
      await HyroxDb.create(db, armedSession('hx_dnf_mid_1',
          createdAt: (midnightSec - 3600) * 1000));
      // Round 1 runs yesterday and closes yesterday; round 2 (the cut) STARTS
      // today and stays open; the race is abandoned + finalized.
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_dnf_mid_1', ts: midnightSec - 3000,
        boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_dnf_mid_1', currentIdx: 0,
        transitionTs: midnightSec - 600, boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_dnf_mid_1', currentIdx: 1,
        transitionTs: midnightSec + 60, boundarySource: 'gesture');
      final current = (await HyroxDb.byId(db, 'hx_dnf_mid_1'))!;
      await HyroxDb.updateSession(
        db,
        HyroxSession(
          id: current.id, kind: current.kind, preset: current.preset,
          status: 'abandoned', plan: current.plan,
          createdAt: current.createdAt, updatedAt: current.updatedAt,
        ),
      );
      await HyroxDb.finalize(db, 'hx_dnf_mid_1');

      await LocalDb.deleteDays({dayLabelOf(now)});
      expect(await HyroxDb.byId(db, 'hx_dnf_mid_1'), isNull,
          reason: 'the cut segment starts today, so the race belongs to today');
      expect(
        await db.query('hyrox_segment',
            where: 'session_id = ?', whereArgs: ['hx_dnf_mid_1']),
        isEmpty,
      );
      await LocalDb.close();
    });

    test('a DNF cut segment starting after midnight is included in the '
        'second day export', () async {
      final db = await freshDb('hx_dnf_midnight_export_test.db');
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final midnightSec = midnight.millisecondsSinceEpoch ~/ 1000;
      await HyroxDb.create(db, armedSession('hx_dnf_mid_exp_1',
          createdAt: (midnightSec - 3600) * 1000));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_dnf_mid_exp_1', ts: midnightSec - 3000,
        boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_dnf_mid_exp_1', currentIdx: 0,
        transitionTs: midnightSec - 600, boundarySource: 'gesture');
      await HyroxDb.transitionSegment(
        db: db, sessionId: 'hx_dnf_mid_exp_1', currentIdx: 1,
        transitionTs: midnightSec + 60, boundarySource: 'gesture');
      final current = (await HyroxDb.byId(db, 'hx_dnf_mid_exp_1'))!;
      await HyroxDb.updateSession(
        db,
        HyroxSession(
          id: current.id, kind: current.kind, preset: current.preset,
          status: 'abandoned', plan: current.plan,
          createdAt: current.createdAt, updatedAt: current.updatedAt,
        ),
      );
      await HyroxDb.finalize(db, 'hx_dnf_mid_exp_1');

      final path = await LocalDb.exportDaysDb({dayLabelOf(now)});
      final exported = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(readOnly: true));
      final rows = await exported.query('hyrox_session',
          where: 'id = ?', whereArgs: ['hx_dnf_mid_exp_1']);
      final segs = await exported.query('hyrox_segment',
          where: 'session_id = ?', whereArgs: ['hx_dnf_mid_exp_1']);
      expect(rows, hasLength(1),
          reason: 'the cut segment starts today, so the race exports with today');
      expect(segs, hasLength(8));
      await exported.close();
      await File(path).delete();
      await LocalDb.close();
    });

    // CodeRabbit follow-up: re-importing an OLDER snapshot must not overwrite
    // the segments of a locally newer session whose parent row was skipped.
    test('restore keeps segments of a locally newer (skipped) session',
        () async {
      final db = await freshDb('hx_restore_src.db');
      final now = DateTime.now();
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      await HyroxDb.create(
          db, armedSession('hx_restore_1', createdAt: nowSec * 1000));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_restore_1', ts: nowSec - 120,
        boundarySource: 'gesture');
      final path = await LocalDb.exportDaysDb({dayLabelOf(now)});
      await LocalDb.close();

      // Destination: import the snapshot, then advance the race locally so
      // the local row is newer than the snapshot.
      LocalDb.dbName = 'hx_restore_dest.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      final dest = await LocalDb.instance;
      await LocalDb.importFromDbFile(path);
      await HyroxDb.transitionSegment(
        db: dest, sessionId: 'hx_restore_1', currentIdx: 0,
        transitionTs: nowSec - 60, boundarySource: 'gesture');
      final before = await HyroxDb.segments(dest, 'hx_restore_1');
      expect(before[0].endTs, nowSec - 60);
      expect(before[1].startTs, nowSec - 60);

      // Re-import the same (older) snapshot: the parent is skipped because
      // the local row is newer, and its segments must follow that verdict.
      await LocalDb.importFromDbFile(path);
      final after = await HyroxDb.segments(dest, 'hx_restore_1');
      expect(after[0].endTs, nowSec - 60,
          reason: 'segment rows must not be overwritten by the older snapshot');
      expect(after[1].startTs, nowSec - 60);
      await File(path).delete();
      await LocalDb.close();
    });

    // CodeRabbit follow-up: removeBoundary must refuse to merge into the final
    // segment when that segment is already closed (finished race).
    test('removeBoundary refuses to merge into a closed final segment',
        () async {
      final db = await freshDb('hx_rmb_final_test.db');
      await HyroxDb.create(db, armedSession('hx_rmbf_1'));
      await HyroxDb.startSegment(
        db: db, sessionId: 'hx_rmbf_1', ts: 1000, boundarySource: 'gesture');
      for (var i = 0; i < 7; i++) {
        await HyroxDb.transitionSegment(
          db: db, sessionId: 'hx_rmbf_1', currentIdx: i,
          transitionTs: 2000 + i * 600, boundarySource: 'gesture');
      }
      await HyroxDb.finishSegment(
        db: db, sessionId: 'hx_rmbf_1', ts: 2000 + 7 * 600 + 600,
        boundarySource: 'gesture');
      // The race is finished: boundary 6 (round 7 -> final round 8) must not
      // be removable, because that would clear the closed final segment.
      await expectLater(
        HyroxDb.removeBoundary(db: db, sessionId: 'hx_rmbf_1', idx: 6),
        throwsA(isA<HyroxWriteError>()),
      );
      final segs = await HyroxDb.segments(db, 'hx_rmbf_1');
      expect(segs[7].startTs, isNotNull);
      expect(segs[7].endTs, isNotNull);
      await LocalDb.close();
    });
  });
}
