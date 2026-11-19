import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import '../support/layout_shift_probe.dart';
import '../support/shift_run.dart';

class _Pending extends StatelessWidget {
  const _Pending({required this.pending, required this.child});
  final bool pending;
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

void main() {
  // WHY: an adapter must classify loading paint without importing app widgets.
  // Catches: ignoring isPending or merging the placeholder into its envelope.
  testWidgets('adapter preserves placeholder fill in a keyed envelope', (t) async {
    final probe = ShiftProbe(trackUnkeyed: true,
      isPending: (w) => w is _Pending && w.pending);
    Widget app(bool pending) => MaterialApp(home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(key: const ValueKey('envelope'), width: 200, height: 100,
        child: _Pending(pending: pending, child: const Text('Result')))));
    await t.pumpWidget(app(true));
    final before = probe.capture(t, atMs: 0);
    probe.interactions.add(const Interaction(0, 'open'));
    expect(before.elements.where((e) => e.id.startsWith('~pending|')),
      hasLength(1));
    await t.pumpWidget(app(false));
    probe.capture(t, atMs: 2500);
    expect(score(probe.scenario(shiftViewport),
      ShiftPolicy.standard.copyWith(loadWeight: 0, colorWeight: 0))
      .findings.where((f) => f.rule == 'appear'), isEmpty);
  });

  // WHY: settling between offsets can silently remove the frames being scored.
  // Catches: adding extra pumps to frames or recording wall-clock timestamps.
  testWidgets('driver captures exact offsets and records tap source', (t) async {
    await t.pumpWidget(MaterialApp(home: Center(child: TextButton(
      key: const ValueKey('go'), onPressed: () {}, child: const Text('Go')))));
    final run = ShiftRun(t, trackUnkeyed: false);
    run.opened();
    await run.frames([0, 16, 50]);
    expect(run.probe.frames.map((f) => f.atMs), [0, 0, 16, 50]);
    await run.tap(find.byKey(const ValueKey('go')), [0, 100]);
    expect(run.now, 150);
    expect(run.probe.interactions.map((i) => (i.atMs, i.sourceId)),
      [(0, 'screen-open'), (50, 'go')]);
  });
}
