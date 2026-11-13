import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/app.dart' show resolveRoute;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';

// The gate's welcome/pairing switch, on the real AppState.route and
// resolveRoute. Finishing onboarding swaps WelcomeView out in the same frame,
// which is how a lossy import's report used to vanish before it was drawn.
class _Gate extends StatelessWidget {
  final ImportOutcome outcome;
  final bool holding;
  const _Gate(this.outcome, {required this.holding});
  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final raw = context.select<AppState, AppRoute>((a) => a.route);
    final r = resolveRoute(raw, pairingSkipped: false, profileSeen: false);
    return switch (r) {
      AppRoute.welcome => WelcomeView(
          onNew: () {},
          onImport: () {},
          outcome: outcome,
          onContinue: holding ? app.completeImportOnboard : null),
      _ => Scaffold(body: Text('PAIRING:${r.name}')),
    };
  }
}

Future<AppState> _fresh() async {
  SharedPreferences.setMockInitialValues({});
  return AppState()..initialized = true;
}

void main() {
  testWidgets('a lossy onboarding import stays on its report until Continue',
      (tester) async {
    final app = await _fresh();
    addTearDown(app.dispose);
    const o = ImportOutcome(
        source: 'Vendor CSV export',
        days: 30,
        rejectedRows: ['line 4: bad date'],
        rollupError: 'boom');
    final hold = await settleOnboardImport(app, o);
    expect(hold, isTrue);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app, child: MaterialApp(home: _Gate(o, holding: hold))));
    await tester.pump();
    expect(app.route, AppRoute.welcome);
    expect(find.byType(ImportReport), findsOneWidget);
    expect(find.textContaining('Re-analyze everything'), findsOneWidget);
    // The only way on is Continue, below the report.
    expect(find.text('Set up my band'), findsNothing);

    await tester.scrollUntilVisible(find.text('Continue'), 200);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(app.route, AppRoute.pairing);
    expect(find.text('PAIRING:pairing'), findsOneWidget);
  });

  testWidgets('a clean onboarding import moves straight on to pairing',
      (tester) async {
    final app = await _fresh();
    addTearDown(app.dispose);
    const o = ImportOutcome(source: 'OpenStrap backup', days: 30);
    expect(await settleOnboardImport(app, o), isFalse);
    expect(app.route, AppRoute.pairing);
  });

  testWidgets('an import that landed nothing leaves onboarding open',
      (tester) async {
    final app = await _fresh();
    addTearDown(app.dispose);
    const o = ImportOutcome(
        source: 'Vendor CSV export', rejectedRows: ['line 2: bad date']);
    expect(await settleOnboardImport(app, o), isFalse);
    expect(app.route, AppRoute.welcome);
  });

  test('every part of the report that says something was refused holds', () {
    const base = ImportOutcome(source: 's', days: 1);
    expect(base.needsReading, isFalse);
    for (final o in const [
      ImportOutcome(source: 's', days: 1, rejectedRows: ['x']),
      ImportOutcome(source: 's', days: 1, readError: 'x'),
      ImportOutcome(source: 's', days: 1, rollupError: 'x'),
      ImportOutcome(source: 's', days: 1, lateRows: 1),
      ImportOutcome(source: 's', days: 1, strandedDays: 1),
      ImportOutcome(source: 's', days: 1, corruptTables: {'t'}),
      ImportOutcome(source: 's', days: 1, archiveBucketsSkipped: 1),
    ]) {
      expect(o.needsReading, isTrue);
    }
  });
}
