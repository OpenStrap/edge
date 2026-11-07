// SlotScrub dates its slots from the calendar day its caller built the series
// for, not from the clock at each touch. A chart left open across midnight
// must keep labelling its data with the days the data is from.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/slot_scrub.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/scrub_surface_laws.dart';

Widget _chart(DateTime anchor) => scaledApp(
      1,
      Scaffold(
        body: SlotScrub(
          series: const [10, 20, 30],
          anchor: anchor,
          bars: true,
          label: 'Load',
          color: Colors.purple,
          format: (v) => '${v.round()} points',
          builder: (c, pick, scrub, panel) => Column(children: [
            SizedBox(
                height: 80,
                child: scrub(const SizedBox.expand(key: ValueKey('plot')))),
            panel,
          ]),
        ),
      ),
    );

String _caption(WidgetTester t) =>
    plainOf(t.widget<Text>(find.byKey(captionKey)));

void main() {
  testWidgets('an anchor of yesterday labels the last slot as yesterday, at '
      'rest and when touched', (t) async {
    final n = DateTime.now();
    final yesterday = DateTime(n.year, n.month, n.day - 1);
    await t.pumpWidget(_chart(yesterday));
    await t.pumpAndSettle();
    expect(_caption(t), startsWith('LATEST · '));
    expect(_caption(t), isNot(contains('Today')),
        reason: 'the clock says today; the series says yesterday');
    expect(namesDay(_caption(t), 1), isTrue, reason: _caption(t));

    final box = t.getRect(find.byType(Scrubber));
    // The last of three bars, then the first.
    await t.tapAt(Offset(box.left + box.width * 5 / 6, box.center.dy));
    await t.pumpAndSettle();
    expect(_caption(t), startsWith('SELECTED · '));
    expect(namesDay(_caption(t), 1), isTrue, reason: _caption(t));
    await t.tapAt(Offset(box.left + box.width * 1 / 6, box.center.dy));
    await t.pumpAndSettle();
    expect(namesDay(_caption(t), 3), isTrue,
        reason: 'the first slot is two days before the anchor: "${_caption(t)}"');
  });

  testWidgets('an anchor of today still labels the last slot Today',
      (t) async {
    final n = DateTime.now();
    await t.pumpWidget(_chart(DateTime(n.year, n.month, n.day)));
    await t.pumpAndSettle();
    expect(_caption(t), 'LATEST · Today');
  });
}
