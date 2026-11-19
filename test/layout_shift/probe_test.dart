// The probe must see a real widget tree the way the scorer expects.
// Test surface: 800 x 600 logical. Times are explicit pump durations.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import '../support/layout_shift_probe.dart';

const _viewport = ShiftRect(0, 0, 800, 600);

/// Placeholder (or content) above a keyed paragraph.
class _Feed extends StatelessWidget {
  final bool loaded;
  final double placeholder;
  const _Feed({required this.loaded, required this.placeholder});

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (loaded)
                  const SizedBox(key: ValueKey('hero'), width: 200, height: 100)
                else
                  SizedBox(height: placeholder),
                const Text('body', key: ValueKey('body')),
              ],
            ),
          ),
        ),
      );
}

ElementSnapshot _find(Frame f, String id) =>
    f.elements.singleWhere((e) => e.id == id);

Future<ShiftProbe> _loadFeed(WidgetTester t, double placeholder) async {
  final probe = ShiftProbe();
  await t.pumpWidget(_Feed(loaded: false, placeholder: placeholder));
  probe.capture(t, atMs: 0);
  await t.pumpWidget(_Feed(loaded: true, placeholder: placeholder));
  await t.pump(const Duration(milliseconds: 300));
  probe.capture(t, atMs: 300);
  return probe;
}

