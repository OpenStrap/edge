// Closing the breathing screen while the session is still starting skipped
// every teardown branch (not running yet, no quiet window), so the session,
// its Live Activity and the live streams kept going with no screen left to
// stop them.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:openstrap_edge/ui2/screens/calm_breathing.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _SlowStart extends AppState {
  _SlowStart() : super.forTesting();

  final gate = Completer<void>();
  int stops = 0;

  @override
  Future<List<Map<String, dynamic>>> breathingHistory({int limit = 30}) async =>
      const [];

  @override
  Future<void> startBreathingSession({BreathPattern? pattern, Duration? target}) =>
      gate.future;

  @override
  Future<void> stopBreathingSession() async => stops++;

  @override
  Future<void> closeBreathingWindow() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('closing mid-start stops the session once it starts', (t) async {
    final app = _SlowStart();
    addTearDown(app.dispose);

    await t.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(
                  builder: (_) => const CalmBreathing(),
                )),
                child: const Text('under'),
              ),
            ),
          ),
        ),
      ),
    );

    await t.tap(find.text('under'));
    await t.pumpAndSettle();
    await t.tap(find.text('Begin'));
    await t.pump();
    await t.tap(find.bySemanticsLabel('Close breathing'));
    await t.pumpAndSettle();
    expect(find.byType(CalmBreathing), findsNothing);

    app.gate.complete();
    await t.pumpAndSettle();
    expect(app.stops, 1, reason: 'session left running behind a closed screen');
  });
}
