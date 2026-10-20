// Design snapshots: every gallery case, in both themes, at 1.0× and 2.0× text,
// written out as PNGs so a design change can be LOOKED at without a phone.
//
// Nothing is compared and nothing fails on a pixel — this is a camera, not a
// golden test. It is off by default and kept out of CI:
//
//   SNAPSHOTS=1 flutter test test/design_snapshots_test.dart
//
// Output lands in build/design_snapshots/<label>/<theme>_<scale>x/<case>.png
// (build/ is gitignored). Two optional knobs:
//
//   SNAPSHOTS_LABEL=before   the folder name, so a "before" and an "after" set
//                            can sit side by side. Default `latest`.
//   SNAPSHOTS_ONLY=ring|pill a regex over case names, to re-shoot a few cases
//                            instead of all of them.
//   SNAPSHOTS_LOCALE=ru      render in that language through the app's own
//                            delegates (default: the English fallbacks).
//   SNAPSHOTS_ROOTS=0        skip the whole screens (test/support/
//                            root_fixtures.dart), photographed after the
//                            gallery under root_<name>.png.
//   SNAPSHOTS_README=1       also rewrite the README's screenshots/*.png from
//                            the same fixtures (the only output outside build/).
//
// Any error a case throws while pumping (an overflow, an assertion) is written
// to errors.txt next to the PNGs rather than failing the run: the overflow
// gate is ui2_component_sweep_test.dart, and a camera that stops at the first
// broken case photographs nothing after it.
@Tags(['snapshots'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/gallery.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/root_fixtures.dart';

final _env = Platform.environment;
final _label = _env['SNAPSHOTS_LABEL'] ?? 'latest';
final _only = _env['SNAPSHOTS_ONLY'];
final _locale = switch (_env['SNAPSHOTS_LOCALE']) {
  null || '' => null,
  final code => Locale(code),
};
final _roots = _env['SNAPSHOTS_ROOTS'] != '0';

/// A phone: 390 × 844 logical, the width every layout decision is made at.
/// Rendered at 2× so the PNGs stay readable without being enormous.
const _phone = Size(390, 844);
const _ratio = 2.0;

/// A whole screen is photographed on a phone this tall, so one PNG holds the
/// entire scroll rather than its first 844 pt.
const _tall = Size(390, 2200);

final _shot = GlobalKey();

Widget _frame(Widget child, Brightness b, double scale) => MediaQuery(
      data: MediaQueryData(size: _phone, textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b),
        locale: _locale,
        localizationsDelegates:
            _locale == null ? null : AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) => Scaffold(
            backgroundColor: P.of(c).bg,
            // Scrolls, like every real screen, so a case taller than the
            // phone is photographed whole rather than clipped at 844.
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: _shot,
                child: ColoredBox(
                  color: P.of(c).bg,
                  child: Padding(
                    // Extra room below so a light-theme shadow (0 / 8 / 24)
                    // is photographed whole instead of cut into a slab.
                    padding:
                        const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x10),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

/// Every font the app bundles, its packages' icon fonts included, read from
/// the same FontManifest.json the app ships — without this every glyph is a
/// test-harness block and every icon is a tofu box.
Future<void> _loadFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json'))
      as List<dynamic>;
  Future<ByteData> load(String asset) => rootBundle.load(asset);
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final family = entry['family'] as String;
    final assets = [
      for (final f in (entry['fonts'] as List).cast<Map<String, dynamic>>())
        f['asset'] as String,
    ];
    final names = [
      family,
      // `.SF Pro Text` exists only on Apple hardware; everywhere else the
      // type IS the Manrope fallback, so it is registered under both names —
      // the same choice ui2_component_sweep_test makes.
      if (family == 'Manrope') '.SF Pro Text',
    ];
    for (final name in names) {
      final loader = FontLoader(name);
      for (final a in assets) {
        loader.addFont(load(a));
      }
      await loader.load();
    }
  }
}

/// The shell is not a gallery component (it is a route-level Scaffold), so it
/// is photographed here: four tabs of cards scrolling UNDER the floating bar,
/// with and without the minimised-workout banner.
Widget _shell(Brightness b, double scale, {bool banner = false}) => MediaQuery(
      data: MediaQueryData(
          size: _phone,
          textScaler: TextScaler.linear(scale),
          padding: const EdgeInsets.only(top: 47, bottom: 34)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b),
        home: AppShell(
          banner: banner
              ? Builder(
                  builder: (c) => Padding(
                    padding: const EdgeInsets.all(S.x3),
                    child: Text('Strength · Session running',
                        style: F.body.copyWith(color: P.of(c).ink)),
                  ),
                )
              : null,
          builder: (c, d) => ListView(
            padding:
                EdgeInsets.fromLTRB(S.gutter, S.x4, S.gutter, S.navClear(c)),
            children: [
              ScreenTitle(d.label),
              for (var i = 0; i < 8; i++) ...[
                const SizedBox(height: S.x3),
                Surface(child: Numeral('${52 + i}', unit: 'bpm')),
              ],
            ],
          ),
        ),
      ),
    );

/// A whole screen, under a phone's safe areas, the way a tab root sits in the
/// shell (without the bar, which the shell shot covers).
Widget _root(Widget child, Brightness b, double scale) => MediaQuery(
      data: MediaQueryData(
          size: _tall,
          textScaler: TextScaler.linear(scale),
          padding: const EdgeInsets.only(top: 47, bottom: 34)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(b),
        locale: _locale,
        localizationsDelegates:
            _locale == null ? null : AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) => RepaintBoundary(
            key: _shot,
            child: child is Scaffold
                ? child
                : Scaffold(
                    backgroundColor: P.of(c).bg,
                    body: SafeArea(bottom: false, child: child),
                  ),
          ),
        ),
      ),
    );

