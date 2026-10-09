import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/gallery.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fonts = Directory(
      'assets/fonts/Manrope',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'));
    for (final family in ['Manrope', '.SF Pro Text']) {
      final loader = FontLoader(family);
      for (final file in fonts) {
        loader.addFont(
          file.readAsBytes().then(
            (bytes) => ByteData.sublistView(Uint8List.fromList(bytes)),
          ),
        );
      }
      await loader.load();
    }
  });

  for (final (width, scale) in [(320.0, 1.0), (320.0, 2.0), (390.0, 3.1)]) {
    testWidgets('Russian gallery fits $width dp at ${scale}x text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width * 3, 4000 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final failures = <String>[];
      for (final entry in galleryCases().entries) {
        final errors = <String>[];
        final previous = FlutterError.onError;
        try {
          FlutterError.onError = (details) =>
              errors.add(details.exceptionAsString());
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('ru'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: buildTheme(Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(S.x4),
                    child: entry.value,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
        } finally {
          FlutterError.onError = previous;
        }
        failures.addAll(errors.map((error) => '${entry.key}: $error'));
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  }
}
