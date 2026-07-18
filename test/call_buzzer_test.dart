// call_buzzer_test.dart — the incoming-call ring cadence (see CallBuzzer).
// Drives handleStateEvent directly so no platform channel is involved; timers
// run under fakeAsync so the cadence is asserted deterministically.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/call_buzzer.dart';

void main() {
  CallBuzzer make(void Function() onBuzz, {bool connected = true}) =>
      CallBuzzer(
        buzz: () async => onBuzz(),
        isConnected: () => connected,
      );

  test('ringing buzzes immediately, then on the cadence until idle', () {
    fakeAsync((async) {
      var buzzes = 0;
      final cb = make(() => buzzes++);
      cb.handleStateEvent('ringing');
      expect(buzzes, 1, reason: 'first buzz fires the moment ringing starts');
      async.elapse(CallBuzzer.repeatEvery * 2 + const Duration(seconds: 1));
      expect(buzzes, 3, reason: 'one more buzz per elapsed cadence interval');
      cb.handleStateEvent('idle'); // rang out / declined
      async.elapse(const Duration(minutes: 1));
      expect(buzzes, 3, reason: 'idle stops the cadence dead');
    });
  });

  test('answering (offhook) stops the cadence', () {
    fakeAsync((async) {
      var buzzes = 0;
      final cb = make(() => buzzes++);
      cb.handleStateEvent('ringing');
      async.elapse(CallBuzzer.repeatEvery + const Duration(seconds: 1));
      expect(buzzes, 2);
      cb.handleStateEvent('offhook');
      async.elapse(const Duration(minutes: 5)); // long call — no buzzing through it
      expect(buzzes, 2);
    });
  });

  test('a stuck RINGING state is capped at maxBuzzes', () {
    fakeAsync((async) {
      var buzzes = 0;
      final cb = make(() => buzzes++);
      cb.handleStateEvent('ringing'); // no idle/offhook ever arrives
      async.elapse(const Duration(minutes: 10));
      expect(buzzes, CallBuzzer.maxBuzzes);
    });
  });

  test('duplicate ringing events do not restart the cadence', () {
    fakeAsync((async) {
      var buzzes = 0;
      final cb = make(() => buzzes++);
      cb.handleStateEvent('ringing');
      async.elapse(const Duration(seconds: 1));
      cb.handleStateEvent('ringing'); // repeated native event mid-ring
      expect(buzzes, 1, reason: 'no double-buzz from a repeated event');
      async.elapse(const Duration(minutes: 1));
      expect(buzzes, CallBuzzer.maxBuzzes,
          reason: 'cap unchanged — cadence was not restarted');
    });
  });

  test('band disconnected: ticks count toward the cap but nothing buzzes', () {
    fakeAsync((async) {
      var buzzes = 0;
      final cb = make(() => buzzes++, connected: false);
      cb.handleStateEvent('ringing');
      async.elapse(const Duration(minutes: 1));
      expect(buzzes, 0, reason: 'no link — no writes');
    });
  });

  test('duplicate ringing after the cap does not restart the cadence', () {
    fakeAsync((async) {
      var buzzes = 0;
      final cb = make(() => buzzes++);
      cb.handleStateEvent('ringing');
      async.elapse(const Duration(minutes: 2)); // well past the cap
      expect(buzzes, CallBuzzer.maxBuzzes);
      // Some OEMs re-emit RINGING for the same call with no terminal state in
      // between — that must NOT buzz another full cadence.
      cb.handleStateEvent('ringing');
      async.elapse(const Duration(minutes: 2));
      expect(buzzes, CallBuzzer.maxBuzzes,
          reason: 'same call — no fresh cadence without idle/offhook between');
    });
  });

  test('a new ring after idle starts a fresh cadence', () {
    fakeAsync((async) {
      var buzzes = 0;
      final cb = make(() => buzzes++);
      cb.handleStateEvent('ringing');
      async.elapse(const Duration(minutes: 1)); // rings out to the cap
      expect(buzzes, CallBuzzer.maxBuzzes);
      cb.handleStateEvent('idle');
      cb.handleStateEvent('ringing'); // caller tries again
      expect(buzzes, CallBuzzer.maxBuzzes + 1,
          reason: 'fresh ring buzzes immediately again');
    });
  });
}
