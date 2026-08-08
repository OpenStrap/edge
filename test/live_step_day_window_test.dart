// The Today tile must not carry yesterday's steps into today.
//
// From TestFlight: "steps and calories are not resetting every day - it's
// accumulating". The tile shows `derived day total + live session steps`, and
// the live half counts since the BLE connection began. This app holds ONE
// continuous connection by design, so that counter spans midnight — at 00:01
// the tile showed yesterday's live total on top of today's derived zero.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

void main() {
  test('a connection that spans midnight starts today at zero', () {
    final w = LiveStepDayWindow();
    // A session on one day: everything the counter holds is that day's.
    expect(w.stepsToday(4000, '2026-08-08'), 4000);

    // Midnight. Those 4,000 steps are yesterday's, and yesterday's derived
    // total already carries them.
    expect(w.stepsToday(4000, '2026-08-09'), 0);

    // The counter keeps climbing from where it was; only the new steps count.
    expect(w.stepsToday(4120, '2026-08-09'), 120);
  });

  test('a reconnect mid-day does not stop the count', () {
    final w = LiveStepDayWindow();
    expect(w.stepsToday(900, '2026-08-08'), 900);

    // Reconnect: the session counter restarts at 0. A stale base would make
    // every later reading negative, and clamping that at zero would silently
    // stop counting for the rest of the day.
    expect(w.stepsToday(0, '2026-08-08'), 0);
    expect(w.stepsToday(60, '2026-08-08'), 60);
  });

  test('a reconnect immediately after midnight counts from zero', () {
    final w = LiveStepDayWindow();
    w.stepsToday(7000, '2026-08-08');
    expect(w.stepsToday(0, '2026-08-09'), 0);
    expect(w.stepsToday(250, '2026-08-09'), 250);
  });

  test('a first-ever observation counts in full — it cannot be yesterday', () {
    // The counter is per-connection and per-process, so on a FIRST observation
    // whatever it holds was walked in this session, today. Rebasing here would
    // discard a real walk (the live-coverage suite catches exactly that). The
    // midnight case is covered by having OBSERVED the earlier day, which the
    // sample path guarantees independently of whether any screen is built.
    final w = LiveStepDayWindow();
    expect(w.stepsToday(3300, '2026-08-09'), 3300);
    expect(w.stepsToday(3400, '2026-08-09'), 3400);
  });

  test('never returns a negative count', () {
    final w = LiveStepDayWindow();
    w.stepsToday(100, '2026-08-08');
    expect(w.stepsToday(-5, '2026-08-08'), 0);
  });

  test('days are tracked, so a skipped day still rebases', () {
    final w = LiveStepDayWindow();
    w.stepsToday(1000, '2026-08-08');
    // The phone was off for a day; the band reconnected and kept counting.
    expect(w.stepsToday(1500, '2026-08-10'), 0);
    expect(w.day, '2026-08-10');
  });
}
