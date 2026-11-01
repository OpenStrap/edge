import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart' show confirmChatGptTerms;

// ChatGPT sign-in only starts after the user has been pointed at OpenAI's
// terms and usage policies and chosen to continue.
void main() {
  Future<List<bool>> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final results = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () async => results.add(await confirmChatGptTerms(c)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('the notice names both OpenAI documents before sign-in',
      (tester) async {
    await open(tester);
    expect(find.text('Before you sign in'), findsOneWidget);
    expect(find.textContaining('your own ChatGPT account'), findsOneWidget);
    expect(find.text('OpenAI Terms of Use'), findsOneWidget);
    expect(find.text('OpenAI Usage Policies'), findsOneWidget);
  });

  testWidgets('cancel does not start sign-in', (tester) async {
    final results = await open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [false]);
  });

  testWidgets('dismissing the sheet does not start sign-in', (tester) async {
    final results = await open(tester);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(results, [false]);
  });

  testWidgets('continue starts sign-in', (tester) async {
    final results = await open(tester);
    await tester.tap(find.text('I’ve read them, continue'));
    await tester.pumpAndSettle();
    expect(results, [true]);
  });
}
