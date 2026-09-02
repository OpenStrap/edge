// "in wellness screen when we enter recovery tab everything becomes grey,
// except bottom navbar."
//
// That sentence is a precise description of ONE failure and no other, and it
// is worth writing down because reading the widget tree will never find it.
//
// `AppShell` puts the domain in `Scaffold.body` and the tab row in
// `Scaffold.bottomNavigationBar` — SIBLINGS. So anything that throws while the
// domain BUILDS is caught by the framework, that whole subtree is replaced by
// an `ErrorWidget`, and the bar beside it is untouched. `RenderErrorBox` paints
// `0xF0C0C0C0` — "red in debug mode, a light gray otherwise" — so on a release
// build a single exception inside `_recovery` is, pixel for pixel, a grey page
// under a normal nav bar. Nothing about it looks like a crash.
//
// The consequence for testing: a green `flutter test` proves nothing here,
// because the framework SWALLOWS the throw. `FlutterError.onError` has to be
// captured and asserted on, and the render tree has to be walked, or this
// exact bug reports as a pass.
//
// So this renders the real screen — the real `_load`, the real repository
// seam, the real ListView — walks to Recovery the way a thumb does, and then
// asserts three things, in the order they would fail:
//
//   1. nothing was reported to `FlutterError.onError` while the tab came up,
//   2. no `ErrorWidget` is in the tree and no `RenderErrorBox` is in the RENDER
//      tree — the substitution happens at paint, so the second is the one that
//      cannot be satisfied by a page that has stopped drawing,
//   3. the tab's first card is laid out with a real height.
//
// Light and dark, 1.0x and 2.0x text, at 390 pt — the narrow phone and the
// accessibility size are where this screen's cards have failed before.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _day = '2026-08-16';

/// A day with everything Recovery can show: a debt worth a recommendation, a
/// learned need, and four readiness inputs — one that helped, one that moved
/// inside its own spread, one that could not be used, and the raw skin-temp
/// ADC whose numbers are suppressed. Every field is the WIRE name; a fixture
/// built on `contribution` instead of `weighted_contribution` passes its own
/// fiction and reports every driver as "neither".
class _Repo extends LocalRepository {
  _Repo({this.insights, this.stress});

  /// Overrides the healthy fixture, for the hostile-leaf case.
  final Map<String, dynamic>? insights;
  final Map<String, dynamic>? stress;

  @override
  Future<Map<String, dynamic>> getToday() async => const {
        'status': {'today_day': _day}
      };

  @override
  Future<Map<String, dynamic>> getDayStress(String date) async =>
      stress ??
      const {
        'readiness': {'value': 62.0, 'confidence': 0.8, 'tier': 'HIGH'},
        'stress': {'score': 34},
      };

  @override
  Future<Map<String, dynamic>> getInsights() async =>
      insights ??
      const {
        'readiness_glassbox': {
          'value': {
            'breakdown': [
              {
                'label': 'hrv',
                'used': true,
                'weight': 0.40,
                'weighted_contribution': -6.2,
                'past_mdc': true,
              },
              {
                'label': 'rhr',
                'used': true,
                'weight': 0.30,
                'weighted_contribution': 3.1,
                'past_mdc': false,
              },
              {
                'label': 'resp',
                'used': false,
                'weight': 0.15,
                'note': 'need_baseline:have=2,need=7',
              },
              {
                'label': 'temp',
                'used': true,
                'weight': 0.15,
                'weighted_contribution': -1.4,
                'past_mdc': true,
              },
            ],
          },
        },
        'sleep_debt': {
          'value': {'debt_hours': 1.4}
        },
        'sleep_coach': {
          'need': {
            'value': {'need_sec': 28800.0}
          },
          'bedtime': {
            'value': {'bedtime_min_of_day': 1380}
          },
          'wake': {
            'value': {'wake_min_of_day': 420}
          },
          'nap_credit_min': 20,
          'strain_bonus_min': 15,
        },
      };

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async => const {
        'baselines': {
          'hrv': {
            'value': 42.0,
            'baseline': 51.0,
            'spread': 4.0,
            'delta': -9.0,
            'mdc_multiples': -1.6,
          },
          'resting_hr': {
            'value': 54.0,
            'baseline': 56.0,
            'spread': 2.0,
            'delta': -2.0,
            'mdc_multiples': -0.4,
          },
          'skin_temp': {
            'value': 32411.0,
            'baseline': 32380.0,
            'spread': 20.0,
            'delta': 31.0,
            'mdc_multiples': 1.1,
          },
        },
      };

