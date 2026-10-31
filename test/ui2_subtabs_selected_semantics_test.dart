// SubTabs drives the 7/30/90-day range on every metric detail and the
// sections of the Health, Wellness, Workouts and Devices screens. The active
// pill is told apart only by fill and font weight, so a screen reader has to
// be given the selected state explicitly or it reads every pill the same.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _harness(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  const items = ['7 days', '30 days', '90 days'];

  testWidgets('only the active pill is announced as selected', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(_harness(SubTabs(items, 1, (_) {})));
    await t.pumpAndSettle();

    expect(
      t.getSemantics(find.text('30 days')),
      isSemantics(isSelected: true, isButton: true),
    );
    for (final other in const ['7 days', '90 days']) {
      expect(
        t.getSemantics(find.text(other)),
        isSemantics(isSelected: false, isButton: true),
      );
    }
    handle.dispose();
  });

  testWidgets('selection follows the index', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(_harness(SubTabs(items, 0, (_) {})));
    await t.pumpAndSettle();
    expect(t.getSemantics(find.text('7 days')),
        isSemantics(isSelected: true));

    await t.pumpWidget(_harness(SubTabs(items, 2, (_) {})));
    await t.pumpAndSettle();
    expect(t.getSemantics(find.text('7 days')),
        isSemantics(isSelected: false));
    expect(t.getSemantics(find.text('90 days')),
        isSemantics(isSelected: true));
    handle.dispose();
  });

  testWidgets('a disabled pill is never announced as selected', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(
        _harness(SubTabs(items, 1, (_) {}, disabled: const {1})));
    await t.pumpAndSettle();
    expect(
      t.getSemantics(find.text('30 days')),
      isSemantics(isSelected: false),
    );
    handle.dispose();
  });
}
