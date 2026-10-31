// While a reply is coming in, the coach menu's past chats can be neither
// opened nor deleted: the running send writes into the open chat, and either
// would put its reply in the wrong chat or save a deleted one back.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<(List<String>, List<String>)> _pump(WidgetTester t,
    {required bool locked}) async {
  final opened = <String>[], deleted = <String>[];
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: CoachChatList(
        sessions: [CoachSessionMeta('1', 'Sleep this week', 0, 'how did I')],
        locked: locked,
        onOpen: opened.add,
        onDelete: (id) async => deleted.add(id),
      ),
    ),
  ));
  await t.tap(find.text('Sleep this week'), warnIfMissed: false);
  final delete = find.bySemanticsLabel(RegExp('^Delete'));
  if (delete.evaluate().isNotEmpty) await t.tap(delete);
  await t.pumpAndSettle();
  return (opened, deleted);
}

void main() {
  testWidgets('past chats open and delete when no reply is coming in',
      (t) async {
    final (opened, deleted) = await _pump(t, locked: false);
    expect(find.bySemanticsLabel(RegExp('^Delete')), findsOneWidget);
    expect(opened, ['1']);
    expect(deleted, ['1']);
  });

  testWidgets('past chats neither open nor delete while a reply is coming in',
      (t) async {
    final (opened, deleted) = await _pump(t, locked: true);
    expect(opened, isEmpty);
    expect(deleted, isEmpty);
    expect(find.bySemanticsLabel(RegExp('^Delete')), findsNothing);
  });
}
