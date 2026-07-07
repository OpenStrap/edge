// Widget tests: the AiSummaryCard filled state, and the shared AI breakdown
// screen driven by a MOCKED briefing engine (no network, no heavy AppState).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ai/briefing.dart';
import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/ai/ai_breakdown_screen.dart';
import 'package:openstrap_edge/ui/today/ai_summary_card.dart';

class _FakeRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': {'value': 74},
          'resting_hr': {'value': 52},
        },
        'hrv': {'rmssd': 61.0},
        'status': const {},
      };
  @override
  Future<Map<String, dynamic>> getDaySleep(String date) async =>
      {'has_sleep': false};
}

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<CoachConfig>(create: (_) => CoachConfig()),
    ],
    child: MaterialApp(
      theme: buildOpenStrapTheme(palette),
      home: child,
    ),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    AppColors.active = kLightPalette;
  });
  tearDown(() => AppColors.active = kLightPalette);

  testWidgets('AiSummaryCard shows the one-liner and fires onTap', (t) async {
    var taps = 0;
    await t.pumpWidget(_host(Scaffold(
      body: AiSummaryCard(
        summary: 'You recovered well overnight.',
        onTap: () => taps++,
      ),
    )));
    await t.pump(const Duration(milliseconds: 700));
    expect(find.text('You recovered well overnight.'), findsOneWidget);
    await t.tap(find.text('You recovered well overnight.'));
    await t.pump(const Duration(milliseconds: 300));
    expect(taps, 1);
  });

  testWidgets('breakdown screen generates via mocked engine and renders',
      (t) async {
    final engine = BriefingEngine(
      config: CoachConfig(),
      repo: _FakeRepo(),
      complete: ({required system, required user}) async =>
          'Recovered and ready for a strong day.\n---\n'
          '- Readiness sits at 74\n- Resting HR steady at 52 bpm',
    );
    await t.pumpWidget(_host(AiBreakdownScreen(
      period: BriefingPeriod.morning,
      engineOverride: engine,
    )));
    await t.pump(); // post-frame _load → generate (mock resolves async)
    await t.pump(const Duration(milliseconds: 50));
    await t.pump(const Duration(milliseconds: 700));

    expect(find.text('Recovered and ready for a strong day.'), findsOneWidget);
    // "Based on" tiles reflect the inputs snapshot the model saw.
    expect(find.text('READINESS'), findsOneWidget);
    expect(find.text('74'), findsOneWidget);
    // And it was cached under today+morning.
    expect(BriefingStore.read(BriefingPeriod.morning)?.oneLiner,
        'Recovered and ready for a strong day.');
  });

  testWidgets('breakdown screen shows cached briefing instantly (no generate)',
      (t) async {
    BriefingStore.write(Briefing(
      day: todayLabel(),
      period: BriefingPeriod.evening,
      oneLiner: 'A solid, active day.',
      breakdownMd: '- Strain 12.4\n- 8,300 steps',
      generatedAtMs: DateTime.now().millisecondsSinceEpoch,
      inputs: const {'strain_0_21': 12.4, 'steps': 8300},
    ));
    // An engine that would THROW if called — proves we render from cache.
    final engine = BriefingEngine(
      config: CoachConfig(),
      repo: _FakeRepo(),
      complete: ({required system, required user}) async =>
          throw StateError('should not generate when cached'),
    );
    await t.pumpWidget(_host(AiBreakdownScreen(
      period: BriefingPeriod.evening,
      engineOverride: engine,
    )));
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));
    expect(find.text('A solid, active day.'), findsOneWidget);
  });
}
