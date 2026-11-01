// PR 1 tests: triathlon model, validation, storage invariants, and schema
// migration ladder integration.
//
// Runs against the real sqflite_ffi database — the repo standard for DB tests.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/state/triathlon_reconciler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/triathlon_plan.dart';
import 'package:openstrap_edge/data/triathlon_store.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
  });

  group('TriathlonPlan pure model validation', () {
    test('a race plan builds the standard 5-segment order with distances', () {
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      expect(plan.validate(), isNull);
      expect(plan.segments.length, 5);
      expect(plan.segments[0].kind, TriSegmentKind.swim);
      expect(plan.segments[0].plannedDistanceM, 750.0);
      expect(plan.segments[1].kind, TriSegmentKind.t1);
      expect(plan.segments[2].kind, TriSegmentKind.bike);
      expect(plan.segments[2].plannedDistanceM, 20000.0);
      expect(plan.segments[3].kind, TriSegmentKind.t2);
      expect(plan.segments[4].kind, TriSegmentKind.run);
      expect(plan.segments[4].plannedDistanceM, 5000.0);
      expect(plan.needsGps, isTrue);
    });

    test('an all-indoor race plan needs no GPS and keeps its distances', () {
      final plan = TriathlonPlan.race(
        'olympic',
        swimEnv: TriEnvironment.indoor,
        bikeEnv: TriEnvironment.indoor,
        runEnv: TriEnvironment.indoor,
      );
      expect(plan.validate(), isNull);
      expect(plan.needsGps, isFalse);
      expect(plan.segments[0].environment, TriEnvironment.indoor);
      expect(plan.segments[2].environment, TriEnvironment.indoor);
      expect(plan.segments[4].environment, TriEnvironment.indoor);
    });

    test('mixed environment arms GPS only for outdoor segments', () {
      final plan = TriathlonPlan.race(
        'half_distance',
        swimEnv: TriEnvironment.indoor, // pool
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.indoor, // treadmill
      );
      expect(plan.validate(), isNull);
      expect(plan.needsGps, isTrue);
      expect(
        triathlonSegmentRecordsRoute(TriSegmentKind.bike, TriEnvironment.outdoor),
        isTrue,
      );
      expect(
        triathlonSegmentRecordsRoute(TriSegmentKind.run, TriEnvironment.indoor),
        isFalse,
      );
    });

    test('training plan allows brick workouts (bike -> run)', () {
      final plan = TriathlonPlan.training(const [
        TriSegmentPlan(
          kind: TriSegmentKind.bike,
          environment: TriEnvironment.outdoor,
          plannedDistanceM: 40000,
        ),
        TriSegmentPlan(kind: TriSegmentKind.t2),
        TriSegmentPlan(
          kind: TriSegmentKind.run,
          environment: TriEnvironment.outdoor,
          plannedDistanceM: 10000,
        ),
      ]);
      expect(plan.validate(), isNull);
      expect(plan.segments.length, 3);
      expect(plan.isTraining, isTrue);
    });

    test('validation catches broken plans', () {
      final empty = TriathlonPlan.training(const []);
      expect(empty.validate(), contains('needs at least one segment'));

      final startsWithT1 = TriathlonPlan.training(const [
        TriSegmentPlan(kind: TriSegmentKind.t1),
        TriSegmentPlan(kind: TriSegmentKind.run, environment: TriEnvironment.outdoor),
      ]);
      expect(startsWithT1.validate(), contains('discipline'));

      final unchosenEnv = TriathlonPlan.training(const [
        TriSegmentPlan(kind: TriSegmentKind.run),
      ]);
      expect(unchosenEnv.validate(), contains('indoor/outdoor'));

      final negativeDistance = TriathlonPlan.training(const [
        TriSegmentPlan(
          kind: TriSegmentKind.run,
          environment: TriEnvironment.outdoor,
          plannedDistanceM: -100,
        ),
      ]);
      expect(negativeDistance.validate(), contains('finite and positive'));
    });

    test('json round-trip preserves preset and environment choices', () {
      final plan = TriathlonPlan.race(
        'full_distance',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.indoor,
        goalSec: const {TriSegmentKind.run: 14400},
      );
      final json = plan.toJson();
      final roundTrip = TriathlonPlan.fromJson(json);
      expect(roundTrip, isNotNull);
      expect(roundTrip!.preset, 'full_distance');
      expect(roundTrip.segments[4].environment, TriEnvironment.indoor);
      expect(roundTrip.segments[4].goalSec, 14400);
    });
  });

  group('TriathlonDb storage seam', () {
    Future<Database> freshDb(String name) async {
      LocalDb.dbName = name;
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      return LocalDb.instance;
    }

    test('create stores session and pre-populates all planned segment rows',
        () async {
      final db = await freshDb('tri_create_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final session = TriSession(
        id: 'tri_sprint_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: t0,
        updatedAt: t0,
      );

      await TriathlonDb.create(db, session);
      final read = await TriathlonDb.byId(db, 'tri_sprint_1');
      expect(read, isNotNull);
      expect(read!.status, 'armed');
      expect(read.segments.length, 5);
      expect(read.segments[0].kind, TriSegmentKind.swim);
      expect(read.segments[0].plannedDistanceM, 750.0);
      expect(read.segments[0].startTs, isNull);
      await LocalDb.close();
    });

    test('activeSession returns the unfinalized active session', () async {
      final db = await freshDb('tri_active_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final session = TriSession(
        id: 'tri_sprint_active',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: t0,
        updatedAt: t0,
      );

      await TriathlonDb.create(db, session);
      final active = await TriathlonDb.activeSession(db);
      expect(active, isNotNull);
      expect(active!.id, 'tri_sprint_active');
      await LocalDb.close();
    });

    test('segment save enforces contiguous boundary constraint', () async {
      final db = await freshDb('tri_boundary_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final session = TriSession(
        id: 'tri_sprint_bounds',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: t0,
        updatedAt: t0,
      );
      await TriathlonDb.create(db, session);

      final seg0 = (await TriathlonDb.segments(db, 'tri_sprint_bounds'))[0];
      // Swim: 10:00 -> 10:15
      await TriathlonDb.saveSegment(
        db,
        seg0.copyWith(startTs: 1000, endTs: 1900, boundarySource: 'gesture'),
      );

      final seg1 = (await TriathlonDb.segments(db, 'tri_sprint_bounds'))[1];
      // T1 starts at 1900 (matches swim end).
      await TriathlonDb.saveSegment(
        db,
        seg1.copyWith(startTs: 1900, endTs: 1960, boundarySource: 'gesture'),
      );

      // A gap after T1's 1960 is a PAUSE and is legal now: T2 may start at
      // 2000 (40 s later).
      final seg2 = (await TriathlonDb.segments(db, 'tri_sprint_bounds'))[2];
      await TriathlonDb.saveSegment(
        db,
        seg2.copyWith(startTs: 2000, endTs: 3000, boundarySource: 'gesture'),
      );
      final read = (await TriathlonDb.byId(db, 'tri_sprint_bounds'))!;
      expect(read.pauseSec, 40);
      await LocalDb.close();
    });

    test('finalizing freezes session and rejects later writes', () async {
      final db = await freshDb('tri_finalize_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final session = TriSession(
        id: 'tri_sprint_fin',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: t0,
        updatedAt: t0,
      );
      await TriathlonDb.create(db, session);

      var t = 1000;
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_sprint_fin',
        ts: t,
        boundarySource: 'gesture',
      );
      for (var i = 0; i < 4; i++) {
        t += (i.isEven ? 1000 : 60);
        await TriathlonDb.transitionSegment(
          db: db,
          sessionId: 'tri_sprint_fin',
          currentIdx: i,
          transitionTs: t,
          boundarySource: 'gesture',
        );
      }
      t += 800;
      await TriathlonDb.finishSegment(
        db: db,
        sessionId: 'tri_sprint_fin',
        ts: t,
        boundarySource: 'gesture',
      );

      await TriathlonDb.finalize(db, 'tri_sprint_fin');
      final finalized = await TriathlonDb.byId(db, 'tri_sprint_fin');
      expect(finalized!.isFinalized, isTrue);
      expect(finalized.status, 'finalized');
      expect(finalized.endTs, t);

      // Any attempt to edit a finalized segment must throw.
      final seg0 = finalized.segments[0];
      await expectLater(
        TriathlonDb.saveSegment(
          db,
          seg0.copyWith(distanceM: 750, distanceSource: 'user'),
        ),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

    test('finalize refuses a session that never finished', () async {
      final db = await freshDb('tri_finalize_unfinished_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_unfinished_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_unfinished_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      await expectLater(
        TriathlonDb.finalize(db, 'tri_unfinished_1'),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

    test('triathlon tables participate in backup restore and salvage', () {
      expect(LocalDb.restoreTablesForTest,
          containsAllInOrder(['triathlon_session', 'triathlon_segment']));
      expect(LocalDb.salvageTablesForTest,
          containsAllInOrder(['triathlon_session', 'triathlon_segment']));
    });

    test('deleting a day works when no triathlon exists', () async {
      await freshDb('tri_delete_day_test.db');
      await LocalDb.deleteDays({'2026-01-01'});
      await LocalDb.close();
    });

    test('band-only race: stored taps are reconciled into boundaries',
        () async {
      final db = await freshDb('tri_sync_posthoc_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final t0 = 1_000_000;
      final session = TriSession(
        id: 'tri_posthoc_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: t0,
        updatedAt: t0,
      );
      await TriathlonDb.create(db, session);

      // The whole race happened with no phone in range: the strap recorded
      // every tap. Three taps clear the gate; two do not.
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

      // Start 10 min after arming, swim for the 300 s floor, then T1 for
      // longer than its own 20 s floor.
      await taps(t0 + 600, [0, 2, 4]);
      // A lone accidental bump must NOT advance anything.
      await taps(t0 + 640, [0]);
      await taps(t0 + 900, [0, 1, 2]);
      await taps(t0 + 930, [0, 2, 4]);

      final reconciler = TriathlonReconciler(db);
      final applied = await reconciler.reconcile('tri_posthoc_1');

      expect(applied, hasLength(3));
      final segs = await TriathlonDb.segments(db, 'tri_posthoc_1');
      expect(segs[0].startTs, t0 + 600);
      expect(segs[0].endTs, t0 + 900);
      expect(segs[0].boundarySource, 'posthoc');
      expect(segs[1].startTs, t0 + 900);
      expect(segs[1].endTs, t0 + 930);
      expect(segs[2].startTs, t0 + 930);
      final read = await TriathlonDb.byId(db, 'tri_posthoc_1');
      expect(read!.startTs, t0 + 600);
      expect(read.status, 'active');

      // Idempotent: the same log a second time adds nothing.
      final again = await reconciler.reconcile('tri_posthoc_1');
      expect(again, isEmpty);
      await LocalDb.close();
    });

    test('a transition under the segment minimum is ignored', () async {
      final db = await freshDb('tri_posthoc_floor_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_floor_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1_000_000,
        updatedAt: 1_000_000,
      );
      await TriathlonDb.create(db, session);

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

      // Clears the gate 600 s after arming: this is the START, not a
      // transition, so no minimum applies to it.
      await taps(1_000_600);
      // 20 s later a second burst tries to end the swim. A swim cannot be
      // over, so it must be ignored — the race keeps running.
      await taps(1_000_620);

      final applied = await TriathlonReconciler(db).reconcile('tri_floor_1');
      expect(applied, hasLength(1));
      final segs = await TriathlonDb.segments(db, 'tri_floor_1');
      expect(segs[0].startTs, 1_000_600);
      expect(segs[0].endTs, isNull);
      expect(segs[1].startTs, isNull);
      await LocalDb.close();
    });

    test('transition and boundary adjustment move both sides atomically',
        () async {
      final db = await freshDb('tri_transition_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_move_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_move_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_move_1',
        currentIdx: 0,
        transitionTs: 1600,
        boundarySource: 'gesture',
      );
      await TriathlonDb.adjustBoundary(
        db: db,
        sessionId: 'tri_move_1',
        idx: 0,
        newTs: 1700,
      );
      var segs = await TriathlonDb.segments(db, 'tri_move_1');
      expect(segs[0].endTs, 1700);
      expect(segs[1].startTs, 1700);

      // A closed segment cannot be transitioned again.
      await expectLater(
        TriathlonDb.transitionSegment(
          db: db,
          sessionId: 'tri_move_1',
          currentIdx: 0,
          transitionTs: 1800,
          boundarySource: 'gesture',
        ),
        throwsA(isA<TriathlonWriteError>()),
      );
      // But the next segment MAY start later than the previous end: a pause.
      await TriathlonDb.saveSegment(
        db,
        (await TriathlonDb.segments(db, 'tri_move_1'))[1]
            .copyWith(startTs: 2000),
      );
      segs = await TriathlonDb.segments(db, 'tri_move_1');
      expect(segs[0].endTs, 1700);
      expect(segs[1].startTs, 1700);
      await LocalDb.close();
    });

    test('an out-of-order segment is refused by the timeline rule', () async {
      final db = await freshDb('tri_timeline_order_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_order_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      final seg3 = (await TriathlonDb.segments(db, 'tri_order_1'))[3];
      await expectLater(
        TriathlonDb.saveSegment(
          db,
          seg3.copyWith(startTs: 500, endTs: 600),
        ),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

    test('finish only closes the final segment', () async {
      final db = await freshDb('tri_finish_early_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_finish_early_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_finish_early_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_finish_early_1',
        currentIdx: 0,
        transitionTs: 2000,
        boundarySource: 'gesture',
      );
      await expectLater(
        TriathlonDb.finishSegment(
          db: db,
          sessionId: 'tri_finish_early_1',
          ts: 2100,
          boundarySource: 'gesture',
        ),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

    test('finalizing refuses an open segment', () async {
      final db = await freshDb('tri_finalize_open_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_open_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_open_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      await expectLater(
        TriathlonDb.finalize(db, 'tri_open_1'),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

    test('a plan field cannot be rewritten through saveSegment', () async {
      final db = await freshDb('tri_plan_immutable_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_plan_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      final seg = (await TriathlonDb.segments(db, 'tri_plan_1'))[0];
      final relabelled = TriSegment(
        sessionId: seg.sessionId,
        idx: seg.idx,
        kind: seg.kind,
        environment: TriEnvironment.indoor,
        plannedDistanceM: seg.plannedDistanceM,
      );
      await expectLater(
        TriathlonDb.saveSegment(db, relabelled),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

    test('a workout cannot be linked to two segments', () async {
      final db = await freshDb('tri_link_unique_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_link_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.linkWorkout(db, 'tri_link_1', 0, 'w42');
      await expectLater(
        TriathlonDb.linkWorkout(db, 'tri_link_1', 2, 'w42'),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

    test('deleting a day removes the race and its segments', () async {
      final db = await freshDb('tri_delete_day_rows_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final session = TriSession(
        id: 'tri_delete_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: nowSec * 1000,
        updatedAt: nowSec * 1000,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_delete_1',
        ts: nowSec - 60,
        boundarySource: 'gesture',
      );
      await LocalDb.deleteDays({dayLabelOf(DateTime.now())});
      expect(await TriathlonDb.byId(db, 'tri_delete_1'), isNull);
      expect(
        await db.query('triathlon_segment',
            where: 'session_id = ?', whereArgs: ['tri_delete_1']),
        isEmpty,
      );
      await LocalDb.close();
    });


    test('a fresh install creates the triathlon tables', () async {
      final db = await freshDb('tri_schema_fresh_test.db');
      final names = await LocalDb.tableNames();
      expect(names, containsAll(['triathlon_session', 'triathlon_segment']));
      final v = await db.rawQuery('PRAGMA user_version');
      expect((v.first.values.first as num).toInt(), LocalDb.schemaVersion);
      await LocalDb.close();
    });

    test('an install at v58 is upgraded to the current schema', () async {
      const name = 'tri_upgrade_58_test.db';
      LocalDb.dbName = name;
      final dir = await databaseFactory.getDatabasesPath();
      final path = p.join(dir, name);
      await databaseFactory.deleteDatabase(path);
      await LocalDb.instance;
      await LocalDb.close();

      // Rewind to v58 without the triathlon tables, exactly what a user who
      // installed before this PR has.
      final raw = await databaseFactory.openDatabase(path);
      await raw.execute('DROP TABLE triathlon_segment');
      await raw.execute('DROP TABLE triathlon_session');
      await raw.execute('PRAGMA user_version = 58');
      await raw.close();

      final db = await LocalDb.instance;
      final v = await db.rawQuery('PRAGMA user_version');
      expect((v.first.values.first as num).toInt(), LocalDb.schemaVersion,
          reason: 'the v60 ladder rung must run, not just the repair pass');
      final names = await LocalDb.tableNames();
      expect(names, containsAll(['triathlon_session', 'triathlon_segment']));
      await LocalDb.close();
    });

    test('updateSession cannot move the derived bounds', () async {
      final db = await freshDb('tri_update_bounds_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_bounds_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_bounds_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      final current = (await TriathlonDb.byId(db, 'tri_bounds_1'))!;
      await TriathlonDb.updateSession(
        db,
        TriSession(
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
      final read = (await TriathlonDb.byId(db, 'tri_bounds_1'))!;
      expect(read.startTs, 1000);
      expect(read.endTs, isNull);
      expect(read.note, 'felt good');
      await LocalDb.close();
    });

    test('deleting the second day removes a race that crossed midnight',
        () async {
      final db = await freshDb('tri_midnight_test.db');
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final midnightSec = midnight.millisecondsSinceEpoch ~/ 1000;
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_midnight_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: (midnightSec - 600) * 1000,
        updatedAt: (midnightSec - 600) * 1000,
      );
      await TriathlonDb.create(db, session);
      // Swim starts yesterday, the bike starts today.
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_midnight_1',
        ts: midnightSec - 600,
        boundarySource: 'gesture',
      );
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_midnight_1',
        currentIdx: 0,
        transitionTs: midnightSec + 60,
        boundarySource: 'gesture',
      );

      await LocalDb.deleteDays({dayLabelOf(now)});
      expect(await TriathlonDb.byId(db, 'tri_midnight_1'), isNull);
      await LocalDb.close();
    });


    test('a day export carries the race and restores it whole', () async {
      final db = await freshDb('tri_roundtrip_source.db');
      final now = DateTime.now();
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_export_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: nowSec * 1000,
        updatedAt: nowSec * 1000,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_export_1',
        ts: nowSec - 60,
        boundarySource: 'gesture',
      );
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_export_1',
        currentIdx: 0,
        transitionTs: nowSec - 30,
        boundarySource: 'gesture',
      );

      final path = await LocalDb.exportDaysDb({dayLabelOf(now)});
      expect(File(path).existsSync(), isTrue);

      // Import into a second, empty database.
      await LocalDb.close();
      LocalDb.dbName = 'tri_roundtrip_dest.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      final dest = await LocalDb.instance;
      final counts = await LocalDb.importFromDbFile(path);
      expect(counts['triathlon_session'], 1);
      expect(counts['triathlon_segment'], 5);

      final restored = await TriathlonDb.byId(dest, 'tri_export_1');
      expect(restored, isNotNull);
      expect(restored!.segments, hasLength(5));
      expect(restored.segments[0].startTs, nowSec - 60);
      expect(restored.segments[1].startTs, nowSec - 30);
      expect(restored.plan?.preset, 'sprint');
      await File(path).delete();
      await LocalDb.close();
    });


    test('create only accepts an armed plan without history', () async {
      final db = await freshDb('tri_create_invariants_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final base = TriSession(
        id: 'tri_create_bad_1',
        kind: 'race',
        preset: 'sprint',
        status: 'active',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await expectLater(
        TriathlonDb.create(db, base),
        throwsA(isA<TriathlonWriteError>()),
      );

      // A full plan whose first segment already carries a start: the plan is
      // fine, the HISTORY is what create must refuse.
      final history = TriSession(
        id: 'tri_create_bad_2',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
        segments: [
          for (var i = 0; i < plan.segments.length; i++)
            TriSegment(
              sessionId: 'tri_create_bad_2',
              idx: i,
              kind: plan.segments[i].kind,
              environment: plan.segments[i].environment,
              plannedDistanceM: plan.segments[i].plannedDistanceM,
              startTs: i == 0 ? 1000 : null,
            ),
        ],
      );
      await expectLater(
        TriathlonDb.create(db, history),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

    test('a manual boundary is marked manual on both sides', () async {
      final db = await freshDb('tri_manual_source_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_manual_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_manual_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_manual_1',
        currentIdx: 0,
        transitionTs: 1600,
        boundarySource: 'gesture',
      );
      await TriathlonDb.adjustBoundary(
        db: db,
        sessionId: 'tri_manual_1',
        idx: 0,
        newTs: 1700,
      );
      final segs = await TriathlonDb.segments(db, 'tri_manual_1');
      expect(segs[0].boundarySource, 'manual');
      expect(segs[1].boundarySource, 'manual');
      await LocalDb.close();
    });

    test('adjustStart corrects a false start and refuses a started race',
        () async {
      final db = await freshDb('tri_adjust_start_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_adjstart_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      // False triple-tap in the pen starts the race at the wrong time.
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_adjstart_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      // Not yet transitioned: the start is still correctable.
      await TriathlonDb.adjustStart(
        db: db,
        sessionId: 'tri_adjstart_1',
        newTs: 1500,
      );
      var segs = await TriathlonDb.segments(db, 'tri_adjstart_1');
      expect(segs[0].startTs, 1500);
      expect(segs[0].boundarySource, 'manual');
      expect(segs[1].startTs, isNull);
      var read = await TriathlonDb.byId(db, 'tri_adjstart_1');
      expect(read!.startTs, 1500);
      expect(read.status, 'active');

      // Once a segment has ENDED, the start is history and cannot move.
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_adjstart_1',
        currentIdx: 0,
        transitionTs: 2000,
        boundarySource: 'gesture',
      );
      await expectLater(
        TriathlonDb.adjustStart(
          db: db,
          sessionId: 'tri_adjstart_1',
          newTs: 1600,
        ),
        throwsA(isA<TriathlonWriteError>()),
      );
      segs = await TriathlonDb.segments(db, 'tri_adjstart_1');
      expect(segs[0].startTs, 1500);
      await LocalDb.close();
    });

    test('removeBoundary merges a false split and refuses a started tail',
        () async {
      final db = await freshDb('tri_remove_boundary_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_rmb_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      // swim 1000->1600, t1 1600->1700, bike 1700->3100, t2 3100->open.
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_rmb_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_rmb_1',
        currentIdx: 0,
        transitionTs: 1600,
        boundarySource: 'gesture',
      );
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_rmb_1',
        currentIdx: 1,
        transitionTs: 1700,
        boundarySource: 'gesture',
      );
      // A later segment started: boundary 1 (t1) cannot be removed anymore.
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_rmb_1',
        currentIdx: 2,
        transitionTs: 3100,
        boundarySource: 'gesture',
      );
      await expectLater(
        TriathlonDb.removeBoundary(db: db, sessionId: 'tri_rmb_1', idx: 1),
        throwsA(isA<TriathlonWriteError>()),
      );
      // Boundary 2 (bike->t2) is the live edge: removing it merges t2 into
      // the bike segment; t2 was just opened so the merge re-opens the bike.
      await TriathlonDb.removeBoundary(db: db, sessionId: 'tri_rmb_1', idx: 2);
      final segs = await TriathlonDb.segments(db, 'tri_rmb_1');
      expect(segs[2].startTs, 1700);
      expect(segs[2].endTs, isNull);
      expect(segs[2].boundarySource, 'manual');
      expect(segs[3].startTs, isNull);
      expect(segs[3].endTs, isNull);
      // The merged session is still a valid timeline: one open segment.
      expect(segs.where((s) => s.isOpen).length, 1);
      await LocalDb.close();
    });

    test('linkWorkout refuses a transition and a missing segment', () async {
      final db = await freshDb('tri_link_guards_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_link_guard_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      // idx 1 is T1: no workout row exists for a transition.
      await expectLater(
        TriathlonDb.linkWorkout(db, 'tri_link_guard_1', 1, 'w1'),
        throwsA(isA<TriathlonWriteError>()),
      );
      await expectLater(
        TriathlonDb.linkWorkout(db, 'tri_link_guard_1', 42, 'w2'),
        throwsA(isA<TriathlonWriteError>()),
      );
      expect(
        await db.query('triathlon_segment', where: 'workout_id IS NOT NULL'),
        isEmpty,
      );
      await LocalDb.close();
    });

    test('a discarded race is never rebuilt by the reconciler', () async {
      final db = await freshDb('tri_discarded_reconcile_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_discarded_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1_000_000,
        updatedAt: 1_000_000,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.updateSession(
        db,
        TriSession(
          id: session.id,
          kind: session.kind,
          preset: session.preset,
          status: 'discarded',
          plan: plan,
          createdAt: session.createdAt,
          updatedAt: session.updatedAt,
        ),
      );
      for (final o in [0, 1, 2]) {
        final ts = 1_000_600 + o;
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
      final applied = await TriathlonReconciler(db).reconcile('tri_discarded_1');
      expect(applied, isEmpty);
      expect(
        (await TriathlonDb.byId(db, 'tri_discarded_1'))!.segments[0].startTs,
        isNull,
      );
      await LocalDb.close();
    });

    test('an open segment from yesterday is deleted with today', () async {
      final db = await freshDb('tri_open_overlap_test.db');
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final midnightSec = midnight.millisecondsSinceEpoch ~/ 1000;
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_open_overlap_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: (midnightSec - 600) * 1000,
        updatedAt: (midnightSec - 600) * 1000,
      );
      await TriathlonDb.create(db, session);
      // The swim started yesterday and is STILL OPEN at midnight.
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_open_overlap_1',
        ts: midnightSec - 300,
        boundarySource: 'gesture',
      );
      await LocalDb.deleteDays({dayLabelOf(now)});
      expect(await TriathlonDb.byId(db, 'tri_open_overlap_1'), isNull);
      await LocalDb.close();
    });

    test('offline boundaries after the final segment are rejected', () async {
      final db = await freshDb('tri_offline_tail_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_tail_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      const bounds = [
        ReconcileBoundary(1000, 3, TriSegmentKind.swim),
        ReconcileBoundary(2000, 3, TriSegmentKind.swim),
        ReconcileBoundary(2060, 3, TriSegmentKind.t1),
        ReconcileBoundary(3060, 3, TriSegmentKind.bike),
        ReconcileBoundary(3120, 3, TriSegmentKind.t2),
        ReconcileBoundary(4000, 3, TriSegmentKind.run),
        ReconcileBoundary(4100, 3, TriSegmentKind.run),
      ];
      await expectLater(
        db.transaction((txn) async {
          await TriathlonDb.applyOfflineBoundariesInTx(
            txn,
            sessionId: 'tri_tail_1',
            boundaries: bounds,
          );
        }),
        throwsA(isA<TriathlonWriteError>()),
      );
      final segs = await TriathlonDb.segments(db, 'tri_tail_1');
      expect(segs[4].endTs, isNull, reason: 'the transaction rolled back');
      await LocalDb.close();
    });


    test('a day export includes a race whose open segment overlaps it',
        () async {
      final db = await freshDb('tri_export_overlap_src.db');
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final midnightSec = midnight.millisecondsSinceEpoch ~/ 1000;
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_export_overlap_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: (midnightSec - 600) * 1000,
        updatedAt: (midnightSec - 600) * 1000,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_export_overlap_1',
        ts: midnightSec - 300,
        boundarySource: 'gesture',
      );
      final path = await LocalDb.exportDaysDb({dayLabelOf(now)});
      final exported = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(readOnly: true));
      final rows = await exported.query('triathlon_session',
          where: 'id = ?', whereArgs: ['tri_export_overlap_1']);
      final segs = await exported.query('triathlon_segment',
          where: 'session_id = ?', whereArgs: ['tri_export_overlap_1']);
      expect(rows, hasLength(1));
      expect(segs, hasLength(5));
      await exported.close();
      await File(path).delete();
      await LocalDb.close();
    });


    test('a pause between segments is legal and reported separately',
        () async {
      final db = await freshDb('tri_pause_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_pause_1',
        kind: 'training',
        preset: 'training',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_pause_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      // Swim ends at 2000; T1 only starts at 5600 -> 3600 s pause.
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_pause_1',
        currentIdx: 0,
        transitionTs: 2000,
        boundarySource: 'gesture',
      );
      // Simulate the pause by moving the T1 start later (manual correction).
      await TriathlonDb.saveSegment(
        db,
        (await TriathlonDb.segments(db, 'tri_pause_1'))[1]
            .copyWith(startTs: 5600, endTs: 5660),
      );
      final read = (await TriathlonDb.byId(db, 'tri_pause_1'))!;
      expect(read.movingSec, 660 + 60); // swim 1000s + t1 60s
      expect(read.totalSec, 5660 - 1000);
      expect(read.pauseSec, (5660 - 1000) - (1000 + 60));
      await LocalDb.close();
    });

    test('an overlap between segments is refused', () async {
      final db = await freshDb('tri_overlap_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_overlap_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_overlap_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_overlap_1',
        currentIdx: 0,
        transitionTs: 2000,
        boundarySource: 'gesture',
      );
      // Try to move the swim end AFTER the T1 start: overlap, must fail.
      await expectLater(
        TriathlonDb.saveSegment(
          db,
          (await TriathlonDb.segments(db, 'tri_overlap_1'))[0]
              .copyWith(endTs: 2100),
        ),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

    test('a DNF (abandoned mid-race) finalizes with an open cut segment',
        () async {
      final db = await freshDb('tri_dnf_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_dnf_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.startSegment(
        db: db,
        sessionId: 'tri_dnf_1',
        ts: 1000,
        boundarySource: 'gesture',
      );
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_dnf_1',
        currentIdx: 0,
        transitionTs: 2000,
        boundarySource: 'gesture',
      );
      // Athlete quits during T1: T1 stays open, bike/run untouched.
      await TriathlonDb.updateSession(
        db,
        TriSession(
          id: session.id,
          kind: session.kind,
          preset: session.preset,
          status: 'abandoned',
          plan: plan,
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await TriathlonDb.finalize(db, 'tri_dnf_1');
      final fin = (await TriathlonDb.byId(db, 'tri_dnf_1'))!;
      expect(fin.isFinalized, isTrue);
      expect(fin.status, 'finalized');
      expect(fin.segments[1].endTs, isNull, reason: 'open segment stays open');
      expect(fin.segments[1].durationSec, isNull, reason: 'no invented time');
      expect(fin.segments[2].startTs, isNull);
      expect(fin.movingSec, 1000); // only the swim was measured
      await LocalDb.close();
    });

    test('finalizing a never-started session is refused', () async {
      final db = await freshDb('tri_dnf_empty_test.db');
      final plan = TriathlonPlan.race(
        'sprint',
        swimEnv: TriEnvironment.outdoor,
        bikeEnv: TriEnvironment.outdoor,
        runEnv: TriEnvironment.outdoor,
      );
      final session = TriSession(
        id: 'tri_dnf_empty_1',
        kind: 'race',
        preset: 'sprint',
        status: 'armed',
        plan: plan,
        createdAt: 1,
        updatedAt: 1,
      );
      await TriathlonDb.create(db, session);
      await TriathlonDb.updateSession(
        db,
        TriSession(
          id: session.id,
          kind: session.kind,
          preset: session.preset,
          status: 'abandoned',
          plan: plan,
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await expectLater(
        TriathlonDb.finalize(db, 'tri_dnf_empty_1'),
        throwsA(isA<TriathlonWriteError>()),
      );
      await LocalDb.close();
    });

  });
}