  /// `{t, v}` and dated off NOW, which is what `pointsOf` and `denseDays`
  /// actually read. A `{day, value}` fixture parses to an EMPTY series, every
  /// driver comes back `chartable: false`, and the expandable half of this
  /// card silently stops being covered.
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    final midnight = DateTime.now().copyWith(
        hour: 12, minute: 0, second: 0, millisecond: 0, microsecond: 0);
    return {
      'points': [
        for (var back = 29; back >= 0; back--)
          {
            't': midnight
                    .subtract(Duration(days: back))
                    .millisecondsSinceEpoch ~/
                1000,
            'v': 40.0 + back % 7,
          }
      ]
    };
  }

  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(
          String date) async =>
      {};

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
}

/// `_load` goes to sqflite for medication, breathing and the habit history, and
/// sqflite answers on a REAL event loop. Pumping alone never lets those futures
/// complete, so the screen sits on its spinner and every assertion below passes
/// against an empty tab — which is how a test like this quietly stops testing
/// anything, which is why there is a spinner check after it.
///
/// So: real time to let the queries answer, a pump to commit the `setState`
/// they land in, and POLL rather than guess a duration — a fixed delay that is
/// long enough on this machine is a flake on a slower one. Returns whether the
/// spinner ever went away; the caller asserts on it, but only once it has put
/// `FlutterError.onError` back.
Future<bool> _settleLoad(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      await _frames(t);
      return true;
    }
  }
  return false;
}

/// Fake time only — enough for a `setState` and the chip's transition.
Future<void> _frames(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 32));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      final where = '${dark ? 'dark' : 'light'}, ${scale}x text';

      testWidgets('recovery paints its cards — $where', (t) async {
        await _openRecovery(t, dark: dark, scale: scale, repo: _Repo());

        expect(find.text('What charged and drained you'), findsOneWidget);
        expect(find.text('Sleep need tonight'), findsOneWidget);
        expect(find.byType(DriverBreakdown), findsOneWidget);
        _expectCardPainted(t);
      }, timeout: const Timeout(Duration(seconds: 60)));

      // ONE UNREADABLE LEAF MUST COST THAT LEAF, NOT THE SCREEN.
      //
      // `_recovery` is called from `WellnessScreen.build`, so every cast and
      // every `.round()` in it is load-bearing for the whole domain: `x as
      // num?` tolerates null and nothing else, and `.round()` throws on NaN
      // and infinity (`jsonDecode('1e999')` is `Infinity`). Each of the six
      // leaves below used to be one of those, and any one of them turned the
      // page into a flat `0xF0C0C0C0` rectangle with the nav bar beside it.
      //
      // The write seam already refuses to let one bad leaf cost the artifact
      // (`sanitizeForJson`); this is the same rule on the read side, and this
      // is the test that says so. Both themes, because a screen that has
      // stopped painting looks different in each.
      testWidgets('a leaf of the wrong type costs its row, not the page — '
          '$where', (t) async {
        await _openRecovery(
          t,
          dark: dark,
          scale: scale,
          repo: _Repo(
            insights: const {
              'sleep_coach': {
                // Not a Map: the `need` envelope flattened to a scalar.
                'need': 12345,
                'bedtime': {
                  // Not finite: `1e999` off the wire.
                  'value': {'bedtime_min_of_day': double.infinity}
                },
                'wake': {
                  // Not a num.
                  'value': {'wake_min_of_day': '07:00'}
                },
                'nap_credit_min': 'twenty',
                'strain_bonus_min': double.nan,
              },
              // The envelope's own `value` is a String, not a map or a number.
              'sleep_debt': {'value': 'a lot'},
            },
            stress: const {
              // The Mind tab's two casts, same method, same blast radius.
              'stress': {'score': 'high', 'level': 7},
            },
          ),
        );

        // Every one of those is now ABSENT, which is a state this screen
        // already renders honestly — so the section is still here and still
        // says why, rather than the page being gone.
        expect(find.text('Sleep need tonight'), findsOneWidget);
        expect(find.text('No sleep need yet'), findsOneWidget);
        _expectCardPainted(t);
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  }
}

