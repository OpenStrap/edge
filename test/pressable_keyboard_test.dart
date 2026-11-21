import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  testWidgets('Pressable activates on Enter and Space when focused', (t) async {
    var taps = 0;
    await t.pumpWidget(MaterialApp(
      home: Center(
        child: Pressable(onTap: () => taps++, child: const Text('go')),
      ),
    ));
    // Tab moves focus onto the control.
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, 2);
  });
}
