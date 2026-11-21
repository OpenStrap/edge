import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/layout_shift/layout_shift.dart';
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
  // why: a pre-tap baseline belongs to the action it was already displaying.
  // catches: a second tap taking ownership of earlier movement at the same ms.
  testWidgets('a second tap cannot erase a shift captured before it', (t) async {
    phoneSurface(t);
    late StateSetter update;
    var top = 0.0;
    await t.pumpWidget(MaterialApp(home: StatefulBuilder(builder: (context, set) {
      update = set;
      return Stack(children: [
        Positioned(left: 0, top: top, width: 390, height: 844,
            child: const SizedBox(key: ValueKey('panel'))),
        Positioned(bottom: 0, child: TextButton(key: const ValueKey('go'),
            onPressed: () {}, child: const Text('Go'))),
      ]);
    })));
    final run = ShiftRun(t, trackUnkeyed: false);
    run.opened();
    await run.frames([500]);
    update(() => top = 30);
    await t.pump();
    await run.tap(find.byKey(const ValueKey('go')), [0, 100]);
    final shifts = run.score().findings.where((f) => f.rule == 'shift' && f.elementId == 'panel');
    expect(shifts, hasLength(1));
    // Full viewport impact * 30px / 844px; the second tap must not make it 0.
    expect(shifts.single.score, closeTo(30 / 844, 1e-9));
    final loads = run.score().findings.where((f) => f.rule == 'load');
    expect(loads.single.elementId, 'screen-open');
    expect(loads.single.score, .25);
  });

  // WHY: upstream screens use indeterminate indicators while data loads.
  // Catches: applying a no-spinner policy to every measurement.
  testWidgets('driver captures an indeterminate indicator by default', (t) async {
    await t.pumpWidget(const MaterialApp(home: Center(child: SizedBox(
      width: 40, height: 40, child: CircularProgressIndicator()))));
    final run = ShiftRun(t);
    run.opened();
    expect(run.probe.frames, hasLength(1));
    expect(run.probe.frames.single.elements
      .where((e) => e.id.startsWith('~card|')).single.role, ElementRole.other);
    expect(run.probe.interactions.single.sourceId, 'screen-open');
  });

  // WHY: strict scenarios must still be able to forbid perpetual loading paint.
  // Catches: ignoring rejectIndeterminateProgress after making it opt-in.
  testWidgets('driver rejects an indeterminate indicator when opted in', (t) async {
    await t.pumpWidget(const MaterialApp(home: Center(child: SizedBox(
      width: 40, height: 40, child: CircularProgressIndicator()))));
    final run = ShiftRun(t, rejectIndeterminateProgress: true);
    expect(run.snap, throwsA(isA<TestFailure>()));
    expect(run.probe.frames, isEmpty);
  });

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
    expect(run.probe.interactions.map((i) => i.afterFrameIndex), [0, 4]);
    expect(run.probe.interactions.map((i) => (i.atMs, i.sourceId)),
      [(0, 'screen-open'), (50, 'go')]);
  });
}
