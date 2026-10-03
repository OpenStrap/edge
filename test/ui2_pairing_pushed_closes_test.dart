// The device picker's band row PUSHES the pairing screen. In onboarding the
// gate swaps `home` underneath it when the band pairs, and nothing popped the
// pushed copy: the user sat on "Paired · Continue", whose only button re-ran
// the scan. A pushed pairing screen has to close itself on success.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _PairsAtOnce extends AppState {
  _PairsAtOnce() : super.forTesting();

  @override
  Future<bool> accessorySetupSupported() async => true;

  @override
  Future<void> pairViaAccessorySetup({String? serial}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a pushed pairing screen pops itself once paired', (t) async {
    final app = _PairsAtOnce();
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
                  builder: (_) => const PairingScreen(),
                )),
                child: const Text('under'),
              ),
            ),
          ),
        ),
      ),
    );

    await t.tap(find.text('under'));
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 32));
    }
    expect(find.byType(PairingScreen), findsOneWidget);

    await t.tap(find.text('Find my band'));
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 32));
    }

    expect(find.byType(PairingScreen), findsNothing,
        reason: 'left on "Paired", whose button re-runs the scan');
    expect(find.text('under'), findsOneWidget);
  });
}
