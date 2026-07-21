// Regression tests for the Sleep page showing "Alarm sent, waiting for the
// strap to confirm." when the user never set an alarm.
//
// Root cause: the caption used to fall through to the "awaiting confirmation"
// text whenever a PERSISTED alarm epoch existed (an alarm set in a previous
// session), even though the strap-confirmation state machine is session-scoped
// and had recorded no SET this session. On a fresh open the epoch was restored
// from SharedPreferences but confirmed/pending/unconfirmed were all false, so
// the fallthrough fired the pending caption with no user tap.
//
// The fix routes the caption purely through the session-scoped machine's
// confirmed/pending/unconfirmed flags — never the persisted epoch — so an
// all-false state (fresh launch, no tap) yields no caption. These tests pin the
// mapping, driven by the real [AlarmConfirmation] transitions.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/ui/insights/coach_cards.dart';

// Caption as the widget builds it, from a confirmation machine at [nowMs].
String? captionFor(AlarmConfirmation a, int nowMs) => alarmStatusCaption(
      confirmed: a.confirmed,
      pending: a.isPending(nowMs),
      unconfirmed: a.isUnconfirmed(nowMs),
    );

void main() {
  group('alarmStatusCaption', () {
    test('fresh session (no in-session SET) shows NO caption', () {
      // This is the bug: a persisted epoch alone must not surface a caption.
      final a = AlarmConfirmation();
      expect(captionFor(a, 0), isNull);
    });

    test('after a SET this session → "Setting alarm…" inside the grace window', () {
      final a = AlarmConfirmation(graceMs: 6000);
      a.set(1750000000, 0);
      expect(captionFor(a, 0), 'Setting alarm…');
      expect(captionFor(a, 5999), 'Setting alarm…');
    });

    test('SET with no confirm past the grace window → awaiting-confirm caption', () {
      final a = AlarmConfirmation(graceMs: 6000);
      a.set(1750000000, 0);
      expect(captionFor(a, 6000), 'Alarm sent, waiting for the strap to confirm.');
    });

    test('strap confirms (event 56) → "Alarm set ✓"', () {
      final a = AlarmConfirmation(graceMs: 6000);
      a.set(1750000000, 0);
      a.onEvent(AlarmConfirmation.kEvtSet, 100);
      expect(captionFor(a, 10000), 'Alarm set ✓');
    });

    test('disable clears the caption back to idle', () {
      final a = AlarmConfirmation(graceMs: 6000);
      a.set(1750000000, 0);
      a.onEvent(AlarmConfirmation.kEvtSet, 100);
      a.onEvent(AlarmConfirmation.kEvtDisabled, 200);
      expect(captionFor(a, 10000), isNull);
    });

    test('pure mapping: precedence confirmed > pending > unconfirmed > null', () {
      expect(
        alarmStatusCaption(confirmed: true, pending: true, unconfirmed: true),
        'Alarm set ✓',
      );
      expect(
        alarmStatusCaption(confirmed: false, pending: true, unconfirmed: true),
        'Setting alarm…',
      );
      expect(
        alarmStatusCaption(confirmed: false, pending: false, unconfirmed: true),
        'Alarm sent, waiting for the strap to confirm.',
      );
      expect(
        alarmStatusCaption(confirmed: false, pending: false, unconfirmed: false),
        isNull,
      );
    });
  });
}
