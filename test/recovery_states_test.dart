// Today's recovery headline: three explicit states, a pin that only freezes a
// FINAL main night, and a read side that only trusts a pin for its own night.
//
// The reported case: a night 01:05–07:56 local (IST on the device) had
// `{"day": …, "value": 2}` pinned at 04:04, three hours into the night, and
// Home showed 2 all day while Coach (reading day_result) said 27.6.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Local wall-clock times, so the 03:00 guard reads the same in any TZ.
  const day = '2026-10-08';
  final onset = sec(DateTime(2026, 10, 8, 1, 5));
  final wake = sec(DateTime(2026, 10, 8, 7, 56));
  final at0404 = sec(DateTime(2026, 10, 8, 4, 4));

  group('recoveryStateOf', () {
    test('edge still at the window close → night in progress', () {
      // Mid-drain at 04:04 the stager closes the window at the newest record.
      expect(recoveryStateOf(wakeSec: at0404, dataEdgeSec: at0404),
          RecoveryState.nightInProgress);
      expect(recoveryStateOf(wakeSec: null, dataEdgeSec: at0404),
          RecoveryState.nightInProgress);
    });

    test('wake confirmed but not settled → provisional', () {
      expect(
          recoveryStateOf(
              wakeSec: wake, dataEdgeSec: wake + kWakeConfirmMarginSec),
          RecoveryState.provisional);
    });

    test('edge an hour past wake → final', () {
      expect(recoveryStateOf(wakeSec: wake, dataEdgeSec: wake + 3600),
          RecoveryState.finalReady);
    });
  });

  group('pin guards (reported case replay)', () {
    test('pin attempt at 04:04 mid-night is refused', () {
      // Not settled: the edge is the window close.
      expect(
          nextFrozenHeadline(
            today: day,
            overnightComplete: overnightSettled(
                sleepOffsetSec: at0404, dataEdgeSec: at0404),
            liveReadiness: 2,
            current: null,
            wakeSec: at0404,
            onsetSec: onset,
          ),
          isNull);
      // Even if the edge claimed it settled, 2h59m of sleep is no main night.
      expect(
          nextFrozenHeadline(
            today: day,
            overnightComplete: true,
            liveReadiness: 2,
            current: null,
            wakeSec: at0404,
            onsetSec: onset,
          ),
          isNull);
    });

    test('a wake before 03:00 local is never pinned', () {
      expect(
          nextFrozenHeadline(
            today: day,
            overnightComplete: true,
            liveReadiness: 40,
            current: null,
            wakeSec: sec(DateTime(2026, 10, 8, 2, 30)),
            onsetSec: sec(DateTime(2026, 10, 7, 21, 0)),
          ),
          isNull);
    });

    test('after wake the final value pins', () {
      final pin = nextFrozenHeadline(
        today: day,
        overnightComplete:
            overnightSettled(sleepOffsetSec: wake, dataEdgeSec: wake + 3600),
        liveReadiness: 28,
        current: null,
        wakeSec: wake,
        onsetSec: onset,
      );
      expect(pin?.value, 28);
      expect(pin?.wakeSec, wake);
    });

    test('an old pin without wakeSec is replaced by the final night', () {
      final pin = nextFrozenHeadline(
        today: day,
        overnightComplete: true,
        liveReadiness: 28,
        current: (day: day, value: 2, wakeSec: null),
        wakeSec: wake,
        onsetSec: onset,
      );
      expect(pin?.value, 28);
    });
  });

  group('read side', () {
    late String dir;
    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_recovery_states_test.db';
      dir = await databaseFactory.getDatabasesPath();
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.putDayResult(
        dayId: day,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({'scalars': {'readiness': 27.6}}),
        windowJson: jsonEncode({
          'onset_ms': onset * 1000,
          'offset_ms': wake * 1000,
        }),
      );
    });
    tearDown(() async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    test('a pin is trusted only for the night it was taken on', () async {
      await LocalDb.setFrozenHeadline(day, 2); // old build: no wake
      expect(await LocalDb.headlinePinFor(day), isNull);
      await LocalDb.setFrozenHeadline(day, 2, wakeSec: at0404);
      expect(await LocalDb.headlinePinFor(day), isNull,
          reason: 'pinned on a wake 4 h before the real one');
      await LocalDb.setFrozenHeadline(day, 28, wakeSec: wake + 600);
      expect(await LocalDb.headlinePinFor(day), 28);
      expect(await LocalDb.headlinePinFor('2026-10-07'), isNull);
    });

    test('a manual re-analyse releases today\'s pin so the re-derive re-pins',
        () async {
      SharedPreferences.setMockInitialValues({});
      // A same-night pin would hold the old number through the re-derive
      // while the re-analysis summary reported the new one.
      await LocalDb.setFrozenHeadline(todayLabel(), 2, wakeSec: wake);
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.reanalyzeAll();
      // Nothing here to re-derive, so nothing re-pins; the stale 2 is gone.
      expect(await LocalDb.frozenHeadline(), isNull);
    });

    test('a changed final headline is remembered as from → to', () async {
      expect(await LocalDb.noteHeadlineShown(day, 2), isNull);
      expect(await LocalDb.noteHeadlineShown(day, 2), isNull);
      final u = await LocalDb.noteHeadlineShown(day, 28);
      expect(u?['from'], 2);
      expect(u?['to'], 28);
      // Stable on later reads, so the card keeps saying it.
      expect((await LocalDb.noteHeadlineShown(day, 28))?['from'], 2);
      // A new day starts clean.
      expect(await LocalDb.noteHeadlineShown('2026-10-09', 50), isNull);
    });
  });
}
