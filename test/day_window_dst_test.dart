// LOCAL DAY WINDOWS ACROSS A DST TRANSITION.
//
// `_localDayStartSec(dayId) + 86400` treats every local calendar day as exactly
// 24 h. It isn't: a spring-forward day is 23 h local and a fall-back day is
// 25 h. So on those two days a year the day window either overran into the NEXT
// day (deleteDays silently deleted the following day's first hour of
// decoded_onehz / sessions / band_* / events, and exportDaysDb copied it) or
// fell an hour short (fall-back left the last hour of the day behind).
//
// The host running these tests is very unlikely to sit in a DST zone, so we
// move the PROCESS timezone with libc setenv("TZ")+tzset() before asserting.
// Dart's DateTime reads the C library's local time on every call (it does not
// cache a zone), so this genuinely re-homes the local calendar. POSIX only —
// the test self-skips on Windows.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart'
    show lastSevenDays;

typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _UnsetenvNative = Int32 Function(Pointer<Utf8>);
typedef _UnsetenvDart = int Function(Pointer<Utf8>);
typedef _TzsetNative = Void Function();
typedef _TzsetDart = void Function();

void _setProcessTz(String? tz) {
  final lib = DynamicLibrary.process();
  final key = 'TZ'.toNativeUtf8();
  try {
    if (tz == null) {
      lib.lookupFunction<_UnsetenvNative, _UnsetenvDart>('unsetenv')(key);
    } else {
      final value = tz.toNativeUtf8();
      lib.lookupFunction<_SetenvNative, _SetenvDart>('setenv')(key, value, 1);
      calloc.free(value);
    }
    lib.lookupFunction<_TzsetNative, _TzsetDart>('tzset')();
  } finally {
    calloc.free(key);
  }
}

/// America/New_York: 2026-03-08 springs forward (23 h), 2026-11-01 falls back
/// (25 h). Both are ordinary 24 h days everywhere the flat +86400 was "right".
const _springForward = '2026-03-08';
const _fallBack = '2026-11-01';

Sample _sample(int ts, int counter) => Sample(
  tsEpoch: ts,
  counter: counter,
  hr: 70,
  rrIntervalsMs: const [800],
  ax: 0,
  ay: 0,
  az: 0,
  spo2RedRaw: 0,
  spo2IrRaw: 0,
  skinTempRaw: 0,
);

RawRecord _raw(int ts, int counter) => RawRecord(
  counter: counter,
  packetType: 47,
  hex: 'dst$counter',
  capturedAt: ts * 1000,
  recTs: ts,
);

