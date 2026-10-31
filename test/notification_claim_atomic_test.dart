// Atomic cross-isolate fire-once for notification dedupeKeys (issue #136 tail).
//
// The sibling suite (notification_dedupe_test.dart) runs with no sqlite factory
// and covers the degraded SharedPreferences fallback. THIS suite runs the real
// LocalDb via sqflite_common_ffi, so it exercises the path that actually ships:
// FiredKeyStore.claim → LocalDb.claimNotifFired → one atomic INSERT OR IGNORE.
//
// Why this can be tested in-process at all: the race being fixed is two
// derivation isolates racing between "has it fired?" and "record that it fired".
// A unit test can't spawn the WorkManager isolate, but it doesn't need to — both
// isolates reach the SAME sqlite database, and the claim's correctness is a
// property of the statement, not of who calls it. Calling claim() concurrently
// WITHOUT NotificationCenter's in-isolate lock reproduces exactly the
// interleaving the other isolate would produce: two claimants, no ordering
// between them. Under the old check-then-record protocol both would win.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/fired_keys.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';

NotificationEvent _ev(String dedupeKey) => NotificationEvent(
      dedupeKey: dedupeKey,
      category: NotifCategory.health,
      title: 't',
      body: 'b',
      date: dedupeKey.split(':').first,
      // critical so quiet hours can never mask a failure to dedupe.
      priority: NotifPriority.critical,
    );

/// A local YYYY-MM-DD offset from today — same convention the store's retention
/// cutoff uses (day labels are LOCAL everywhere; see data/day_label.dart).
String _dayOffset(int days) => dayLabelOf(DateTime.now().add(Duration(days: days)));

