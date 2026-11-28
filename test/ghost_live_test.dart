// Ghost run, the live gap against a fake feed: the card must say ahead /
// behind / level in words, refuse a gap it can not compute, buzz the band
// once per change of lead (never spam), and congratulate at the finish.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openstrap_edge/gps/ghost_math.dart';
import 'package:openstrap_edge/gps/route_models.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/ghost.dart';
import 'package:openstrap_edge/ui2/activity/live.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mPerDeg = 111319.49;

/// 3000 m due east at 3 m/s, a fix every 5 s.
List<RoutePoint> _ghostPts() => [
  for (var i = 0; i < 201; i++)
    RoutePoint(
      seq: i,
      tsMs: 1000000 + i * 5000,
      lat: 0,
      lng: 15.0 * i / _mPerDeg,
    ),
];

LatLng at(double m) => LatLng(0, m / _mPerDeg);

Widget _screen(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildTheme(Brightness.light),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Widget _frame(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildTheme(Brightness.light),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// A fake feed: set [feed.value] and the panel is rebuilt with it, exactly
/// as the live screen rebuilds it each second.
class _Feed {
  final value = ValueNotifier<(int, LatLng?)>((0, null));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final track = GhostTrack.tryBuild(_ghostPts())!;

  Future<_Feed> mount(
    WidgetTester t, {
    Future<void> Function()? buzz,
    bool buzzOn = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    final f = _Feed();
    await t.pumpWidget(
      _frame(
        ValueListenableBuilder<(int, LatLng?)>(
          valueListenable: f.value,
          builder: (_, v, _) => GhostPanel(
            track: track,
            elapsedSec: v.$1,
            fix: v.$2,
            buzz: buzz,
            buzzOn: buzzOn,
          ),
        ),
      ),
    );
    return f;
  }

  Future<void> feed(WidgetTester t, _Feed f, int sec, LatLng? fix) async {
    f.value.value = (sec, fix);
    await t.pump();
  }

  String gap(WidgetTester t) =>
      (t.widget(find.byKey(const Key('ghost-gap'))) as Text).data!;

  testWidgets('no fix: says so and shows no number', (t) async {
    final f = await mount(t);
    await feed(t, f, 30, null);
    expect(gap(t), 'Waiting for GPS');
    expect(find.byKey(const Key('ghost-gap-sec')), findsNothing);
  });

  testWidgets('ahead reads in metres and seconds', (t) async {
    final f = await mount(t);
    await feed(t, f, 0, at(0));
    await feed(t, f, 100, at(360)); // ghost is at 300 m
    expect(gap(t), '60 m ahead');
    expect(find.text('20 s ahead of your ghost'), findsOneWidget);
  });

  testWidgets('behind reads in metres and seconds', (t) async {
    final f = await mount(t);
    await feed(t, f, 0, at(0));
    await feed(t, f, 100, at(270));
    expect(gap(t), '30 m behind');
    expect(find.text('10 s behind your ghost'), findsOneWidget);
  });

  testWidgets('a gap inside GPS wander is level', (t) async {
    final f = await mount(t);
    await feed(t, f, 0, at(0));
    await feed(t, f, 100, at(303));
    expect(gap(t), 'Level with your ghost');
  });

  testWidgets('somewhere else entirely: refuses a gap', (t) async {
    final f = await mount(t);
    await feed(t, f, 20, const LatLng(0.05, 0.003));
    expect(gap(t), contains('no gap to show'));
    expect(find.byKey(const Key('ghost-gap-sec')), findsNothing);
  });

  testWidgets('buzzes once when the lead changes, not on every tick', (
    t,
  ) async {
    var buzzes = 0;
    final f = await mount(t, buzz: () async => buzzes++);
    await feed(t, f, 0, at(0));
    await feed(t, f, 100, at(360)); // +60 m: first side, no buzz
    expect(buzzes, 0);
    await feed(t, f, 200, at(540)); // ghost 600 m: -60 m, lead flips
    expect(buzzes, 1);
    await feed(t, f, 201, at(543));
    await feed(t, f, 202, at(546));
    expect(buzzes, 1, reason: 'same side, and inside the cooldown');
    await t.pumpAndSettle();
  });

  testWidgets('the buzz toggle off means no buzz', (t) async {
    var buzzes = 0;
    final f = await mount(t, buzz: () async => buzzes++, buzzOn: false);
    await feed(t, f, 0, at(0));
    await feed(t, f, 100, at(360));
    await feed(t, f, 200, at(540));
    expect(buzzes, 0);
  });

  testWidgets('a buzz callback that throws does not break the screen', (
    t,
  ) async {
    final f = await mount(t, buzz: () async => throw StateError('no band'));
    await feed(t, f, 0, at(0));
    await feed(t, f, 100, at(360));
    await feed(t, f, 200, at(540));
    expect(gap(t), '60 m behind');
  });

  testWidgets('crossing the line first is a win with the real margin', (
    t,
  ) async {
    final f = await mount(t);
    await feed(t, f, 0, at(0));
    await feed(t, f, 900, at(2700));
    await feed(t, f, 950, at(3000));
    expect(gap(t), 'You beat your ghost by 50 s');
    await t.pumpAndSettle();
  });

  testWidgets('finishing behind says so plainly', (t) async {
    final f = await mount(t);
    await feed(t, f, 0, at(0));
    await feed(t, f, 1000, at(2700));
    await feed(t, f, 1060, at(3000));
    expect(gap(t), 'Your ghost won by 1:00');
  });

  group('inside the live screen', () {
    final a = activityByName('running')!;

    testWidgets('a chosen ghost shows its gap from the feed', (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      t.view.physicalSize = const Size(390 * 3, 2600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      var pos = at(0);
      final host = ActivityHost(
        feed: () => LiveFeed(position: pos, gpsActive: true),
        ghostRoute: (id) async => id == 'old' ? _ghostPts() : null,
      );
      await t.pumpWidget(_screen(liveFor(a, host: host, ghostId: 'old')));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('ghost-panel')), findsOneWidget);
      // 100 s on the clock, standing 60 m up the road from the ghost.
      for (var i = 0; i < 100; i++) {
        if (i == 99) pos = at(360);
        await t.pump(const Duration(seconds: 1));
      }
      expect(find.text('60 m ahead'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a ghost route that can not be read says so', (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      t.view.physicalSize = const Size(390 * 3, 2600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final host = ActivityHost(
        feed: () => const LiveFeed(),
        ghostRoute: (id) async => null,
      );
      await t.pumpWidget(_screen(liveFor(a, host: host, ghostId: 'gone')));
      await t.pump();
      await t.pump();
      expect(find.text('Could not load that ghost\'s route'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('summary card', () {
    testWidgets('a win names the margin and the best and worst stretch', (
      t,
    ) async {
      const cmp = GhostComparison(
        23,
        3000,
        [
          GhostSplit(1, 0, 1000, 320, 333),
          GhostSplit(2, 1000, 2000, 350, 333),
          GhostSplit(3, 2000, 3000, 310, 333),
        ],
        GhostSplit(3, 2000, 3000, 310, 333),
        GhostSplit(2, 1000, 2000, 350, 333),
      );
      await t.pumpWidget(_frame(const GhostSummaryCard(cmp)));
      await t.pump();
      expect(find.text('You beat your ghost by 23 s'), findsOneWidget);
      expect(find.text('+23 s'), findsOneWidget);
      expect(find.text('-17 s'), findsOneWidget);
      expect(find.textContaining('Most time gained: km 3'), findsOneWidget);
      expect(find.textContaining('Most time lost: km 2'), findsOneWidget);
      await t.pumpAndSettle();
    });

    testWidgets('no comparison is a refusal, not a time', (t) async {
      await t.pumpWidget(_frame(const GhostSummaryCard(null)));
      await t.pump();
      expect(find.textContaining('Not compared'), findsOneWidget);
      expect(find.byKey(const Key('ghost-result')), findsNothing);
    });
  });

  group('picker', () {
    testWidgets('lists usable runs, greys refused ones with the reason', (
      t,
    ) async {
      GhostPick? got;
      await t.pumpWidget(
        _screen(
          Builder(
            builder: (c) => TextButton(
              onPressed: () async => got = await pickGhost(
                c,
                typeKey: 'running',
                load: (_) async => [
                  GhostCandidate(
                    id: 'good',
                    start: DateTime(2026, 11, 1, 7),
                    durationSec: 1500,
                    distanceM: 5000,
                  ),
                  GhostCandidate(
                    id: 'short',
                    start: DateTime(2026, 10, 1, 7),
                    durationSec: 200,
                    distanceM: 300,
                    refusal: GhostRefusal.tooShort,
                  ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Too short to race'), findsOneWidget);
      await t.tap(find.textContaining('25:00'));
      await t.pumpAndSettle();
      expect(got?.picked?.id, 'good');
    });

    testWidgets('no runs with a route: says what to do', (t) async {
      await t.pumpWidget(
        _screen(
          Builder(
            builder: (c) => TextButton(
              onPressed: () =>
                  pickGhost(c, typeKey: 'running', load: (_) async => []),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.textContaining('recorded route yet'), findsOneWidget);
    });
  });

  test('gap and time text', () {
    expect(ghostGapText(-12.4), '12 m');
    expect(ghostGapText(1234), '1.2 km');
    expect(ghostTimeText(-8), '8 s');
    expect(ghostTimeText(65), '1:05');
  });
}