/// TWO framework-internal assertions this harness causes and the screen does
/// not, dropped BY NAME rather than by widening the filter.
///
/// `_load` awaits sqflite, whose continuations only run when fake time is
/// advanced, so real delays have to be interleaved with pumped frames to get
/// the screen loaded at all. That interleaving lets the semantics tree be
/// compiled while layout is still dirty, and `flushSemantics` says so. Both are
/// debug-only asserts inside the framework's own semantics pass; neither can
/// produce an `ErrorWidget`, which is what this file is about.
///
/// Everything else fails — every `TypeError`, `UnsupportedError`, `RangeError`
/// and `FlutterError`, which is the entire class of bug that greys the page.
bool _harnessArtifact(String message) =>
    message.contains('parentDataDirty') ||
    message.contains('!childSemantics.renderObject._needsLayout');

/// Pump the real screen, let its real load finish, and tap through to Recovery
/// the way a thumb does — then assert that the tab switch itself reported
/// nothing. That assertion is the point: the framework SWALLOWS a build throw
/// into an `ErrorWidget`, so without capturing `FlutterError.onError` the grey
/// page reports as a passing test.
Future<void> _openRecovery(
  WidgetTester t, {
  required bool dark,
  required double scale,
  required LocalRepository repo,
}) async {
  t.view.physicalSize = const Size(390 * 3, 844 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);

  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  addTearDown(() => FlutterError.onError = previous);

  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = repo;

  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: buildTheme(dark ? Brightness.dark : Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: Builder(
          builder: (c) => Scaffold(
            backgroundColor: P.of(c).bg,
            body: const WellnessScreen(),
          ),
        ),
      ),
    ),
  ));
  final loaded = await _settleLoad(t);

  // Cleared, NOT asserted on. The Mind tab this opens on has a pre-existing
  // layout complaint of its own (`StartCard`'s `Spacer` sits in a `Column`
  // that a `ListView` hands unbounded height), and this test is about the tab
  // that comes next. Only what the switch to Recovery reports is in scope.
  errors.clear();
  await t.tap(find.text('Recovery'), warnIfMissed: false);
  await _frames(t);

  // RESTORED BEFORE THE FIRST expect. A failing expectation while the test
  // still holds `FlutterError.onError` trips an assert inside the binding's
  // own error handler, and the test then hangs until its timeout instead of
  // reporting what actually went wrong.
  FlutterError.onError = previous;
  expect(loaded, isTrue,
      reason: 'the fixture never loaded, so nothing after this is a test');
  expect(
    errors
        .map((e) => e.exception.toString())
        .where((m) => !_harnessArtifact(m))
        .toList(),
    isEmpty,
    reason: 'a throw inside the tab body is swallowed into an ErrorWidget — '
        'grey on a release build, and green here unless this is asserted',
  );
  expect(find.byType(ErrorWidget), findsNothing);
}

/// The tab is REALLY THERE — not replaced by the thing that paints it grey.
///
/// The grey page is a PAINT-time substitution: `RenderErrorBox` is spliced in
/// where the failing subtree was, so every finder above can be satisfied by a
/// tree that draws one flat rectangle over the whole page. Walking the RENDER
/// tree for that box is the assertion that cannot be.
void _expectCardPainted(WidgetTester t) {
  final boxes = <RenderObject>[];
  void walk(RenderObject r) {
    if (r is RenderErrorBox) boxes.add(r);
    r.visitChildren(walk);
  }

  walk(t.binding.rootElement!.renderObject!);
  expect(boxes, isEmpty,
      reason: 'a RenderErrorBox is in the tree — that is the grey page, and it '
          'paints 0xF0C0C0C0 over everything the failing subtree covered');

  // …and the tab's first card is laid out with a real height. An ErrorWidget
  // has no `Surface` under it at all, so this fails before the walk above even
  // gets a chance to — which is the belt to that braces.
  expect(t.getSize(find.byType(Surface).first).height, greaterThan(0));
}
