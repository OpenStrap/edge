// Tests for MedBuzzer — the strap-haptic half of the medication reminder.
//
// The OS notification is the half that actually reminds (it fires with no Dart
// running); the buzz only works with a live link and a live isolate, so it is
// best-effort by design. What is pinned here:
//   • a connected band gets one buzz per slot, then the timer re-arms onward;
//   • a disconnected band swallows the slot SILENTLY — a late buzz for a dose
//     window that already passed is noise about a decision already made;
//   • past slots handed to configure() are skipped, not fired late;
//   • dispose() stops everything (the AppState teardown path);
//   • a timer that expires long after its slot in wall-clock terms (the
//     monotonic clock stalls while the device sleeps) does not buzz, and the
//     other missed slots don't then buzz back to back.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/med_buzzer.dart';

class _Harness {
  int buzzes = 0;
  bool connected = true;
  late MedBuzzer buzzer;

  DateTime? wall; // when set, the buzzer's wall clock

  _Harness() {
    buzzer = MedBuzzer(
      buzz: () async => buzzes++,
      isConnected: () => connected,
      now: () => wall ?? DateTime.now(),
    );
  }
}

void main() {
  test('fires once at the slot when the band is connected', () async {
    final h = _Harness();
    final at = DateTime.now().add(const Duration(milliseconds: 40));
    h.buzzer.configure(slotInstants: [at]);

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(h.buzzes, 1);
    h.buzzer.dispose();
  });

  test('a disconnected band misses the slot silently — no late buzz',
      () async {
    final h = _Harness()..connected = false;
    h.buzzer
        .configure(slotInstants: [DateTime.now().add(const Duration(milliseconds: 30))]);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.buzzes, 0);

    // Reconnecting afterwards must not retro-fire: the slot was consumed.
    h.connected = true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(h.buzzes, 0);
    h.buzzer.dispose();
  });

  test('past slots are skipped, not fired late', () async {
    final h = _Harness();
    h.buzzer.configure(slotInstants: [
      DateTime.now().subtract(const Duration(minutes: 90)),
    ]);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(h.buzzes, 0);
    h.buzzer.dispose();
  });

  test('multiple slots fire in order, one buzz each', () async {
    final h = _Harness();
    final now = DateTime.now();
    h.buzzer.configure(slotInstants: [
      now.add(const Duration(milliseconds: 30)),
      now.add(const Duration(milliseconds: 80)),
    ]);

    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(h.buzzes, 2);
    h.buzzer.dispose();
  });

  test('reconfigure replaces the pending schedule', () async {
    final h = _Harness();
    final now = DateTime.now();
    h.buzzer.configure(slotInstants: [now.add(const Duration(milliseconds: 30))]);
    // Before the first slot lands, re-arm to a later one. The old timer must
    // be cancelled — otherwise both fire.
    h.buzzer.configure(
        slotInstants: [now.add(const Duration(milliseconds: 120))]);

    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(h.buzzes, 0, reason: 'old slot was superseded');
    await Future<void>.delayed(const Duration(milliseconds: 110));
    expect(h.buzzes, 1, reason: 'new slot fires exactly once');
    h.buzzer.dispose();
  });

  test('dispose cancels the pending slot', () async {
    final h = _Harness();
    h.buzzer.configure(
        slotInstants: [DateTime.now().add(const Duration(milliseconds: 30))]);
    h.buzzer.dispose();

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.buzzes, 0);
  });

  test('a timer that fires hours late (device slept) does not buzz', () async {
    final base = DateTime(2026, 10, 22, 8);
    final h = _Harness()..wall = base;
    h.buzzer.configure(
        slotInstants: [base.add(const Duration(milliseconds: 30))]);
    // The phone sat in deep sleep: wall-clock moved on, the timer didn't.
    h.wall = base.add(const Duration(hours: 3));

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.buzzes, 0);
    h.buzzer.dispose();
  });

  test('missed slots after a suspend do not buzz back to back', () async {
    final base = DateTime(2026, 10, 22, 8);
    final h = _Harness()..wall = base;
    h.buzzer.configure(slotInstants: [
      base.add(const Duration(milliseconds: 30)),
      base.add(const Duration(hours: 1)),
      base.add(const Duration(hours: 2, milliseconds: 60)),
    ]);
    // Wake at 10:00: the first two slots are long gone, the third is still
    // ahead and must keep its own timer.
    h.wall = base.add(const Duration(hours: 2));

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(h.buzzes, 0, reason: 'overdue slots are dropped, not replayed');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(h.buzzes, 1, reason: 'the on-time slot still buzzes');
    h.buzzer.dispose();
  });

  test('a fire a few seconds late still buzzes', () async {
    final base = DateTime(2026, 10, 22, 8);
    final h = _Harness()..wall = base;
    h.buzzer.configure(
        slotInstants: [base.add(const Duration(milliseconds: 30))]);
    h.wall = base.add(const Duration(seconds: 5));

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.buzzes, 1);
    h.buzzer.dispose();
  });
}
