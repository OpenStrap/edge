import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart' show RenameBandDialog;

// showDialog completes at pop time, before the exit transition finishes. The
// rename sheet used to dispose its controller and error notifier right after
// that await, while the field was still rebuilding, which threw on every Save
// and Cancel. Pumping the full transition is what surfaces it.
Future<void> _open(WidgetTester t, void Function(String?) onResult) async {
  await t.pumpWidget(MaterialApp(
    home: Builder(
      builder: (c) => TextButton(
        onPressed: () async => onResult(await showDialog<String>(
          context: c,
          builder: (_) => const RenameBandDialog(current: 'Old'),
        )),
        child: const Text('open'),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('save returns the trimmed name and survives the pop transition',
      (t) async {
    String? result;
    await _open(t, (r) => result = r);
    await t.enterText(find.byType(TextField), '  Left wrist  ');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byType(RenameBandDialog), findsNothing);
    expect(result, 'Left wrist');
  });

  testWidgets('cancel returns null and survives the pop transition',
      (t) async {
    var result = 'unset' as String?;
    await _open(t, (r) => result = r);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byType(RenameBandDialog), findsNothing);
    expect(result, isNull);
  });

  testWidgets('an empty name is refused in the sheet', (t) async {
    await _open(t, (_) {});
    await t.enterText(find.byType(TextField), '   ');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.byType(RenameBandDialog), findsOneWidget);
    expect(find.text('Give it a name'), findsOneWidget);
  });
}
