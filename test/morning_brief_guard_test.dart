// The morning briefing's persisted guards: what a pass decides when the pending
// list cannot be read, and that moving the time A to B and back to A re-arms A.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/fired_keys.dart';
import 'package:openstrap_edge/notify/notification_center.dart';

MorningBriefAction _act({
  bool planned = true,
  bool announced = true,
  bool known = true,
  bool pending = true,
  bool armed = false,
}) =>
    NotificationCenter.morningBriefAction(
      slotPlanned: planned,
      announced: announced,
      pendingKnown: known,
      hasPending: pending,
      slotArmed: armed,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('decision', () {
    test('no planned slot cancels', () {
      expect(_act(planned: false), MorningBriefAction.cancel);
    });
    test('fresh day arms', () {
      expect(_act(announced: false, pending: false), MorningBriefAction.rearm);
    });
    test('announced and already delivered is never re-armed', () {
      expect(_act(pending: false), MorningBriefAction.preserve);
      expect(_act(pending: false, armed: false), MorningBriefAction.preserve);
    });
    test('announced, pending, same slot is preserved', () {
      expect(_act(armed: true), MorningBriefAction.preserve);
    });
    test('announced, pending, moved slot is replaced', () {
      expect(_act(armed: false), MorningBriefAction.rearm);
    });
    test('an unreadable pending list never replaces an announced day', () {
      // Unknown state is assumed pending by the caller; replacing it would
      // announce a second time if it had in fact already been delivered.
      expect(_act(known: false, pending: true, armed: false),
          MorningBriefAction.preserve);
      expect(_act(known: false, pending: true, armed: true),
          MorningBriefAction.preserve);
    });
    test('an unreadable pending list still arms a day that was never announced',
        () {
      expect(_act(announced: false, known: false, pending: true),
          MorningBriefAction.rearm);
    });
  });

  group('slot keys', () {
    const store = FiredKeyStore();
    const day = '2026-11-13';
    final prefix = '${NotificationCenter.morningBriefSlotPrefix}$day:';

    // The replacement the scheduler performs: release the day's slot keys,
    // then record the slot it armed.
    Future<void> arm(int slotMin) async {
      await store.releasePrefix(prefix);
      await store.recordFired('$prefix$slotMin');
    }

    test('A to B to A re-arms A instead of preserving B', () async {
      await arm(480); // armed for 08:00
      expect(await store.hasFired('${prefix}510'), isFalse);

      await arm(510); // user moves it to 08:30
      expect(await store.hasFired('${prefix}510'), isTrue);

      // Back to 08:00: the old key for 08:00 must not read as "armed for this
      // slot", or the pending 08:30 post would be preserved.
      expect(await store.hasFired('${prefix}480'), isFalse);
      expect(
        NotificationCenter.morningBriefAction(
          slotPlanned: true,
          announced: true,
          pendingKnown: true,
          hasPending: true,
          slotArmed: await store.hasFired('${prefix}480'),
        ),
        MorningBriefAction.rearm,
      );
    });

    test('the key families are the ones the pruner knows about', () {
      expect(FiredKeyStore.datedAfterPrefixes,
          contains(NotificationCenter.morningBriefAnnouncedPrefix));
      expect(FiredKeyStore.datedAfterPrefixes,
          contains(NotificationCenter.morningBriefSlotPrefix));
    });

    test('expiryDate reads the date inside the key', () {
      expect(FiredKeyStore.expiryDate('2026-11-13:low_read'), '2026-11-13');
      expect(
          FiredKeyStore.expiryDate(
              '${NotificationCenter.morningBriefAnnouncedPrefix}2026-11-13'),
          '2026-11-13');
      expect(FiredKeyStore.expiryDate('${prefix}480'), '2026-11-13');
      expect(FiredKeyStore.expiryDate('alarm_fired:12345'), isNull);
      expect(FiredKeyStore.expiryDate('morning_brief_slot:oops'), isNull);
    });
  });
}
