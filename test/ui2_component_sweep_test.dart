// Layout sweeps for the grammar: every gallery component, at every text
// scale a phone can reach, must not overflow and must keep 44 pt tap targets.
//
// iOS reaches 3.1x with Larger Accessibility Sizes and Android about 2.6x
// effective; accessibility text sizes are where cards overflow.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The cases are the GALLERY's cases. One list, so a component added to the
// gallery is swept here too.
import 'package:openstrap_edge/ui2/profile/gallery.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// The component, not the page: the boundary the sweeps measure.
final _shot = GlobalKey();

Widget _frame(Widget child, Brightness b, double scale) => MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b),
        home: Builder(
          builder: (c) => Scaffold(
            backgroundColor: P.of(c).bg,
            // Top-aligned, not centred: a component that grows past the
            // viewport at 2x text should be tall, not clipped in the middle.
            // A scroll view, because that is what every real screen is: it
            // hands the component an unbounded height, so a card shrink-wraps
            // its content here exactly as it does in the app.
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(S.x4),
                child: RepaintBoundary(key: _shot, child: child),
              ),
            ),
          ),
        ),
      ),
    );

/// Load the bundled type so text measures as it does on a phone, not as the
/// test harness's block glyphs.
Future<void> _loadType() async {
  final files = Directory('assets/fonts/Manrope')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ttf'));
  // Registered under both names. `.SF Pro Text` does not exist off Apple
  // hardware, so on Android and in the test harness the type IS Manrope —
  // registering it under the primary name makes text measure as a non-Apple
  // user sees it, rather than as the harness's fallback blocks.
  for (final family in const ['Manrope', '.SF Pro Text']) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(f
          .readAsBytes()
          .then((b) => ByteData.sublistView(Uint8List.fromList(b))));
    }
    await loader.load();
  }
}


void main() {
  // Swept for overflow and tap size below: everything, painters included.
  final all = galleryCases();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadType();
  });

  testWidgets('the shell has five destinations and cannot grow a sixth',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: AppShell(
        builder: (c, d) => Center(child: Text(d.label)),
      ),
    ));
    expect(ShellDomain.values, hasLength(5));
    for (final d in ShellDomain.values) {
      expect(find.text(d.label), findsWidgets, reason: '${d.label} tab missing');
    }
  });

  testWidgets('every tap target in the shell clears 44 pt', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: AppShell(builder: (c, d) => const SizedBox.shrink()),
    ));
    for (final e in tester.widgetList<Pressable>(find.byType(Pressable))) {
      if (e.onTap == null) continue;
      final size = tester.getSize(find.byWidget(e));
      expect(size.height, greaterThanOrEqualTo(S.tap),
          reason: '${e.semanticLabel} is ${size.height} pt tall');
      expect(size.width, greaterThanOrEqualTo(S.tap),
          reason: '${e.semanticLabel} is ${size.width} pt wide');
    }
  });

  // ── every text scale ──────────────────────────────────────────────────
  //
  // Both sweeps also cover 1.0x, because F-06 was a component clipped at 1.0x.
  group('every text scale', () {
    for (final scale in const [1.0, 1.4, 2.0, 3.0, 3.1]) {
      testWidgets('nothing overflows at ${scale}x', (tester) async {
        tester.view.physicalSize = const Size(390 * 3, 4000 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final broke = <String>[];
        for (final e in all.entries) {
          final errors = <String>[];
          final previous = FlutterError.onError;
          FlutterError.onError = (d) => errors.add(d.exceptionAsString());
          await tester.pumpWidget(_frame(e.value, Brightness.light, scale));
          await tester.pump();
          FlutterError.onError = previous;
          for (final err in errors) {
            if (err.contains('overflowed')) broke.add('${e.key}: $err');
          }
        }
        expect(broke, isEmpty,
            reason: 'a card that overflows at an accessibility text size is a '
                'measurement pushed off the screen:\n${broke.join('\n')}');
      });
    }

    testWidgets('every tap target in every case clears 44 pt', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 4000 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final small = <String>[];
      for (final e in all.entries) {
        await tester.pumpWidget(_frame(e.value, Brightness.light, 1.0));
        await tester.pump();
        for (final w in tester.widgetList<Pressable>(find.byType(Pressable))) {
          if (w.onTap == null) continue;
          final s = tester.getSize(find.byWidget(w));
          if (s.height < S.tap || s.width < S.tap) {
            small.add('${e.key} · ${w.semanticLabel ?? 'unlabelled'} '
                'is ${s.width} × ${s.height}');
          }
        }
      }
      expect(small, isEmpty,
          reason: 'the 44 pt guarantee only held for the five shell tabs, '
              'which is how seven sub-44 controls shipped:\n${small.join('\n')}');
    });
  });
}