void main() {
  final originalTz = Platform.environment['TZ'];

  setUpAll(() async {
    _setProcessTz('America/New_York');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_dst_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    _setProcessTz(originalTz);
  });

  test('the DST fixture timezone actually applied (guards the whole file)', () {
    expect(
      DateTime(2026, 3, 8).timeZoneOffset,
      const Duration(hours: -5),
      reason: 'setenv(TZ)+tzset() did not re-home the local calendar; the '
          'assertions below would be vacuous',
    );
  }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);

  test('localDayEndSec is the next local midnight, not start + 86400', () {
    // Spring forward: 23 h.
    expect(localDayLengthSec(_springForward), 23 * 3600);
    expect(
      localDayEndSec(_springForward),
      localDayStartSec('2026-03-09'),
      reason: 'a day ends exactly where the next one starts',
    );
    // Fall back: 25 h.
    expect(localDayLengthSec(_fallBack), 25 * 3600);
    expect(localDayEndSec(_fallBack), localDayStartSec('2026-11-02'));
    // An ordinary day is still 24 h.
    expect(localDayLengthSec('2026-06-15'), 86400);
    // Month and year rollover still work.
    expect(localDayEndSec('2026-01-31'), localDayStartSec('2026-02-01'));
    expect(localDayEndSec('2026-12-31'), localDayStartSec('2027-01-01'));
    // Malformed labels degrade to null rather than epoch 0.
    expect(localDayStartSec('not-a-date'), isNull);
    expect(localDayEndSec('2026-06'), isNull);
  }, skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null);

  test(
    'deleteDays on a spring-forward day must not eat the NEXT day\'s first hour',
    () async {
      final springStart = localDayStartSec(_springForward)!;
      final nextStart = localDayStartSec('2026-03-09')!;
      // With the 23 h day, start + 86400 lands one hour INTO 2026-03-09.
      expect(springStart + 86400, nextStart + 3600);

      // A record 30 min into 2026-03-09 — inside the buggy window, outside the
      // real one.
      final victimTs = nextStart + 1800;
      await LocalDb.insertRecord(_raw(victimTs, 5001), _sample(victimTs, 5001));
      // A record safely inside the spring-forward day itself.
      final doomedTs = springStart + 3600 * 12;
      await LocalDb.insertRecord(_raw(doomedTs, 5002), _sample(doomedTs, 5002));

      // A session in each, likewise.
      await LocalDb.putSession({
        'id': 'sess-next-day',
        'start_ts': victimTs,
        'end_ts': victimTs + 600,
        'type': 'run',
        'status': 'done',
        'source': 'manual',
        'created_at': victimTs * 1000,
      });

      await LocalDb.deleteDays({_springForward});

      final db = await LocalDb.instance;
      expect(
        await db.query('decoded_onehz', where: 'counter = ?', whereArgs: [5002]),
        isEmpty,
        reason: 'the selected day itself must be deleted',
      );
      expect(
        await db.query('decoded_onehz', where: 'counter = ?', whereArgs: [5001]),
        isNotEmpty,
        reason: 'the NEXT local day is not selected and must survive',
      );
      expect(
        await db.query('sessions', where: 'id = ?', whereArgs: ['sess-next-day']),
        isNotEmpty,
      );
    },
    skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null,
  );

  test(
    'deleteDays on a fall-back day must not leave the last hour behind',
    () async {
      final fallStart = localDayStartSec(_fallBack)!;
      final fallEnd = localDayEndSec(_fallBack)!;
      // With the 25 h day, start + 86400 stops an hour SHORT of local midnight.
      expect(fallStart + 86400, fallEnd - 3600);

      final lateTs = fallEnd - 1800; // in the 25th hour
      await LocalDb.insertRecord(_raw(lateTs, 5003), _sample(lateTs, 5003));

      await LocalDb.deleteDays({_fallBack});

      final db = await LocalDb.instance;
      expect(
        await db.query('decoded_onehz', where: 'counter = ?', whereArgs: [5003]),
        isEmpty,
        reason: 'the last local hour of the day belongs to that day',
      );
    },
    skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null,
  );

  test(
    'the daily-load week keeps one slot per calendar day over a spring-forward',
    () {
      // The day after the transition: `end - Sunday` is 23 h of wall clock,
      // which `Duration.inDays` floored to 0, so Sunday landed in Monday's
      // slot and Monday overwrote it — one bar missing, one slot empty, and a
      // footnote saying six of seven days produced a figure when seven did.
      final end = DateTime(2026, 3, 9); // Monday, the day after
      final points = [
        for (var i = 6; i >= 0; i--)
          {
            't': DateTime(2026, 3, 9 - i, 12).millisecondsSinceEpoch ~/ 1000,
            'v': (9 - i).toDouble(),
          },
      ];
      expect(lastSevenDays(points, end), [3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0]);
    },
    skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null,
  );

  test(
    'predicted next period counts calendar days across the fall-back',
    () async {
      await LocalDb.putCycleLog('2026-09-12', 'start');
      await LocalDb.putCycleLog('2026-10-10', 'start'); // 28 days
      final repo = LocalRepositoryImpl(
        getProfileMap: () => {'track_cycle': true},
      );
      final cycle = await repo.getCycle();
      // 2026-10-10 + 28 crosses $_fallBack (25 h); a Duration add lands at
      // 23:00 on 2026-11-06.
      expect(cycle['predicted_next'], '2026-11-07');
    },
    skip: Platform.isWindows ? 'POSIX setenv/tzset only' : null,
  );
}
