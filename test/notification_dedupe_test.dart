// Tests for the persistent fire-once dedupe guard added for issue #136.
//
// NotificationCenter.emit must present a given dedupeKey to the OS at most once,
// persisted across restarts, while a fresh (e.g. next-day) key still fires and
// the existing category/quiet-hours gating is untouched. We inject a fake
// present sink (counts calls, no device) and a mocked SharedPreferences.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/fired_keys.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';

/// Records every event handed to the OS layer so tests can assert call counts.
class _FakeSink {
  final List<NotificationEvent> shown = [];
  bool grant; // false simulates permission-denied (nothing actually shown)

  _FakeSink({this.grant = true});

  Future<bool> call(NotificationEvent e, {bool allowPermissionPrompt = true}) async {
    if (!grant) return false;
    shown.add(e);
    return true;
  }
}

NotificationEvent _ev(
  String dedupeKey, {
  NotifCategory category = NotifCategory.health,
  NotifPriority priority = NotifPriority.critical,
  String date = '2026-07-23',
}) =>
    NotificationEvent(
      dedupeKey: dedupeKey,
      category: category,
      priority: priority,
      title: 't',
      body: 'b',
      date: date,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final center = NotificationCenter.instance;
  late Future<bool> Function(NotificationEvent, {bool allowPermissionPrompt})
      original;

  setUp(() {
    // Quiet hours off + all categories on, so gating never interferes with the
    // dedupe-focused tests (the gating tests set their own values).
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
    original = center.presentSink;
  });

  tearDown(() {
    center.presentSink = original;
  });

  group('emit dedupe (issue #136)', () {
    test('same dedupeKey fires the OS notification exactly once', () async {
      final sink = _FakeSink();
      center.presentSink = sink.call;

      final e = _ev('2026-07-23:irregular');
      await center.emit(e);
      await center.emit(e); // re-derive would re-emit the same key
      await center.emit(e);

      expect(sink.shown.length, 1);
    });

    test('a different (next-day) key fires again', () async {
      final sink = _FakeSink();
      center.presentSink = sink.call;

      await center.emit(_ev('2026-07-23:irregular', date: '2026-07-23'));
      await center.emit(_ev('2026-07-24:irregular', date: '2026-07-24'));

      expect(sink.shown.length, 2);
      expect(
        sink.shown.map((e) => e.dedupeKey),
        containsAll(['2026-07-23:irregular', '2026-07-24:irregular']),
      );
    });

    test('the guard survives via SharedPreferences (restart-safe)', () async {
      // First "session": key fires once and is recorded to SharedPreferences —
      // the same on-disk store that survives an app restart on-device.
      final sink1 = _FakeSink();
      center.presentSink = sink1.call;
      await center.emit(_ev('2026-07-23:illness'));
      expect(sink1.shown.length, 1);

      // Second "session": same persisted store — the key is still remembered,
      // so it must NOT fire again.
      final sink2 = _FakeSink();
      center.presentSink = sink2.call;
      await center.emit(_ev('2026-07-23:illness'));
      expect(sink2.shown, isEmpty);
    });

    test('a permission-denied no-op does not consume the key', () async {
      // Present fails (permission denied) → key not recorded → a later grant
      // still lets it fire.
      final denied = _FakeSink(grant: false);
      center.presentSink = denied.call;
      await center.emit(_ev('2026-07-23:temp'));

      final granted = _FakeSink();
      center.presentSink = granted.call;
      await center.emit(_ev('2026-07-23:temp'));
      expect(granted.shown.length, 1);
    });
  });

  group('emit still respects gating', () {
    test('a disabled category never presents (and is not recorded)', () async {
      SharedPreferences.setMockInitialValues({'notif_health': false});
      final sink = _FakeSink();
      center.presentSink = sink.call;

      await center.emit(_ev('2026-07-23:illness', category: NotifCategory.health));
      expect(sink.shown, isEmpty);

      // Re-enabling the category later must let the key fire — the gate, not the
      // dedupe guard, suppressed it, so no key should have been recorded.
      expect(await const FiredKeyStore().hasFired('2026-07-23:illness'), isFalse);
    });

    test('quiet hours suppress a non-critical event', () async {
      // A window covering the whole day → now is always inside quiet hours.
      SharedPreferences.setMockInitialValues({
        'notif_quiet_enabled': true,
        'notif_quiet_start': 0,
        'notif_quiet_end': 1440,
      });
      final sink = _FakeSink();
      center.presentSink = sink.call;

      await center.emit(_ev(
        '2026-07-23:recovery',
        category: NotifCategory.recovery,
        priority: NotifPriority.normal,
      ));
      expect(sink.shown, isEmpty);
    });

    test('a critical event overrides quiet hours (default) and still fires once',
        () async {
      SharedPreferences.setMockInitialValues({
        'notif_quiet_enabled': true,
        'notif_quiet_start': 0,
        'notif_quiet_end': 1440,
      });
      final sink = _FakeSink();
      center.presentSink = sink.call;

      final e = _ev('2026-07-23:illness', priority: NotifPriority.critical);
      await center.emit(e);
      await center.emit(e);
      expect(sink.shown.length, 1);
    });
  });

  group('FiredKeyStore bounding', () {
    test('hasFired reflects recordFired', () async {
      SharedPreferences.setMockInitialValues({});
      const store = FiredKeyStore();
      expect(await store.hasFired('a'), isFalse);
      await store.recordFired('a');
      expect(await store.hasFired('a'), isTrue);
    });

    test('a repeated record neither duplicates nor refreshes recency', () async {
      SharedPreferences.setMockInitialValues({});
      const store = FiredKeyStore();
      await store.recordFired('a');
      await store.recordFired('b');
      await store.recordFired('a'); // hit — must be a no-op
      final p = await SharedPreferences.getInstance();
      // 'a' stays in its original (oldest) slot; no duplicate appended.
      expect(p.getStringList('notif_fired_keys'), ['a', 'b']);
    });

    test('caps at maxKeys, evicting oldest first', () async {
      SharedPreferences.setMockInitialValues({});
      const store = FiredKeyStore();
      for (var i = 0; i < FiredKeyStore.maxKeys + 5; i++) {
        await store.recordFired('k$i');
      }
      final p = await SharedPreferences.getInstance();
      final keys = p.getStringList('notif_fired_keys')!;
      expect(keys.length, FiredKeyStore.maxKeys);
      // Oldest five evicted; newest retained.
      expect(await store.hasFired('k0'), isFalse);
      expect(await store.hasFired('k4'), isFalse);
      expect(await store.hasFired('k5'), isTrue);
      expect(await store.hasFired('k${FiredKeyStore.maxKeys + 4}'), isTrue);
    });
  });
}