/// Claims older than the store's retention are pruned on every won claim, so a
/// fixed calendar date in these keys stops being claimable once it ages out.
final String _today = _dayOffset(0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_notif_claim_test.db';
  });

  setUp(() async {
    // A fresh DB per test: the claim table is the unit under test, so leaked
    // rows between tests would mask a real failure to claim.
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    SharedPreferences.setMockInitialValues({});
  });

  tearDownAll(() async => LocalDb.close());

  group('atomic claim', () {
    test('exactly one of two concurrent claimants for the same key wins',
        () async {
      const store = FiredKeyStore();
      final key = '$_today:readiness';

      // No in-isolate lock here — this is the cross-isolate shape.
      final results = await Future.wait([
        store.claim(key),
        store.claim(key),
        store.claim(key),
      ]);

      expect(results.where((won) => won).length, 1,
          reason: 'a second claimant presenting is the duplicate alert');
      expect(await store.hasFired(key), isTrue);
    });

    test('a claim released (present failed) is claimable again', () async {
      const store = FiredKeyStore();
      final key = '$_today:low_read';

      expect(await store.claim(key), isTrue);
      await store.release(key);
      // The whole point: a permission-denied no-op must not consume the day's
      // only chance to fire this insight.
      expect(await store.hasFired(key), isFalse);
      expect(await store.claim(key), isTrue);
      expect(await store.claim(key), isFalse);
    });

    test('distinct keys never contend', () async {
      const store = FiredKeyStore();
      final results = await Future.wait([
        store.claim('${_dayOffset(0)}:a'),
        store.claim('${_dayOffset(0)}:b'),
        store.claim('${_dayOffset(0)}:c'),
      ]);
      expect(results, everyElement(isTrue));
    });

    test('a key that fired in degraded mode never fires again once the DB is '
        'back — however many passes run', () async {
      const store = FiredKeyStore();
      final key = '$_today:low_read';

      // The exact on-disk state left by a fallback claim taken while the DB was
      // unusable: the prefs mirror remembers the fire, the claim table doesn't.
      SharedPreferences.setMockInitialValues({'notif_fired:$key': true});

      // Every subsequent pass (each background derive is one) must lose. The
      // first reconciling pass is the easy case; the ones after it are where a
      // reconciliation that ERASED the mirror would hand the key back out and
      // re-alert.
      for (var pass = 0; pass < 3; pass++) {
        expect(await store.claim(key), isFalse, reason: 'pass $pass re-fired');
      }

      // Reconciled forward: the claim table now records the fire too, so the
      // mirror is no longer the only thing standing between us and a repeat.
      expect(await LocalDb.notifFiredExists(key), isTrue);
      expect(await store.hasFired(key), isTrue);
    });

    test('the claim survives a store instance being thrown away (restart)',
        () async {
      final key = '$_today:sync_stale';
      expect(await const FiredKeyStore().claim(key), isTrue);
      await LocalDb.close(); // simulate a process teardown between passes
      expect(await const FiredKeyStore().claim(key), isFalse);
    });
  });

  group('emit integration', () {
    late NotificationCenter center;

    setUp(() {
      center = NotificationCenter.instance;
    });

    test('a denied present leaves the key free to fire later', () async {
      final shown = <String>[];
      var grant = false;
      center.presentSink = (e, {bool allowPermissionPrompt = true}) async {
        if (!grant) return false;
        shown.add(e.dedupeKey);
        return true;
      };

      await center.emit(_ev('$_today:temp'));
      expect(shown, isEmpty);

      grant = true;
      await center.emit(_ev('$_today:temp'));
      expect(shown, ['$_today:temp']);

      // ...and now it's spent.
      await center.emit(_ev('$_today:temp'));
      expect(shown, ['$_today:temp']);
    });

    test('a throwing present does not consume the key', () async {
      final shown = <String>[];
      var boom = true;
      center.presentSink = (e, {bool allowPermissionPrompt = true}) async {
        if (boom) throw StateError('OS layer blew up');
        shown.add(e.dedupeKey);
        return true;
      };

      await center.emit(_ev('$_today:auto_workout')); // swallowed by emit
      boom = false;
      await center.emit(_ev('$_today:auto_workout'));
      expect(shown, ['$_today:auto_workout']);
    });
  });

  group('legacy migration', () {
    test('keys that already fired under the old shared list do not re-fire',
        () async {
      // Pre-#145 on-disk shape: one shared list of fired keys.
      final already = '$_today:low_read';
      SharedPreferences.setMockInitialValues({
        FiredKeyStore.legacyListKey: <String>[already, '$_today:step_goal'],
      });

      const store = FiredKeyStore();
      expect(await store.claim(already), isFalse,
          reason: 'upgrading must not re-alert the day\'s already-fired keys');
      expect(await store.claim('$_today:step_goal'), isFalse);
      // A key that never fired is still free.
      expect(await store.claim('$_today:recovery_ready'), isTrue);

      // The legacy list is consumed, not left behind as a dead pref.
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getStringList(FiredKeyStore.legacyListKey), isNull);
    });

    test('migration is idempotent across repeated claims', () async {
      SharedPreferences.setMockInitialValues({
        FiredKeyStore.legacyListKey: <String>['$_today:x'],
      });
      const store = FiredKeyStore();
      expect(await store.claim('$_today:x'), isFalse);
      expect(await store.claim('$_today:x'), isFalse);
      expect(await store.claim('$_today:y'), isTrue);
    });
  });

  group('retention', () {
    test('dated claims older than the window are pruned; recent ones survive',
        () async {
      const store = FiredKeyStore();
      final stale = '${_dayOffset(-(FiredKeyStore.retentionDays + 5))}:low_read';
      final fresh = '${_dayOffset(-1)}:low_read';
      await LocalDb.seedNotifFired([stale, fresh]);

      // Any successful claim triggers a prune pass.
      expect(await store.claim('${_dayOffset(0)}:trigger'), isTrue);

      expect(await LocalDb.notifFiredExists(stale), isFalse);
      expect(await LocalDb.notifFiredExists(fresh), isTrue);
    });

    test('the prefs mirror is pruned too when the DB is healthy', () async {
      // The mirror is written on every won claim, so without its own prune it
      // grows by one key per notification for the life of the install.
      final stale = '${_dayOffset(-(FiredKeyStore.retentionDays + 5))}:low_read';
      final fresh = '${_dayOffset(-1)}:low_read';
      SharedPreferences.setMockInitialValues({
        'notif_fired:$stale': true,
        'notif_fired:$fresh': true,
        'notif_fired:alarm_fired:12345': true,
      });

      expect(await const FiredKeyStore().claim('${_dayOffset(0)}:trigger'),
          isTrue);

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.containsKey('notif_fired:$stale'), isFalse);
      expect(prefs.getBool('notif_fired:$fresh'), isTrue);
      expect(prefs.getBool('notif_fired:alarm_fired:12345'), isTrue);
    });

    test('undated claims (alarm_fired:<epoch>) are never pruned', () async {
      const store = FiredKeyStore();
      await LocalDb.seedNotifFired(['alarm_fired:12345']);
      expect(await store.claim('${_dayOffset(0)}:trigger'), isTrue);
      expect(await LocalDb.notifFiredExists('alarm_fired:12345'), isTrue);
    });
  });
}
