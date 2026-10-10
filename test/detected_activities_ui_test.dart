import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';

ActivitySuggestion proposal(
  String id,
  ActivityKind kind, {
  int revision = 0,
  int shift = 0,
}) => ActivitySuggestion(
  id: id,
  kind: kind,
  startTs: 1787157000 + shift,
  endTs: 1787158800 + shift,
  revision: revision,
  details: const {'sport': 'unrecognized'},
);

class _Repo extends LocalRepository {
  List<ActivitySuggestion> items = [
    proposal('nap', ActivityKind.nap),
    proposal('workout', ActivityKind.workout),
  ];
  bool fail = false;
  String? savedType;
  @override
  Future<List<ActivitySuggestion>> pendingActivities() async {
    if (fail) throw StateError('offline database');
    return items.toList();
  }

  @override
  Future<int> pendingActivityCount() async {
    if (fail) throw StateError('offline database');
    return items.length;
  }

  @override
  Future<List<SessionSpan>> savedSessionSpans() async => [];
  @override
  Future<void> discardActivity(ActivitySuggestion s) async {
    items.removeWhere((i) => i.id == s.id);
  }

  @override
  Future<void> confirmActivity(
    ActivitySuggestion s, {
    int? startTs,
    int? endTs,
    String? workoutType,
  }) async {
    if (items.singleWhere((i) => i.id == s.id).revision != s.revision) {
      throw const ActivityReviewException(
        'The proposal changed. Review the new times.',
      );
    }
    savedType = workoutType;
    items.removeWhere((i) => i.id == s.id);
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'notify_auto_detect': false}),
  );
  Future<_Repo> pump(WidgetTester t, {bool fail = false, Widget? home}) async {
    t.view.physicalSize = const Size(1170, 6000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final repo = _Repo()..fail = fail;
    app.repo = repo;
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ThemeController>(
            create: (_) =>
                ThemeController.seed(AppThemeChoice.light, Brightness.light),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: home ?? const DetectedActivitiesScreen(),
        ),
      ),
    );
    await t.pumpAndSettle();
    return repo;
  }

  testWidgets('load failure offers retry and does not claim an empty list', (
    t,
  ) async {
    final repo = await pump(t, fail: true);
    expect(find.text('Could not load activities. Try again.'), findsOneWidget);
    expect(find.text('Nothing to review'), findsNothing);
    repo.fail = false;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('Possible nap'), findsOneWidget);
    expect(find.text('Possible workout'), findsOneWidget);
  });

  testWidgets('confirm and discard remove only the selected item', (t) async {
    final repo = await pump(t);
    await t.tap(find.text('Confirm').first);
    await t.pumpAndSettle();
    expect(repo.items.single.id, 'workout');
    await t.tap(find.text('Not a workout'));
    await t.pumpAndSettle();
    expect(repo.items, isEmpty);
    expect(find.text('Nothing to review'), findsOneWidget);
  });

  testWidgets('cancelling a nap edit leaves it pending', (t) async {
    final repo = await pump(t);
    await t.tap(find.text('Edit').first);
    await t.pumpAndSettle();
    expect(find.text('Save and confirm'), findsOneWidget);
    Navigator.of(t.element(find.byType(NapProposalEditor))).pop();
    await t.pumpAndSettle();
    expect(repo.items, hasLength(2));
  });

  testWidgets(
    'unknown workout stays Other; stale edit shows new proposal before a second save',
    (t) async {
      final repo = await pump(t);
      await t.tap(find.text('Change sport'));
      await t.pumpAndSettle();
      expect(find.text('Other'), findsOneWidget);
      repo.items[1] = proposal(
        'workout',
        ActivityKind.workout,
        revision: 1,
        shift: 600,
      );
      await t.tap(find.text('Save and confirm'));
      await t.pumpAndSettle();
      expect(repo.items, hasLength(2));
      expect(
        find.text('The proposal changed. Review the new times.'),
        findsOneWidget,
      );
      await t.tap(find.text('Save and confirm'));
      await t.pumpAndSettle();
      expect(repo.items.single.id, 'nap');
      expect(repo.savedType, 'other');
    },
  );

  testWidgets('failed stale-proposal reload does not leave save stuck', (
    t,
  ) async {
    final repo = await pump(t);
    await t.tap(find.text('Change sport'));
    await t.pumpAndSettle();
    repo.items[1] = proposal(
      'workout',
      ActivityKind.workout,
      revision: 1,
      shift: 600,
    );
    repo.fail = true;
    await t.tap(find.text('Save and confirm'));
    await t.pumpAndSettle();
    expect(repo.items, hasLength(2));
    repo.fail = false;
    await t.tap(find.text('Save and confirm'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save and confirm'));
    await t.pumpAndSettle();
    expect(repo.items.single.id, 'nap');
  });

  testWidgets('home card stays up when the count fails to load', (t) async {
    await pump(t, fail: true, home: const Scaffold(body: DetectedActivitiesCard()));
    expect(find.text('Detected activities'), findsOneWidget);
    expect(find.text('Could not load activities. Try again.'), findsOneWidget);
  });
}
