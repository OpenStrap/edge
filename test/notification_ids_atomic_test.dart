// Atomic cross-isolate OS-notification-id slot allocation.
//
// The sibling suite (notification_ids_test.dart) runs with no sqlite factory
// and covers the degraded SharedPreferences fallback. THIS suite runs the
// real LocalDb via sqflite_common_ffi, so it exercises the path that
// actually ships: NotificationIds._slotFor → LocalDb.claimNotifSlot → one
// atomic INSERT OR IGNORE against a UNIQUE(category, slot) index.
//
// What this suite actually proves — and what it doesn't: the race being
// fixed is two derivation isolates racing to FIRST-allocate a slot for two
// DIFFERENT dedupeKeys in the same category band (e.g. derivation_engine
// .dart's same-day plain/escalated exception pair, '$date:exception' and
// '$date:exception:medical'). A unit test can't spawn a second real OS
// isolate/process, and `Future.wait` here does NOT force the two
// `claimNotifSlot` transactions to interleave at the SQLite level — one
// transaction holds sqflite's write lock and runs to completion before the
// other starts, same as it would running fully sequentially. What this DOES
// verify: `claimNotifSlot`'s UNIQUE(category, slot) claim is the primitive
// that makes the *sequential* case (any writer, from any isolate, arriving
// after another has already committed a slot) collision-free — which is what
// actually eliminates the bug, since the old SharedPreferences code could
// misallocate even without true interleaving (a stale read is enough). The
// true concurrent-isolate case is exercised on real devices, not here.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';

final String kToday = todayLabel();

NotificationEvent _ev(String key, [NotifCategory c = NotifCategory.health]) =>
    NotificationEvent(
      dedupeKey: key,
      category: c,
      title: 't',
      body: 'b',
      date: kToday,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_notif_ids_atomic_test.db';
  });

  setUp(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    SharedPreferences.setMockInitialValues({});
    NotificationIds.instance.resetForTest();
  });

  tearDownAll(() async => LocalDb.close());

  test(
      'two concurrent first-time allocations for different dedupeKeys in the '
      'same category never collide on the same id — the derivation_engine.dart '
      'plain/escalated same-day exception shape', () async {
    // No NotificationCenter lock here — that lock only orders emits WITHIN
    // one isolate. `Future.wait` doesn't force true interleaving at the
    // SQLite level (see file header), but it does prove the two claims,
    // whatever order they actually run in, never land on the same slot.
    final results = await Future.wait([
      NotificationIds.instance.idFor(_ev('$kToday:exception')),
      NotificationIds.instance.idFor(_ev('$kToday:exception:medical')),
    ]);
    expect(results[0], isNot(equals(results[1])),
        reason: 'a collision here means one of the two health exceptions '
            'silently replaces the other in the shade');
  });

  test('a larger batch of concurrent distinct-key allocations stays fully '
      'distinct', () async {
    final results = await Future.wait([
      for (var i = 0; i < 50; i++)
        NotificationIds.instance.idFor(_ev('$kToday:race$i')),
    ]);
    expect(results.toSet().length, results.length);
  });

  test('the same dedupeKey allocated concurrently converges on one id',
      () async {
    final results = await Future.wait([
      for (var i = 0; i < 8; i++)
        NotificationIds.instance.idFor(_ev('$kToday:same')),
    ]);
    expect(results.toSet(), hasLength(1));
  });

  test('an allocation survives a process restart via the DB, not just prefs',
      () async {
    final first = await NotificationIds.instance.idFor(_ev('$kToday:illness'));
    NotificationIds.instance.resetForTest();
    // Wipe the prefs mirror too — only the DB should be needed to recover it.
    SharedPreferences.setMockInitialValues({});
    final again = await NotificationIds.instance.idFor(_ev('$kToday:illness'));
    expect(again, equals(first));
  });

  test('a diverged SharedPreferences mirror never wins over the DB', () async {
    final real = await NotificationIds.instance.idFor(_ev('$kToday:drift'));
    NotificationIds.instance.resetForTest();
    // Corrupt the mirror to point at a DIFFERENT slot than the DB actually
    // owns for this key — the exact shape a partial/failed prefs write, or a
    // pre-migration leftover, would leave behind.
    final cat = NotifCategory.health.name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('notif_osid:$cat:$kToday:drift', real + 1);
    final resolved = await NotificationIds.instance.idFor(_ev('$kToday:drift'));
    expect(resolved, equals(real),
        reason: 'the DB is the source of truth on every read, not only on '
            'first allocation — a stale prefs value must never override it');
  });
}
