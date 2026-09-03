// M6 -- `_slotSays` readout, widget-level (spec-m6.md §13.2 tests 5, 6).
//
// `_slotSays` is private to metric_detail.dart, so these drive it through the
// real `MetricDetail(key, data: d)` widget (which skips the repo/AppState
// load path entirely, per its own `data` param) and read the scrubber's
// Semantics `value` — the same string `describe:` produces, per §6.4.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart' show DeviceOption;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<SemanticsHandle> _pump(
  WidgetTester t,
  MetricData d, {
  String key = 'resting_hr',
}) async {
  t.view.physicalSize = const Size(390 * 3, 900 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final handle = t.ensureSemantics();
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: MetricDetail(key, data: d)),
  ));
  await t.pumpAndSettle();
  // The scrubber only exists on a multi-day trend, not on the single-value
  // "Today" screen — switch to the week view, same as the wear-strip tests.
  await t.tap(find.text('7 days'));
  await t.pumpAndSettle();
  // Place a finger on the scrubber (Semantics.value is 'Nothing selected'
  // until then) — the exact slot does not matter here since every test
  // fixture below gives every slot in the window the same value/attribution.
  await t.tapAt(t.getCenter(find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.slider == true,
  )));
  await t.pumpAndSettle();
  return handle;
}

String _scrubberValue(WidgetTester t) {
  final semantics = t.getSemantics(find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.slider == true,
    description: 'the trend scrubber',
  ));
  return semantics.value;
}

void main() {
  // Test 5: gate false (single device, no coverage at all) returns the exact
  // pre-change strings, character for character.
  testWidgets('_slotSays: gate false returns the unchanged strings', (t) async {
    final today = DateTime.now();
    final series = [
      for (var i = 6; i >= 0; i--)
        (
          t: today.subtract(Duration(days: i)).millisecondsSinceEpoch ~/ 1000,
          v: 58.0,
        ),
    ];
    final handle = await _pump(t, MetricData(daysAvailable: 10, series: series));
    final value = _scrubberValue(t);
    expect(value, contains('58 bpm'));
    expect(value, isNot(contains('·')));
    handle.dispose();
  });

  // Test 6: a two-contributor day never names one device alone.
  testWidgets('_slotSays: a two-contributor day names both, never one',
      (t) async {
    final today = DateTime.now();
    final days = [
      for (var i = 6; i >= 0; i--)
        today.subtract(Duration(days: i)).toIso8601String().substring(0, 10),
    ];
    final series = [
      for (var i = 6; i >= 0; i--)
        (
          t: today.subtract(Duration(days: i)).millisecondsSinceEpoch ~/ 1000,
          v: 58.0,
        ),
    ];
    const sources = <DeviceOption>[
      (deviceId: '', label: 'Band', selectable: true, reason: null),
      (deviceId: 'ring-A', label: 'Ring', selectable: true, reason: null),
    ];
    final d = MetricData(
      daysAvailable: 10,
      series: series,
      coverage: {for (final day in days) day: const ['', 'ring-A']},
      sources: sources,
    );
    final handle = await _pump(t, d);
    final value = _scrubberValue(t);
    expect(value, contains('Band + Ring'));
    expect(value, isNot(contains('Band, no value')));
    handle.dispose();
  });

  // A forgotten device leaves its id in `coverage_devices` with no `device`
  // row behind it. Naming the survivor alone credits one of two contributors.
  testWidgets('_slotSays: a coverage id with no name attributes nobody',
      (t) async {
    final today = DateTime.now();
    final days = [
      for (var i = 6; i >= 0; i--)
        today.subtract(Duration(days: i)).toIso8601String().substring(0, 10),
    ];
    final series = [
      for (var i = 6; i >= 0; i--)
        (
          t: today.subtract(Duration(days: i)).millisecondsSinceEpoch ~/ 1000,
          v: 58.0,
        ),
    ];
    const sources = <DeviceOption>[
      (deviceId: '', label: 'Band', selectable: true, reason: null),
      (deviceId: 'ring-A', label: 'Ring', selectable: true, reason: null),
    ];
    final d = MetricData(
      daysAvailable: 10,
      series: series,
      // 'ring-GONE' was forgotten: still in coverage, no source row.
      coverage: {for (final day in days) day: const ['', 'ring-GONE']},
      sources: sources,
    );
    final handle = await _pump(t, d);
    final value = _scrubberValue(t);
    expect(value, contains('58 bpm'));
    expect(value, isNot(contains('Band')));
    handle.dispose();
  });

  // Every day predates schema 50, so `coverage` is empty: absent is UNKNOWN.
  // Selecting a device must not dim the window, and must not caption it.
  testWidgets('selecting a device on a coverage-less window claims nothing',
      (t) async {
    final today = DateTime.now();
    final series = [
      for (var i = 6; i >= 0; i--)
        (
          t: today.subtract(Duration(days: i)).millisecondsSinceEpoch ~/ 1000,
          v: 58.0,
        ),
    ];
    const sources = <DeviceOption>[
      (deviceId: '', label: 'Band', selectable: true, reason: null),
      (deviceId: 'ring-A', label: 'Ring', selectable: true, reason: null),
    ];
    final d = MetricData(daysAvailable: 10, series: series, sources: sources);
    t.view.physicalSize = const Size(390 * 3, 1600 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: MetricDetail('resting_hr', data: d)),
    ));
    await t.pumpAndSettle();
    await t.tap(find.text('7 days'));
    await t.pumpAndSettle();
    await t.tap(find.text('Ring'));
    await t.pumpAndSettle();
    expect(find.textContaining('was involved'), findsNothing);
  });
}
