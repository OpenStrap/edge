import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

BleEngine _fakeEngine({
  required Future<bool> Function(Uint8List frame) onWrite,
  BandProfile band = BandProfile.gen4,
  void Function(DeviceState)? onState,
}) {
  final engine = BleEngine(
    onRecord: (_, _) async {},
    onState: onState ?? (_) {},
  );
  engine.debugInstallFakeLink(
    onWrite: onWrite,
    band: band,
    listening: true,
  );
  return engine;
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: child,
    );

void _tallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  group('BleEngine.setHrBroadcast', () {
    test('returns false when disconnected without writing', () async {
      final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
      expect(await engine.setHrBroadcast(true), isFalse);
      expect(engine.state.hrBroadcast, isNull);
    });

    test('writes 0x0E [0x01]/[0x00] on gen4 and updates state.hrBroadcast',
        () async {
      final writes = <Uint8List>[];
      final states = <bool?>[];
      final engine = _fakeEngine(
        band: BandProfile.gen4,
        onWrite: (f) async {
          writes.add(f);
          return true;
        },
        onState: (s) => states.add(s.hrBroadcast),
      );

      final onOk = await engine.setHrBroadcast(
        true,
        timeout: const Duration(milliseconds: 20),
      );
      expect(onOk, isTrue);
      expect(engine.state.hrBroadcast, isTrue);
      expect(states.last, isTrue);

      final onFrame = parseFrame(writes.single, profile: BandProfile.gen4);
      expect(onFrame, isNotNull);
      expect(onFrame!.inner[0], PacketType.command);
      expect(onFrame.inner[2], Cmd.setGenericHrProfile);
      expect(onFrame.inner.sublist(3), [0x01]);

      final offOk = await engine.setHrBroadcast(
        false,
        timeout: const Duration(milliseconds: 20),
      );
      expect(offOk, isTrue);
      expect(engine.state.hrBroadcast, isFalse);

      final offFrame = parseFrame(writes.last, profile: BandProfile.gen4);
      expect(offFrame, isNotNull);
      expect(offFrame!.inner[2], Cmd.setGenericHrProfile);
      expect(offFrame.inner.sublist(3), [0x00]);
    });

    test('writes 0x0E [0x01] with gen5 framing', () async {
      final writes = <Uint8List>[];
      final engine = _fakeEngine(
        band: BandProfile.gen5,
        onWrite: (f) async {
          writes.add(f);
          return true;
        },
      );

      final ok = await engine.setHrBroadcast(
        true,
        timeout: const Duration(milliseconds: 20),
      );
      expect(ok, isTrue);
      final frame = parseFrame(writes.single, profile: BandProfile.gen5);
      expect(frame, isNotNull);
      expect(frame!.inner[2], Cmd.setGenericHrProfile);
      expect(frame.inner.sublist(3), [0x01]);
    });

    test('failed write returns false and leaves state.hrBroadcast unchanged',
        () async {
      final engine = _fakeEngine(
        onWrite: (_) async => false,
      );

      final ok = await engine.setHrBroadcast(
        true,
        timeout: const Duration(milliseconds: 20),
      );
      expect(ok, isFalse);
      expect(engine.state.hrBroadcast, isNull);
    });
  });

  group('MoreSettingsView HR broadcast row', () {
    testWidgets('shows Off/On and invokes onToggleHrBroadcast when tapped',
        (tester) async {
      _tallPhone(tester);
      var taps = 0;
      await tester.pumpWidget(_wrap(MoreSettingsView(
        version: '1',
        hrBroadcast: false,
        onToggleHrBroadcast: () => taps++,
      )));
      final rowOff =
          tester.widget<SetRow>(find.widgetWithText(SetRow, 'HR broadcast'));
      expect(rowOff.value, 'Off');
      await tester.tap(find.text('HR broadcast'));
      expect(taps, 1);

      await tester.pumpWidget(_wrap(MoreSettingsView(
        version: '1',
        hrBroadcast: true,
        onToggleHrBroadcast: () => taps++,
      )));
      final rowOn =
          tester.widget<SetRow>(find.widgetWithText(SetRow, 'HR broadcast'));
      expect(rowOn.value, 'On');
    });

    testWidgets('shows ellipsis and disables tap while busy', (tester) async {
      _tallPhone(tester);
      var taps = 0;
      await tester.pumpWidget(_wrap(MoreSettingsView(
        version: '1',
        hrBroadcastBusy: true,
        onToggleHrBroadcast: () => taps++,
      )));
      final row =
          tester.widget<SetRow>(find.widgetWithText(SetRow, 'HR broadcast'));
      expect(row.value, '…');
      await tester.tap(find.text('HR broadcast'));
      expect(taps, 0);
    });
  });
}