void main() {
  testWidgets('a too-short placeholder pushes the paragraph down 80', (t) async {
    final probe = await _loadFeed(t, 20);
    final before = _find(probe.frames[0], 'body').rect;
    final after = _find(probe.frames[1], 'body').rect;
    expect(after.top - before.top, closeTo(80, 1e-6)); // 100 - 20
    expect(score(probe.scenario(_viewport), ShiftPolicy.standard).total,
        greaterThan(0));
  });

  testWidgets('a correctly sized placeholder shifts nothing: score 0', (t) async {
    final probe = await _loadFeed(t, 100);
    final r = score(probe.scenario(_viewport), ShiftPolicy.standard);
    expect(r.total, 0);
    expect(r.findings, isEmpty);
  });

  testWidgets('frames carry the atMs they were captured with', (t) async {
    final probe = await _loadFeed(t, 20);
    expect(probe.frames.map((f) => f.atMs), [0, 300]);
    expect(probe.scenario(_viewport).frames, hasLength(2));
  });

  testWidgets('only keyed elements are tracked', (t) async {
    final probe = ShiftProbe();
    await t.pumpWidget(const MaterialApp(
      home: Column(children: [
        Text('keyed', key: ValueKey('k')),
        Text('unkeyed'),
      ]),
    ));
    final f = probe.capture(t, atMs: 0);
    expect(f.elements.map((e) => e.id), ['k']);
  });

  testWidgets('geometry is global logical pixels', (t) async {
    final probe = ShiftProbe();
    await t.pumpWidget(const MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(left: 10, top: 20),
          child: SizedBox(key: ValueKey('box'), width: 30, height: 40),
        ),
      ),
    ));
    final r = _find(probe.capture(t, atMs: 0), 'box').rect;
    expect([r.left, r.top, r.width, r.height], [10, 20, 30, 40]);
  });

  testWidgets('Text is a paragraph', (t) async {
    final probe = ShiftProbe();
    await t.pumpWidget(const MaterialApp(
        home: Text('hello', key: ValueKey('t'))));
    expect(_find(probe.capture(t, atMs: 0), 't').role, ElementRole.paragraph);
  });

  testWidgets('a TextField is an input', (t) async {
    final probe = ShiftProbe();
    await t.pumpWidget(const MaterialApp(
        home: Material(child: TextField(key: ValueKey('in')))));
    expect(_find(probe.capture(t, atMs: 0), 'in').role, ElementRole.input);
  });

  testWidgets('a Focus that can take focus is a focusable control', (t) async {
    final probe = ShiftProbe();
    await t.pumpWidget(const MaterialApp(
        home: Focus(
            key: ValueKey('btn'),
            child: SizedBox(width: 40, height: 40))));
    final e = _find(probe.capture(t, atMs: 0), 'btn');
    expect(e.role, ElementRole.control);
    expect(e.focusable, isTrue);
    expect(e.focused, isFalse);
  });

  testWidgets('a focused Focus reports focused', (t) async {
    final probe = ShiftProbe();
    final node = FocusNode();
    addTearDown(node.dispose);
    await t.pumpWidget(MaterialApp(
        home: Focus(
            key: const ValueKey('btn'),
            focusNode: node,
            child: const SizedBox(width: 40, height: 40))));
    node.requestFocus();
    await t.pump();
    expect(_find(probe.capture(t, atMs: 0), 'btn').focused, isTrue);
  });

  testWidgets('colour comes from the nearest DecoratedBox/ColoredBox', (t) async {
    final probe = ShiftProbe();
    await t.pumpWidget(const MaterialApp(
        home: Column(children: [
      DecoratedBox(
          key: ValueKey('dec'),
          decoration: BoxDecoration(color: Color(0xFF336699)),
          child: SizedBox(width: 10, height: 10)),
      ColoredBox(
          key: ValueKey('col'),
          color: Color(0xFFAA5500),
          child: SizedBox(width: 10, height: 10)),
    ])));
    final f = probe.capture(t, atMs: 0);
    expect(_find(f, 'dec').colorArgb, 0xFF336699);
    expect(_find(f, 'col').colorArgb, 0xFFAA5500);
  });

  testWidgets('trackUnkeyed: ids are stable and a late inserted card shifts '
      'the Text below it', (t) async {
    Widget app(bool banner) => MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (banner) const SizedBox(height: 50),
              const Text('same'),
              const Text('same'),
              ElevatedButton(onPressed: () {}, child: const Text('Go')),
            ]),
          ),
        );
    final probe = ShiftProbe(trackUnkeyed: true);
    await t.pumpWidget(app(false));
    final a = probe.capture(t, atMs: 0);
    await t.pumpWidget(app(true));
    final b = probe.capture(t, atMs: 300);
    final ids = a.elements.map((e) => e.id).toList();
    expect(ids.toSet(), hasLength(ids.length), reason: 'ids are unique');
    expect(b.elements.map((e) => e.id).toList(), ids,
        reason: 'inserting a sibling above must not rename anything');
    expect(a.elements.where((e) => e.role == ElementRole.control), isNotEmpty);
    expect(ids.where((i) => i.startsWith('~text|')),
        hasLength(2));
    final r = score(probe.scenario(_viewport), ShiftPolicy.standard);
    expect(r.total, greaterThan(0));
    // Default mode still tracks keyed only.
    final keyedOnly = ShiftProbe();
    expect(keyedOnly.capture(t, atMs: 0).elements, isEmpty);
  });

  // ---- placeholder -> content is the same slot, not disappear + appear ----
  late ShiftProbe last;
  Future<ShiftReport> run(WidgetTester t, Widget a, Widget b) async {
    final probe = last = ShiftProbe(trackUnkeyed: true);
    await t.pumpWidget(MaterialApp(
        home: Align(alignment: Alignment.topLeft, child: a)));
    probe.capture(t, atMs: 0);
    await t.pumpWidget(MaterialApp(
        home: Align(alignment: Alignment.topLeft, child: b)));
    probe.capture(t, atMs: 300);
    return score(probe.scenario(_viewport), ShiftPolicy.standard);
  }

  testWidgets('slot: loading box 40 -> chart card 200 is one resize',
      (t) async {
    Widget slot(Widget c) => Column(
        key: const ValueKey('slot'),
        mainAxisSize: MainAxisSize.min,
        children: [c]);
    final r = await run(
        t,
        slot(const SizedBox(
            height: 40, width: 200, child: CircularProgressIndicator())),
        slot(const Card(child: SizedBox(height: 200, width: 200))));
    expect(r.total, greaterThan(0));
    expect(r.findings.where((f) => f.rule == 'shift' && f.elementId == 'slot'),
        isNotEmpty);
  });

  testWidgets('unkeyed: loading indicator -> card in the same slot resizes',
      (t) async {
    final r = await run(
        t,
        Column(mainAxisSize: MainAxisSize.min, children: const [
          Text('title'),
          SizedBox(
              height: 40, width: 200, child: CircularProgressIndicator()),
        ]),
        Column(mainAxisSize: MainAxisSize.min, children: const [
          Text('title'),
          Card(child: SizedBox(height: 200, width: 200)),
        ]));
    expect(r.total, greaterThan(0));
    expect(r.findings.where((f) => f.rule == 'shift' && f.elementId.startsWith('~card|')),
        isNotEmpty, reason: 'the slot itself is scored');
  });

  testWidgets('"—" -> "72" same size is not a shift and not an appearance',
      (t) async {
    final r = await run(
        t,
        const Column(mainAxisSize: MainAxisSize.min, children: [
          Text('\u2014', style: TextStyle(fontSize: 20)),
          Text('after'),
        ]),
        const Column(mainAxisSize: MainAxisSize.min, children: [
          Text('72', style: TextStyle(fontSize: 20)),
          Text('after'),
        ]));
    List<String> ids(int i) => last.frames[i].elements.map((e) => e.id).toList();
    expect(ids(1), ids(0), reason: 'same slot, same id');
    expect(r.total, 0);
    expect(r.findings, isEmpty);
  });

  testWidgets('"—" -> taller text is a resize finding on that text', (t) async {
    final r = await run(
        t,
        const Column(mainAxisSize: MainAxisSize.min, children: [
          Text('above'),
          Text('\u2014', style: TextStyle(fontSize: 14)),
        ]),
        const Column(mainAxisSize: MainAxisSize.min, children: [
          Text('above'),
          Text('72 bpm resting', style: TextStyle(fontSize: 40)),
        ]));
    expect(r.total, greaterThan(0));
    expect(r.findings.where((f) => f.rule == 'shift'), isNotEmpty);
    expect(r.findings.every((f) => f.elementId.startsWith('~text|')), isTrue);
    List<String> ids(int i) => last.frames[i].elements.map((e) => e.id).toList();
    expect(ids(1), ids(0), reason: 'same slot, same id');
  });

  testWidgets('regression: a widget appearing in a new position pushes the '
      'sibling below it', (t) async {
    final r = await run(
        t,
        const Column(mainAxisSize: MainAxisSize.min, children: [
          Text('stay'),
        ]),
        const Column(mainAxisSize: MainAxisSize.min, children: [
          Card(child: SizedBox(height: 120, width: 200)),
          Text('stay'),
        ]));
    expect(r.total, greaterThan(0));
    expect(r.findings.where((f) => f.elementId.startsWith('~text|')), isNotEmpty);
  });

  // Moment review: rows growing inside the list "covered" the pinned Save bar
  // below it, though the list viewport clips them.
  testWidgets('rects are clipped by the scroll viewport: a row growing under '
      'a pinned bar does not cover it', (t) async {
    Widget page(double rowH) => SizedBox(
        width: 300,
        height: 400,
        child: Column(children: [
          SizedBox(
              height: 300,
              child: ListView(children: [
                SizedBox(key: const ValueKey('row'), height: rowH, width: 300),
              ])),
          const SizedBox(
              key: ValueKey('save'),
              height: 100,
              width: 300,
              child: Focus(child: SizedBox.expand())),
        ]));
    final r = await run(t, page(100), page(500));
    expect(r.findings.where((f) => f.rule == 'cover'), isEmpty);
    final row = last.frames[1].elements.firstWhere((e) => e.id == 'row');
    expect(row.rect.height, 300, reason: 'clipped to the 300 px viewport');
  });

  // Route push: the covered page slides while the new one comes in. That is
  // the transition, not a shift of the page's controls.
  testWidgets('skipCoveredRoutes drops the page under a pushed route',
      (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: Text('below', key: ValueKey('below'))))));
    final on = ShiftProbe(skipCoveredRoutes: true);
    final off = ShiftProbe();
    on.capture(t, atMs: 0);
    off.capture(t, atMs: 0);
    nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
            body: Text('above', key: ValueKey('above')))));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    on.capture(t, atMs: 100);
    off.capture(t, atMs: 100);
    expect(on.frames[1].elements.map((e) => e.id), isNot(contains('below')));
    expect(on.frames[1].elements.map((e) => e.id), contains('above'));
    expect(off.frames[1].elements.map((e) => e.id), contains('below'));
  });
}
