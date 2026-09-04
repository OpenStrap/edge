// The mandatory adapter test (MULTIBAND_PLAN §3.3.3), qhybrid's shape: this
// adapter declares NO signals at all, so there is nothing to assert arrives —
// what matters instead is the self-confirming probe (see `qhybrid.dart`'s own
// header) and that everything past it is banked raw, undecoded, never as an
// [OffloadCheckpoint].

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/qhybrid.dart';

void main() {
  test('a confirmed probe unlocks the raw stream, and the reply itself is '
      'swallowed rather than banked', () async {
    final link = ReplayBandLink();
    final adapter = const QHybridAdapter(probeTimeout: Duration(seconds: 1));
    final events = <BandEvent>[];
    final sub = adapter.run(link).listen(events.add);

    // Give the adapter a beat to subscribe and write its probe before the
    // reply is fed — a real radio never delivers a notification before the
    // characteristic that produced it has been written to.
    await Future<void>.delayed(Duration.zero);
    expect(link.writes, [(kQHybridControlChar, const [1, 8])]);

    link.feed(kQHybridControlChar, const [3, 8, 61], atSec: 1_800_000_000);
    await Future<void>.delayed(Duration.zero);
    // A button press, then a chunk on the file-download characteristic —
    // neither is the probe reply, both must be banked verbatim.
    link.feed(kQHybridButtonChar, const [1, 2, 3], atSec: 1_800_000_001);
    link.feed(kQHybridFileChar1, const [9, 9], atSec: 1_800_000_002);
    await Future<void>.delayed(Duration.zero);
    // A real disconnect is a HOST-side cancellation of this subscription
    // (`adapter.dart`'s own documented lifecycle), never the link's notify
    // streams ending on their own — so that is what tears this one down too.
    await sub.cancel();

    final raw = [
      for (final e in events)
        if (e is SampleBatch) ...?e.raw,
    ];
    expect(raw, [
      [1, 2, 3],
      [9, 9],
    ]);
    // Nothing here is decoded into a sample, and nothing here stores flash on
    // our say-so.
    expect(events.every((e) => e is! SampleBatch || e.samples.isEmpty), isTrue);
    expect(events.whereType<OffloadCheckpoint>(), isEmpty);
    expect(adapter.signals, isEmpty);
  });

  test('no probe reply within the window abstains cleanly — nothing banked',
      () async {
    final link = ReplayBandLink();
    final adapter = const QHybridAdapter(probeTimeout: Duration(milliseconds: 50));
    final events = <BandEvent>[];
    final done = Completer<void>();
    final sub = adapter.run(link).listen(events.add, onDone: done.complete);

    // A notification that arrives before the probe is ever confirmed — the
    // encrypted sibling protocol answering something unrelated, say — must
    // not be banked: confirmation gates everything past it.
    await Future<void>.delayed(Duration.zero);
    link.feed(kQHybridButtonChar, const [9, 9, 9], atSec: 1_800_000_000);

    await done.future.timeout(const Duration(seconds: 2));
    await sub.cancel();
    expect(events, isEmpty);
  });

  test('a refused probe write ends the stream without waiting out the '
      'timeout', () async {
    final link = ReplayBandLink()..writeSucceeds = false;
    final adapter = const QHybridAdapter(probeTimeout: Duration(seconds: 5));
    final events = await adapter.run(link).toList();
    expect(events, isEmpty);
  });
}
