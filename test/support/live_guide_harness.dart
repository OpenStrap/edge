// Test harness for LIVE guides: the REAL app shell (AppMainShell, lib/app.dart)
// with the real tab screens, fed by a fake repository, under a MaterialApp that
// has the root-Navigator key a [GuideRunner] needs.
//
// Fake data is data, not behaviour: [GuideFakeRepo] answers the repository
// reads the Today, Day strain, Zones and Activity screens make, with the shapes
// the production repository returns (the same keys test/wearable_screens_wiring_
// test.dart relies on). Nothing is stubbed in the code under test.
//
// Not a test file (no _test suffix).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/app.dart' show AppMainShell;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/guides/guide_runner.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final String _today = todayLabel();

Map<String, dynamic> _metric(num v) => {'value': v, 'confidence': .9, 'tier': 'HIGH'};

/// One believable day, as the production repository serves it: recovery 72,
/// strain 9.4 with minutes in all five zones, no scored night.
class GuideFakeRepo extends LocalRepository {
  /// 'auto' (the app staged the night) or 'manual' (the user set the times):
  /// guide #5 step 2 ("Back to automatic") exists only on a manual night.
  final String sleepSource;

  /// A saved workout in History (guide #6's bin exists per saved session).
  final bool withWorkout;

  /// Two auto-detected bouts waiting for an answer (guide #4's Today card).
  final bool withPending;

  GuideFakeRepo({this.sleepSource = 'auto', this.withWorkout = true, this.withPending = true});

  static int _at(int hour, int minute) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, hour, minute).millisecondsSinceEpoch ~/ 1000;
  }

  @override
  Future<List<ActivitySuggestion>> pendingActivities() async => withPending
      ? [
          ActivitySuggestion(id: 'n1', kind: ActivityKind.nap, startTs: _at(13, 5), endTs: _at(13, 45), revision: 0),
          ActivitySuggestion(
            id: 'w1',
            kind: ActivityKind.workout,
            startTs: _at(17, 30),
            endTs: _at(18, 10),
            revision: 0,
            details: const {'sport': 'running', 'peak_bpm': 168, 'avg_bpm': 141},
          ),
        ]
      : const [];
  @override
  Future<Map<String, dynamic>> getChart(String metric, {int? from, int? to, Set<String> signals = const {}}) async => const {'points': []};
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async => const {'naps': [], 'nap_min': 0};
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async => const [];
  @override
  Future<List<Map<String, Object?>>> getDeviceNights(String date) async => const [];
  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async => {
        'workouts': withWorkout
            ? [
                {
                  'id': 'session-1',
                  'type': 'running',
                  'start_ts': _at(7, 0),
                  'duration_min': 42,
                  'strain': 8.1,
                  'calories': 410,
                  'avg_hr': 148,
                  'max_hr': 171,
                },
              ]
            : const [],
      };

  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': _metric(72),
          'strain': _metric(9.4),
          'resting_hr': _metric(52),
          'steps': _metric(6842),
          'calories': _metric(1180),
          'calories_total': _metric(2310),
        },
        'status': {'today_day': _today},
      };
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {'name': 'Alex'};
  @override
  Future<List<String>> availableDays() async => [_today];
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async =>
      {'readiness': _metric(72), 'resting_hr': _metric(52)};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => {
        'strain': 9.4,
        'zones': {'z1': 62, 'z2': 48, 'z3': 31, 'z4': 14, 'z5': 3},
        'zone_source': 'tanaka',
        'zone_max_hr': 185,
        'hr': {'max': 171},
      };
  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => const {'worn_min': 900, 'coverage_pct': 94};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {
        'has_sleep': true,
        'sleep_source': sleepSource,
        'onset_ts': _at(0, 0) - 3600,
        'wake_ts': _at(0, 0) + 6 * 3600,
        'duration_min': 420,
      };
  @override
  Future<Map<String, dynamic>> getZones() async => {
        'source': 'tanaka',
        'max_hr': 185,
        'zones': [
          for (final (i, name) in ['Warm-up', 'Easy', 'Aerobic', 'Threshold', 'Max effort'].indexed)
            {'zone': i + 1, 'name': name, 'lo': 90 + i * 19, 'hi': 108 + i * 19},
        ],
      };
}

/// The mounted app and the handles tests drive it with.
class LiveGuideApp {
  final AppState state;
  final GuideRunner runner;
  final GlobalKey<NavigatorState> navigatorKey;
  LiveGuideApp(this.state, this.runner, this.navigatorKey);

  NavigatorState get navigator => navigatorKey.currentState!;
}

/// Mounts [home] (default: the real [AppMainShell]) under the providers the
/// screens read and a MaterialApp whose root Navigator is `navigatorKey`.
/// Shared-preferences storage is empty and loaded, so the shell opens on Today.
Future<LiveGuideApp> pumpLiveGuideApp(
  WidgetTester t, {
  Widget? home,
  Locale locale = const Locale('en'),
  double textScale = 1,
  Size size = const Size(390, 844),
  GuideRunner? runner,
  LocalRepository? repo,
}) async {
  SharedPreferences.setMockInitialValues(const {});
  await Prefs.ensureLoaded();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);

  // Sleep correction controls require retained input. Seed only a test DB row;
  // the repository's published night alone does not establish correctability.
  if (repo is GuideFakeRepo || repo == null) {
    await t.runAsync(() async {
      final ts = GuideFakeRepo._at(12, 0);
      await (await LocalDb.instance).rawInsert(
        'INSERT OR REPLACE INTO decoded_onehz (device_id, ts_ms, rec_ts, counter, hr) VALUES (?, ?, ?, ?, ?)',
        ['', ts * 1000, ts, ts % 100000, 60],
      );
    });
  }

  final key = GlobalKey<NavigatorState>();
  final guideRunner = runner ?? GuideRunner(navigatorKey: key);
  final state = AppState.forTesting();
  addTearDown(state.dispose);
  state.repo = repo ?? GuideFakeRepo();
  final app = LiveGuideApp(state, guideRunner, runner?.navigatorKey ?? key);

  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: state),
      ChangeNotifierProvider<ThemeController>.value(
          value: ThemeController.seed(AppThemeChoice.light, Brightness.light)),
      ChangeNotifierProvider<GuideRunner>.value(value: guideRunner),
    ],
    child: MaterialApp(
      navigatorKey: app.navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home ?? const AppMainShell(),
    ),
  ));
  await settleLiveGuide(t);
  return app;
}

/// Several frames and real-zone time for the repository reads to land. Not
/// `pumpAndSettle`: the Activity tab's live cards run periodic timers.
Future<void> settleLiveGuide(WidgetTester t, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// A JSON snapshot of every shared-preferences key, to compare before/after.
Future<String> prefsSnapshot() async {
  final sp = await SharedPreferences.getInstance();
  return jsonEncode({for (final k in (sp.getKeys().toList()..sort())) k: sp.get(k)});
}