/// The README's five screenshots (screenshots/*.png), from the same fixtures:
/// a tab root inside the real shell, or a pushed screen on its own, on a
/// 390 × 844 phone in Char, written at the 600 px width the README has always
/// used. Fixture data, not a device capture — `SNAPSHOTS_README=1` to write.
const _readmeShots = {
  'today': ShellDomain.today,
  'health': ShellDomain.health,
  'sleep': ShellDomain.sleep,
  'heart-rate': null,
  'workout': ShellDomain.activity,
};
const _readmeFixture = {
  'today': 'today',
  'health': 'health',
  'sleep': 'sleep',
  'heart-rate': 'metric_resting_hr',
  'workout': 'activity',
};

Widget _readme(String name) {
  final root = rootCases[_readmeFixture[name]!]!();
  final domain = _readmeShots[name];
  return MediaQuery(
    data: const MediaQueryData(
        size: _phone, padding: EdgeInsets.only(top: 47, bottom: 34)),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: RepaintBoundary(
        key: _shot,
        child: domain == null
            ? Builder(
                builder: (c) => Scaffold(
                    backgroundColor: P.of(c).bg,
                    body: SafeArea(bottom: false, child: root)))
            : AppShell(initial: domain, builder: (_, _) => root),
      ),
    ),
  );
}

String _slug(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

/// Pump [w], collecting anything it throws as one line per error rather than
/// failing the run.
Future<List<String>> _pumpCollecting(
    WidgetTester tester, String name, Widget w, {int frames = 2}) async {
  final caught = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) => caught.add(d.exceptionAsString());
  try {
    await tester.pumpWidget(w);
    // Fixed frames, never pumpAndSettle: a spinner on a loading path would
    // never settle.
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  } finally {
    FlutterError.onError = previous;
  }
  return [for (final m in caught) '$name: ${m.split('\n').first}'];
}

Future<void> _write(WidgetTester tester, File out) async {
  final boundary =
      _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _ratio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes!.buffer.asUint8List();
  });
  out.writeAsBytesSync(png!);
}

