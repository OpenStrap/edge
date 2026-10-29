// PR 1 tests: triathlon model, validation, storage invariants, and schema
// migration ladder integration.
//
// Runs against the real sqflite_ffi database — the repo standard for DB tests.

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
        status: 'active',
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

      // Attempting to start T2 at 2000 (gap after T1's 1960) throws.
      final seg2 = (await TriathlonDb.segments(db, 'tri_sprint_bounds'))[2];
      await expectLater(
        TriathlonDb.saveSegment(
          db,
          seg2.copyWith(startTs: 2000, endTs: 3000, boundarySource: 'gesture'),
        ),
        throwsA(isA<TriathlonWriteError>()),
      );
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
        status: 'active',
        plan: plan,
        createdAt: t0,
        updatedAt: t0,
      );
      await TriathlonDb.create(db, session);

      // Close all 5 segments contiguously.
      var t = 1000;
      for (var i = 0; i < 5; i++) {
        final seg = (await TriathlonDb.segments(db, 'tri_sprint_fin'))[i];
        final len = i.isEven ? 1000 : 60;
        await TriathlonDb.saveSegment(
          db,
          seg.copyWith(startTs: t, endTs: t + len, boundarySource: 'gesture'),
        );
        t += len;
      }

      await TriathlonDb.finalize(db, 'tri_sprint_fin');
      final finalized = await TriathlonDb.byId(db, 'tri_sprint_fin');
      expect(finalized!.isFinalized, isTrue);

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

    test('a race under its minimum duration is not segmented by taps',
        () async {
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
      // 20 s in: a real swim cannot be over, so this is not a transition.
      for (final o in [0, 1, 2]) {
        final ts = 1_000_020 + o;
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
      final applied = await TriathlonReconciler(db).reconcile('tri_floor_1');
      expect(applied, isEmpty);
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
      var segs = await TriathlonDb.segments(db, 'tri_move_1');
      expect(segs[0].endTs, 1600);
      expect(segs[1].startTs, 1600);
      await TriathlonDb.transitionSegment(
        db: db,
        sessionId: 'tri_move_1',
        currentIdx: 0,
        transitionTs: 1700,
        boundarySource: 'gesture',
      );
      await expectLater(
        TriathlonDb.transitionSegment(
          db: db,
          sessionId: 'tri_move_1',
          currentIdx: 0,
          transitionTs: 1500,
          boundarySource: 'gesture',
        ),
        throwsA(isA<TriathlonWriteError>()),
      );
      segs = await TriathlonDb.segments(db, 'tri_move_1');
      expect(segs[0].endTs, 1700);
      expect(segs[1].startTs, 1700);
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

  });
}
