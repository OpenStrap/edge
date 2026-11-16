// Real-shell regression coverage for the independent coach and Help entries.
// Repository data, transport and platform storage are fake; AI widgets are real.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:openstrap_edge/ai/briefing.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme_switcher.dart';
import 'package:openstrap_edge/ui2/guides/guide_run.dart';
import 'package:openstrap_edge/ui2/guides/guide_step_card.dart';
import 'package:openstrap_edge/ui2/guides/help_screen.dart';
import 'package:openstrap_edge/ui2/guides/live_guide_overlay.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/screens/ai_briefing.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../support/bundled_fonts.dart';
import '../support/guide_r2_scenes.dart' show r2OpenDb, r2Guide;
import '../support/live_guide_harness.dart';
import '../support/skeleton_fixture.dart' show skLoadAppFonts;

class _DocumentsProvider extends PathProviderPlatform {
  _DocumentsProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

class _Provider {
  final requests = <http.Request>[];
  bool failNext = false;
  late final client = MockClient((request) async {
    requests.add(request);
    if (request.method == 'GET') {
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'test-coach'},
          ],
        }),
        200,
      );
    }
    if (failNext) {
      failNext = false;
      return http.Response(
        jsonEncode({
          'error': {'message': 'Test provider unavailable'},
        }),
        503,
      );
    }
    final body = jsonDecode(request.body) as Map;
    final briefing = !body.containsKey('tools');
    final answer = briefing
        ? 'Your resting heart rate is 52 bpm.\n\n- No scored night is available; sleep details are withheld.'
        : 'I can explain the recorded data. Your resting heart rate is 52 bpm.';
    return http.Response(
      jsonEncode({
        'output': [
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': answer},
            ],
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

Finder _press(String label) =>
    find.byWidgetPredicate((w) => w is Pressable && w.semanticLabel == label);
Finder _row(String title) =>
    find.byWidgetPredicate((w) => w is SetRow && w.title == title);
Finder _field(String label) => find.descendant(
  of: find.ancestor(
    of: find.text(label.toUpperCase()),
    matching: find.byType(OsTextField),
  ),
  matching: find.byType(TextField),
);
Future<void> _reveal(WidgetTester t, Finder finder) async {
  await t.scrollUntilVisible(
    finder,
    260,
    scrollable: find.byType(Scrollable).first,
  );
  await settleLiveGuide(t);
  expect(finder.hitTestable(), findsOneWidget);
}

Future<void> _setup(WidgetTester t, CoachConfig config) async {
  expect(find.byType(CoachSetup), findsOneWidget);
  await _reveal(t, _field('API key'));
  await t.enterText(_field('API key'), 'test-placeholder-key');
  await _reveal(t, find.text('List models'));
  await t.tap(find.text('List models'));
  await settleLiveGuide(t);
  await _reveal(t, find.text('test-coach'));
  await t.tap(find.text('test-coach'));
  await _reveal(t, find.text('Save'));
  await t.tap(find.text('Save'));
  await settleLiveGuide(t);
  expect(config.configured, isTrue);
  expect(config.model, 'test-coach');
  expect(config.api, CoachApi.responses);
  expect(config.apiKey, 'test-placeholder-key');
  expect(find.byType(CoachSetup), findsNothing);
}

Future<void> _send(WidgetTester t, String text) async {
  await t.enterText(find.byType(TextField), text);
  await t.tap(_press('Send'));
  await settleLiveGuide(t, frames: 14);
  for (
    var i = 0;
    i < 30 && !t.widget<TextField>(find.byType(TextField)).enabled!;
    i++
  ) {
    await settleLiveGuide(t, frames: 4);
  }
  expect(t.widget<TextField>(find.byType(TextField)).enabled, isTrue);
}

Future<void> _dispose(WidgetTester t, LiveGuideApp app) async {
  app.runner.exit();
  await t.pumpWidget(const SizedBox());
  app.dispose();
  await t.pump();
  expect(t.takeException(), isNull);
}

void main() {
  setUpAll(() async {
    await loadFonts();
    await skLoadAppFonts();
    await r2OpenDb('pr716_coach_flow.db');
  });
  tearDownAll(LocalDb.close);
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('coach-flow-');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _DocumentsProvider(dir.path);
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      await dir.delete(recursive: true);
    });
    // The live harness replaces SharedPreferences; refresh its cached facade
    // after mounting, before any briefing reads or writes.
  });

  // why: an unconfigured briefing must offer recovery, while cancelling
  // ChatGPT consent must leave the user unconfigured and send no request.
  Future<void> noModel(WidgetTester t) async {
    final fake = _Provider();
    await http.runWithClient(() async {
      final config = CoachConfig();
      final app = await pumpLiveGuideApp(
        t,
        brightness: Brightness.dark,
        coachConfig: config,
      );
      await Prefs.reload();
      await _reveal(t, find.text('Briefing'));
      await t.tap(find.text('Briefing'));
      await settleLiveGuide(t);
      expect(find.byType(AiBriefingScreen), findsOneWidget);
      expect(find.text('No model is set up'), findsOneWidget);
      await t.tap(find.text('Choose a model'));
      await settleLiveGuide(t);
      expect(find.byType(CoachSetup), findsOneWidget);
      await t.tap(find.text('ChatGPT'));
      await settleLiveGuide(t);
      expect(find.text('Before you sign in'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await settleLiveGuide(t);
      expect(find.text('Before you sign in'), findsNothing);
      expect(config.configured, isFalse);
      expect(fake.requests, isEmpty);
      app.navigator.pop();
      await settleLiveGuide(t);
      expect(find.text('No model is set up'), findsOneWidget);
      app.navigator.pop();
      await settleLiveGuide(t);
      expect(_press('Set up the coach'), findsOneWidget);
      await _dispose(t, app);
      config.dispose();
    }, () => fake.client);
  }

  // why: Help beside AI coach must retain independent taps and semantics;
  // a first-time user must be able to configure then use the real coach.
  Future<void> profileFlow(WidgetTester t) async {
    final fake = _Provider();
    await http.runWithClient(() async {
      final config = CoachConfig();
      final app = await pumpLiveGuideApp(
        t,
        brightness: Brightness.dark,
        coachConfig: config,
      );
      await Prefs.reload();
      final semantics = t.ensureSemantics();
      await t.tap(find.byType(ProfileAvatar));
      await settleLiveGuide(t);
      expect(find.byType(ProfileHome), findsOneWidget);
      await _reveal(t, _row('AI coach'));
      expect(find.text('Not set up'), findsOneWidget);
      final coachRect = t.getRect(_row('AI coach'));
      final helpRect = t.getRect(_row('Help'));
      expect(coachRect.bottom, lessThanOrEqualTo(helpRect.top));
      final coachSemantics = t
          .getSemantics(_row('AI coach'))
          .getSemanticsData();
      expect(coachSemantics.label, contains('AI coach. Not set up'));
      expect(coachSemantics.label, isNot(contains('Help')));
      expect(coachSemantics.hasAction(SemanticsAction.tap), isTrue);
      final helpLabel = t.getSemantics(_row('Help')).getSemanticsData().label;
      expect(helpLabel, contains('Help'));
      expect(helpLabel, isNot(contains('AI coach')));
      await t.tap(_row('Help'));
      await settleLiveGuide(t);
      expect(find.byType(HelpScreen), findsOneWidget);
      app.navigator.pop();
      await settleLiveGuide(t);
      // Tap near the lower edge adjacent to Help, not only the row centre.
      await t.tapAt(Offset(coachRect.center.dx, coachRect.bottom - 2));
      await settleLiveGuide(t);
      await _setup(t, config);
      expect(find.byType(ProfileHome), findsOneWidget);
      expect(find.text('test-coach'), findsOneWidget);
      app.navigator.pop();
      await settleLiveGuide(t);
      await _reveal(t, _press('Ask the coach'));
      final chip = t.getRect(_press('Ask the coach'));
      await _reveal(
        t,
        find.widgetWithText(TextButton, 'Looking for something?'),
      );
      final footer = t.getRect(
        find.widgetWithText(TextButton, 'Looking for something?'),
      );
      final movedChip = t.getRect(_press('Ask the coach'));
      expect(movedChip.bottom, lessThanOrEqualTo(footer.top));
      expect(movedChip.size, chip.size);
      await t.tap(_press('Ask the coach'));
      await settleLiveGuide(t);
      expect(find.byType(CoachScreen), findsOneWidget);
      expect(find.text('YOUR DATA, YOUR MODEL'), findsOneWidget);
      await _send(t, 'Can you assess my recovery?');
      expect(find.text('Can you assess my recovery?'), findsOneWidget);
      expect(
        find.textContaining(
          'I can explain the recorded data',
          findRichText: true,
        ),
        findsOneWidget,
      );
      final post = fake.requests.where((r) => r.method == 'POST').single;
      expect(post.url.path, '/v1/responses');
      expect(post.headers['authorization'], 'Bearer test-placeholder-key');
      expect(jsonDecode(post.body)['model'], 'test-coach');
      app.navigator.pop();
      await settleLiveGuide(t);
      await t.tap(_press('Ask the coach'));
      await settleLiveGuide(t);
      await settleLiveGuide(t, frames: 30);
      expect(
        find.text('Can you assess my recovery?'),
        findsOneWidget,
        reason: 'completed chat survives leaving and reopening',
      );
      await t.tap(_press('Chats and AI settings'));
      await settleLiveGuide(t);
      await t.tap(find.text('Briefing, and what was sent'));
      await settleLiveGuide(t);
      expect(find.byType(AiBriefingScreen), findsOneWidget);
      app.navigator.pop();
      await settleLiveGuide(t);
      // Pin morning generation independently of the wall clock's evening sweep.
      app.navigator.push(
        themedRoute<void>(
          (_) => const AiBriefingScreen(period: BriefingPeriod.morning),
          name: 'AiBriefingScreen',
        ),
      );
      await settleLiveGuide(t);
      expect(find.text('Nothing written for today'), findsOneWidget);
      await t.tap(find.text('Write one now'));
      await settleLiveGuide(t, frames: 18);
      expect(find.text('Your resting heart rate is 52 bpm.'), findsOneWidget);
      expect(
        BriefingStore.read(BriefingPeriod.morning)?.oneLiner,
        'Your resting heart rate is 52 bpm.',
      );
      await _reveal(t, find.text('What was sent'));
      app.navigator.pop();
      await settleLiveGuide(t);
      fake.failNext = true;
      await _send(t, 'Please try again');
      expect(
        find.textContaining('Test provider unavailable', findRichText: true),
        findsOneWidget,
      );
      await _send(t, 'Is the provider back?');
      expect(
        find.textContaining(
          'I can explain the recorded data',
          findRichText: true,
        ),
        findsNWidgets(2),
      );
      app.navigator.pop();
      await settleLiveGuide(t);
      semantics.dispose();
      await _dispose(t, app);
      config.dispose();
    }, () => fake.client);
  }

  // why: the Home chip is also a setup entry; guides must release coach input
  // after the guide exits, without leaving a stale input-blocking layer.
  Future<void> guideFlow(WidgetTester t) async {
    final fake = _Provider();
    await http.runWithClient(() async {
      final config = CoachConfig();
      final app = await pumpLiveGuideApp(
        t,
        brightness: Brightness.dark,
        coachConfig: config,
      );
      await Prefs.reload();
      await _reveal(t, _press('Set up the coach'));
      await t.tap(_press('Set up the coach'));
      await settleLiveGuide(t);
      await _setup(t, config);
      expect(find.byType(HomeScreen), findsOneWidget);
      await app.runner.start(r2Guide('heart-rate-zones'), band: null);
      await settleLiveGuide(t, frames: 18);
      expect(find.byType(LiveGuideOverlay), findsOneWidget);
      // A guide deliberately makes unrelated controls into inert skeletons.
      // Simulate a route arriving while it runs, as a notification can do.
      app.navigator.push(
        themedRoute<void>((_) => const CoachScreen(), name: 'CoachScreen'),
      );
      await settleLiveGuide(t, frames: 18);
      expect(find.byType(CoachScreen), findsOneWidget);
      expect(app.runner.activeRun?.state, isA<GuideOffPath>());
      expect(_press('Send').hitTestable(), findsNothing);
      expect(fake.requests.where((r) => r.method == 'POST'), isEmpty);
      await t.tap(find.byKey(GuideStepCard.exitKey));
      await settleLiveGuide(t);
      expect(app.runner.activeRun, isNull);
      expect(find.byType(CoachScreen), findsOneWidget);
      await _send(t, 'And after exiting the guide?');
      expect(
        find.textContaining(
          'I can explain the recorded data',
          findRichText: true,
        ),
        findsOneWidget,
      );
      app.navigator.pop();
      await settleLiveGuide(t);
      await _dispose(t, app);
      config.dispose();
    }, () => fake.client);
  }

  // CoachEngine serializes files through a process-wide Future chain. Keep
  // these journeys in one widget-test clock so its completed futures do not
  // schedule work into a previous test's discarded fake-async zone.
  // why: Help and guide navigation must preserve setup, saved chats,
  // provider-error recovery and the independent briefing route.
  testWidgets(
    'coach setup, chat and briefing survive Help and guide navigation',
    (t) async {
      await noModel(t);
      await profileFlow(t);
      await t.runAsync(() async {
        final path = await PathProviderPlatform.instance
            .getApplicationDocumentsPath();
        await for (final entry in Directory(path!).list()) {
          await entry.delete(recursive: true);
        }
      });
      await guideFlow(t);
    },
  );
}
