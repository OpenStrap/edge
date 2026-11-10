import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart';
import 'package:openstrap_edge/ui2/pairing/whoop_firmware_warning.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('connection warning precedes search in $brightness', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final query = TextEditingController(text: 'Polar');
      addTearDown(query.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(brightness),
          home: DevicePickerView(
            query: query,
            title: 'Connect your devices',
            subtitle: 'Pair a device now or add more later.',
          ),
        ),
      );
      final warning = find.byType(WhoopFirmwareWarning);
      expect(warning, findsOneWidget);
      expect(
        find.text('WHOOP users: do not reconnect to the WHOOP app'),
        findsOneWidget,
      );
      expect(t.getTopLeft(warning).dy, lessThan(150));
      await t.ensureVisible(find.byType(TextField));
      expect(
        t.getTopLeft(warning).dy,
        lessThan(t.getTopLeft(find.byType(TextField)).dy),
      );
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('sensor-only connection flow can omit the WHOOP warning', (
    t,
  ) async {
    final query = TextEditingController();
    addTearDown(query.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: DevicePickerView(
          query: query,
          title: 'Add a sensor',
          subtitle: 'Heart-rate sensors',
          showWhoopWarning: false,
        ),
      ),
    );
    expect(find.byType(WhoopFirmwareWarning), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  for (final phase in [PairPhase.idle, PairPhase.failed]) {
    testWidgets('WHOOP $phase keeps warning and controls at large text', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      var attempts = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: PairingView(
            phase: phase,
            onPair: () => attempts++,
            onSkip: () {},
          ),
        ),
      );
      expect(find.byType(WhoopFirmwareWarning), findsOneWidget);
      expect(t.getTopLeft(find.byType(WhoopFirmwareWarning)).dy, lessThan(100));
      expect(
        find.textContaining('Uninstall or disable the WHOOP app'),
        findsOneWidget,
      );
      final button = find.text(
        phase == PairPhase.idle ? 'Find my band' : 'Try again',
      );
      await t.scrollUntilVisible(button, 400);
      await t.pumpAndSettle();
      await t.tap(button);
      expect(attempts, 1);
      expect(t.takeException(), isNull);
    });
  }
}