void main() {
  final skip = _env['SNAPSHOTS'] != '1'
      ? 'set SNAPSHOTS=1 to write design snapshots'
      : null;
  final filter = _only == null ? null : RegExp(_only!);
  final cases = {
    for (final e in galleryCases().entries)
      if (filter == null || filter.hasMatch(e.key)) e.key: e.value,
  };

  setUpAll(() async {
    // Screens read prefs (the workout tab's import toggle, …); a test has no
    // plugin behind them.
    SharedPreferences.setMockInitialValues({});
    if (skip == null) await _loadFonts();
  });

  testWidgets('the README screenshots',
      skip: skip != null || _env['SNAPSHOTS_README'] != '1', (tester) async {
    // 600 px wide, as the README's images have always been.
    const ratio = 600 / 390;
    tester.view.physicalSize = _phone * ratio;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    final errors = <String>[];
    for (final name in _readmeShots.keys) {
      errors.addAll(
          await _pumpCollecting(tester, name, _readme(name), frames: 6));
      // Let bundled images decode (the start card's art) before the shot.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pump();
      final boundary =
          _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: ratio);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return bytes!.buffer.asUint8List();
      });
      File('screenshots/$name.png').writeAsBytesSync(png!);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    debugDisableShadows = true;
    expect(errors, isEmpty, reason: errors.join('\n'));
  });

  for (final b in Brightness.values) {
    for (final scale in const [1.0, 2.0]) {
      final variant = '${b.name}_${scale}x';
      testWidgets('snapshot every gallery case · $variant', skip: skip != null,
          (tester) async {
        tester.view.physicalSize = _phone * _ratio;
        tester.view.devicePixelRatio = _ratio;
        addTearDown(tester.view.reset);
        // flutter_test draws every BoxShadow as a solid, unblurred slab
        // unless this is off; the camera wants the real 0 / 8 / 24 shadow.
        debugDisableShadows = false;

        final dir = Directory('build/design_snapshots/$_label/$variant')
          ..createSync(recursive: true);
        final errors = <String>[];
        for (final e in cases.entries) {
          final caught = <String>[];
          final previous = FlutterError.onError;
          FlutterError.onError = (d) => caught.add(d.exceptionAsString());
          try {
            await tester.pumpWidget(_frame(e.value, b, scale));
            await tester.pump();
          } finally {
            FlutterError.onError = previous;
          }
          errors.addAll(caught.map((m) => '${e.key}: ${m.split('\n').first}'));

          final boundary = _shot.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final png = await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: _ratio);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            return bytes!.buffer.asUint8List();
          });
          File('${dir.path}/${_slug(e.key)}.png').writeAsBytesSync(png!);
        }
        for (final withBanner in [false, true]) {
          final caught = <String>[];
          final previous = FlutterError.onError;
          FlutterError.onError = (d) => caught.add(d.exceptionAsString());
          try {
            await tester.pumpWidget(_shell(b, scale, banner: withBanner));
            await tester.pump();
          } finally {
            FlutterError.onError = previous;
          }
          errors.addAll(caught.map((m) => 'shell: ${m.split('\n').first}'));
          // The whole screen: the shell is a Scaffold, not a component.
          final png = await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byType(RepaintBoundary).first);
            final img = await boundary.toImage(pixelRatio: _ratio);
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            img.dispose();
            return bytes!.buffer.asUint8List();
          });
          File('${dir.path}/shell${withBanner ? '_banner' : ''}.png')
              .writeAsBytesSync(png!);
        }
        File('${dir.path}/errors.txt').writeAsStringSync(errors.join('\n'));
        // Unmount before the next variant so a case's timers die with it.
        await tester.pumpWidget(const SizedBox.shrink());
        // Restored inside the body: the binding checks it before teardowns.
        debugDisableShadows = true;
      });

      testWidgets('snapshot every tab root · $variant',
          skip: skip != null || !_roots, (tester) async {
        tester.view.physicalSize = _tall * _ratio;
        tester.view.devicePixelRatio = _ratio;
        addTearDown(tester.view.reset);
        debugDisableShadows = false;

        final dir = Directory('build/design_snapshots/$_label/$variant')
          ..createSync(recursive: true);
        final errors = <String>[];
        for (final e in rootCases.entries) {
          if (filter != null && !filter.hasMatch('root_${e.key}')) continue;
          errors.addAll(await _pumpCollecting(
              tester, e.key, _root(e.value(), b, scale),
              frames: 6));
          await _write(tester, File('${dir.path}/root_${_slug(e.key)}.png'));
          await tester.pumpWidget(const SizedBox.shrink());
        }
        File('${dir.path}/errors_roots.txt')
            .writeAsStringSync(errors.join('\n'));
        debugDisableShadows = true;
      });
    }
  }
}
