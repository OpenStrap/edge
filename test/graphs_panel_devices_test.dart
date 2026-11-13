// The per-day contributor line in the metric-detail ChartPanel (Sol r2 S8).
// Upstream's pop-in named the devices behind the touched day ("Band + Ring");
// the replacement panel must keep that line, reserve its height on a
// multi-device window, and never speak it twice.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart' show DeviceOption;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _noteKey = ValueKey('chart-panel-note');
const _panelKey = ValueKey('chart-panel');
const _bare = 3; // days ago with no attribution in the two-device window

const _sources = <DeviceOption>[
  (deviceId: '', label: 'Band', selectable: true, reason: null),
  (deviceId: 'ring-A', label: 'Ring', selectable: true, reason: null),
];

String _day(int back) {
  final n = DateTime.now();
  final d = DateTime(n.year, n.month, n.day - back);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

MetricData _data({required bool multi, int? gap}) {
  final n = DateTime.now();
  return MetricData(
    daysAvailable: 10,
    series: [
      for (var back = 9; back >= 0; back--)
        if (back != gap)
        (
          t: DateTime(n.year, n.month, n.day - back, 12)
                  .millisecondsSinceEpoch ~/
              1000,
          v: 50.0 + back,
        ),
    ],
    sources: multi ? _sources : const [],
    coverage: multi
        ? {
            for (var b = 0; b < 10; b++)
              if (b != _bare) _day(b): const ['', 'ring-A'],
            // Today is fed by the ring alone: one name, not two.
            _day(0): const ['ring-A'],
          }
        : const {},
  );
}

Future<void> _open(WidgetTester t, {required bool multi, int? gap}) async {
  t.view.physicalSize = const Size(390 * 3, 1800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: MetricDetail('resting_hr', data: _data(multi: multi, gap: gap))),
  ));
  await t.pumpAndSettle();
  await t.tap(find.text('7 days'));
  await t.pumpAndSettle();
}

Future<void> _scrubBack(WidgetTester t, int back) async {
  final plot = find.descendant(
      of: find.byType(ChartFrame).first, matching: find.byType(Scrubber));
  final r = t.getRect(plot);
  await t.tapAt(Offset(r.left + r.width * (6 - back) / 6, r.center.dy));
  await t.pumpAndSettle();
}

String? _note(WidgetTester t) {
  final f = find.byKey(_noteKey);
  if (f.evaluate().isEmpty) return null;
  return t.widget<Text>(f).data!.trim();
}

int _times(WidgetTester t, String what) {
  var n = 0;
  void walk(SemanticsNode x) {
    final d = x.getSemanticsData();
    for (final s in [d.label, d.value]) {
      if (s.contains(what)) n++;
    }
    x.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(t.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return n;
}

void main() {
  testWidgets('two devices: the scrubbed day shows "Band + Ring"', (t) async {
    await _open(t, multi: true);
    await _scrubBack(t, 1);
    expect(_note(t), 'Band + Ring');
  });

  testWidgets('at rest the latest day shows its contributors', (t) async {
    await _open(t, multi: true);
    expect(_note(t), 'Ring', reason: 'today is fed by one device only');
  });

  testWidgets('a day with no attribution shows no text and the panel does not '
      'change size', (t) async {
    await _open(t, multi: true);
    await _scrubBack(t, 1);
    final withNote = t.getRect(find.byKey(_panelKey));
    await _scrubBack(t, _bare);
    expect(_note(t), '');
    expect(t.getRect(find.byKey(_panelKey)), withNote);
  });

  testWidgets('a day with coverage but no value shows no device line, as the '
      'slider says', (t) async {
    await _open(t, multi: true, gap: 2);
    await _scrubBack(t, 2);
    expect(_note(t), '', reason: 'the slider names no device for a no-value day');
    expect(find.text('Band + Ring'), findsNothing);
  });

  testWidgets('single device: no line and no reserved space', (t) async {
    await _open(t, multi: false);
    expect(find.byKey(_noteKey), findsNothing);
    final rest = t.getRect(find.byKey(_panelKey)).height;
    await _scrubBack(t, 1);
    expect(find.byKey(_noteKey), findsNothing);
    expect(t.getRect(find.byKey(_panelKey)).height, rest);

    await t.pumpWidget(const SizedBox());
    await _open(t, multi: true);
    expect(t.getRect(find.byKey(_panelKey)).height, greaterThan(rest),
        reason: 'the multi-device window reserves the line');
  });

  testWidgets('the contributors are spoken exactly once', (t) async {
    final h = t.ensureSemantics();
    await _open(t, multi: true);
    expect(_times(t, '· Ring'), 1,
        reason: 'at rest: the resting reading (the device pill is not a note)');
    await _scrubBack(t, 1);
    expect(_times(t, 'Band + Ring'), 1, reason: 'scrubbed: the slider');
    h.dispose();
  });
}
