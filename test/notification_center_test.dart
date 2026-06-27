// Unit tests for the notification gating + id partitioning — the pure logic that
// decides whether an event reaches the OS and which id it lands on. No plugins:
// we construct NotificationPrefs/NotificationEvent directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';

NotificationEvent _ev(NotifCategory c, NotifPriority p) => NotificationEvent(
      dedupeKey: '2026-06-27:${c.name}',
      category: c,
      priority: p,
      title: 't',
      body: 'b',
      date: '2026-06-27',
    );

void main() {
  group('quiet hours window', () {
    const p = NotificationPrefs(quietStartMin: 22 * 60, quietEndMin: 7 * 60);
    test('wraps midnight', () {
      expect(p.inQuietHours(23 * 60), isTrue); // 23:00
      expect(p.inQuietHours(2 * 60), isTrue); // 02:00
      expect(p.inQuietHours(6 * 60 + 59), isTrue); // 06:59
      expect(p.inQuietHours(7 * 60), isFalse); // 07:00 exclusive end
      expect(p.inQuietHours(12 * 60), isFalse); // noon
      expect(p.inQuietHours(22 * 60), isTrue); // 22:00 inclusive start
    });
    test('non-wrapping window', () {
      const d = NotificationPrefs(quietStartMin: 1 * 60, quietEndMin: 5 * 60);
      expect(d.inQuietHours(3 * 60), isTrue);
      expect(d.inQuietHours(6 * 60), isFalse);
      expect(d.inQuietHours(0), isFalse);
    });
    test('disabled quiet hours never matches', () {
      const d = NotificationPrefs(quietEnabled: false);
      expect(d.inQuietHours(2 * 60), isFalse);
    });
  });

  group('shouldFireOs', () {
    const p = NotificationPrefs(); // defaults: all on, quiet 22–07, override on
    test('fires outside quiet hours', () {
      expect(p.shouldFireOs(_ev(NotifCategory.recovery, NotifPriority.normal),
          12 * 60), isTrue);
    });
    test('suppresses non-critical inside quiet hours', () {
      expect(p.shouldFireOs(_ev(NotifCategory.recovery, NotifPriority.normal),
          2 * 60), isFalse);
      expect(p.shouldFireOs(_ev(NotifCategory.reminders, NotifPriority.low),
          2 * 60), isFalse);
    });
    test('critical overrides quiet hours when allowed', () {
      expect(p.shouldFireOs(_ev(NotifCategory.health, NotifPriority.critical),
          2 * 60), isTrue);
    });
    test('critical respects quiet hours when override is off', () {
      const d = NotificationPrefs(criticalOverridesQuiet: false);
      expect(d.shouldFireOs(_ev(NotifCategory.health, NotifPriority.critical),
          2 * 60), isFalse);
    });
    test('disabled category never fires', () {
      const d = NotificationPrefs(healthEnabled: false);
      expect(d.shouldFireOs(_ev(NotifCategory.health, NotifPriority.critical),
          12 * 60), isFalse);
    });
  });

  group('osId partitioning', () {
    test('categories land in disjoint bands', () {
      final health = _ev(NotifCategory.health, NotifPriority.critical).osId;
      final recovery = _ev(NotifCategory.recovery, NotifPriority.normal).osId;
      final reminders = _ev(NotifCategory.reminders, NotifPriority.low).osId;
      expect(health ~/ 100000, equals(3));
      expect(recovery ~/ 100000, equals(2));
      expect(reminders ~/ 100000, equals(4));
    });
    test('same logical event yields a stable id (replace, not stack)', () {
      final a = NotificationEvent(
          dedupeKey: '2026-06-27:illness',
          category: NotifCategory.health,
          title: 'x',
          body: 'y',
          date: '2026-06-27');
      final b = NotificationEvent(
          dedupeKey: '2026-06-27:illness',
          category: NotifCategory.health,
          title: 'different title',
          body: 'different body',
          date: '2026-06-27');
      expect(a.osId, equals(b.osId));
    });
  });
}
