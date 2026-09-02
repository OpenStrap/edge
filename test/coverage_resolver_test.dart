// Pure unit cases for `resolveOwnership` (M5 spec §8.3). Each pins a decision
// that would otherwise be re-litigated. Fixture-independent — no
// whoop_hist.jsonl needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/coverage_resolver.dart';

void main() {
  const from = 1756713600; // fixed constant, not `now`
  const to = from + 3600; // one hour window, 60 buckets

  test('one device, full coverage: one span, the grid never allocated', () {
    final spans = resolveOwnership(
      coverage: [(deviceId: '', start: from, end: to)],
      priority: const [''],
      from: from,
      to: to,
      signal: InputSignal.hr1Hz,
    );
    expect(spans, [(start: from, end: to, deviceId: '')]);
  });

  test('no coverage at all: one null span', () {
    final spans = resolveOwnership(
      coverage: const [],
      priority: const ['ring-TEST-0001'],
      from: from,
      to: to,
      signal: InputSignal.hr1Hz,
    );
    expect(spans, [(start: from, end: to, deviceId: null)]);
  });

  test('two devices, clean handover: boundary on the higher-ranked '
      "device's interval start", () {
    final handover = from + 1800; // 30 buckets in
    final spans = resolveOwnership(
      coverage: [
        (deviceId: '', start: from, end: to),
        (deviceId: 'ring', start: handover, end: to),
      ],
      priority: const ['ring', ''],
      from: from,
      to: to,
      signal: InputSignal.hr1Hz,
    );
    expect(spans, [
      (start: from, end: handover, deviceId: ''),
      (start: handover, end: to, deviceId: 'ring'),
    ]);
  });

  test('higher-ranked device drops 2 buckets: one span, owner unchanged '
      '(the dropout stays a gap inside the span)', () {
    final dropStart = from + 600; // bucket 10
    final dropEnd = dropStart + 2 * kOwnershipBucketSeconds; // 2 buckets
    final spans = resolveOwnership(
      coverage: [
        (deviceId: '', start: from, end: to),
        (deviceId: 'ring', start: from, end: dropStart),
        (deviceId: 'ring', start: dropEnd, end: to),
      ],
      priority: const ['ring', ''],
      from: from,
      to: to,
      signal: InputSignal.hr1Hz,
    );
    expect(spans, [(start: from, end: to, deviceId: 'ring')]);
  });

  test('higher-ranked device drops 5 buckets: three spans A, B, A', () {
    final dropStart = from + 600; // bucket 10
    final dropEnd = dropStart + 5 * kOwnershipBucketSeconds; // 5 buckets
    final spans = resolveOwnership(
      coverage: [
        (deviceId: '', start: from, end: to),
        (deviceId: 'ring', start: from, end: dropStart),
        (deviceId: 'ring', start: dropEnd, end: to),
      ],
      priority: const ['ring', ''],
      from: from,
      to: to,
      signal: InputSignal.hr1Hz,
    );
    expect(spans.length, 3);
    expect(spans[0].deviceId, 'ring');
    expect(spans[1].deviceId, '');
    expect(spans[2].deviceId, 'ring');
    expect(spans[0].start, from);
    expect(spans.last.end, to);
  });

  test('lower-ranked device appears for 2 buckets inside a REAL gap '
      '(nobody covering yet): it OWNS them immediately — the asymmetric '
      'null branch, current == null is a precondition, not a competitor',
      () {
    // Nobody covers [from, from+120) — a genuine recording gap at the very
    // start of the window (current seeds as null). The ring then covers two
    // buckets while the primary still has not started; the primary only
    // starts much later. Two real candidates cover the window overall
    // (never the identity short-circuit), but at the moment the ring
    // appears, "current" is null — absence, not a rival device — so the
    // ring claims those buckets without waiting for hysteresis.
    final ringStart = from + 2 * kOwnershipBucketSeconds; // bucket 2
    final ringEnd = ringStart + 2 * kOwnershipBucketSeconds; // buckets 2-3
    final primaryStart = from + 30 * kOwnershipBucketSeconds; // bucket 30
    final spans = resolveOwnership(
      coverage: [
        (deviceId: 'ring', start: ringStart, end: ringEnd),
        (deviceId: '', start: primaryStart, end: to),
      ],
      priority: const ['', 'ring'],
      from: from,
      to: to,
      signal: InputSignal.hr1Hz,
    );
    final claimed = spanAt(spans, ringStart);
    expect(claimed, isNotNull);
    expect(claimed!.deviceId, 'ring',
        reason: 'the ring owns the buckets it appeared in immediately, '
            'with no hysteresis delay, because nothing was recording there '
            'before it');
  });

  test('output tiling: no holes, no overlaps, exact window bounds', () {
    final handover = from + 1800;
    final spans = resolveOwnership(
      coverage: [
        (deviceId: '', start: from, end: to),
        (deviceId: 'ring', start: handover, end: to),
      ],
      priority: const ['ring', ''],
      from: from,
      to: to,
      signal: InputSignal.hr1Hz,
    );
    expect(spans.first.start, from);
    expect(spans.last.end, to);
    for (var i = 0; i + 1 < spans.length; i++) {
      expect(spans[i].end, spans[i + 1].start);
    }
  });

  test('accelHighRate throws in debug — steps resolve additively, never '
      'by owner', () {
    expect(
      () => resolveOwnership(
        coverage: const [],
        priority: const [''],
        from: from,
        to: to,
        signal: InputSignal.accelHighRate,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('duplicate id in priority throws in debug', () {
    expect(
      () => resolveOwnership(
        coverage: const [],
        priority: const ['', ''],
        from: from,
        to: to,
        signal: InputSignal.hr1Hz,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('device covering but absent from priority is ignored entirely '
      '(candidacy before rank)', () {
    final spans = resolveOwnership(
      coverage: [
        (deviceId: '', start: from, end: to),
        (deviceId: 'unranked-ghost', start: from, end: to),
      ],
      priority: const [''],
      from: from,
      to: to,
      signal: InputSignal.hr1Hz,
    );
    // Only one CANDIDATE ('') is in priority, so this is the identity
    // short-circuit — the ghost device never enters the grid.
    expect(spans, [(start: from, end: to, deviceId: '')]);
  });
}
