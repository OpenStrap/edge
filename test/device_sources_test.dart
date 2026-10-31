// THE SOURCES SCREEN, once a sensor can be paired.
//
// What is pinned here is the set of claims the screen makes ABOUT a paired
// sensor, because every one of them was true of the band and is false of a
// strap:
//
//   * a sensor is not a band. `isBand` gates the "No band is paired" card, the
//     rename/find/battery controls, and `unpair()`. A strap satisfying it
//     would have taken that card off the screen of someone whose sleep,
//     recovery and temperature are all still abstaining — and pointed a
//     chest strap's Forget button at the WHOOP.
//   * EXPERIMENTAL has to reach it. The label exists for exactly the bands
//     nobody here has held, and it used to be gated on `isBand`, which is the
//     one flag a sensor does not have.
//   * "Reporting steps" is the phone's sentence. A sensor whose tier cannot be
//     named falls back to the phone's rung, and the state line must not
//     inherit the phone's words with it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

HealthSource _sensor({String? tier = 'beatToBeat', bool connected = false}) =>
    HealthSource(
      name: 'Polar H10',
      kind: 'Bluetooth heart rate sensor',
      tier: tierNamed(tier) ?? SourceTier.phone,
      icon: Icons.favorite,
      connected: connected,
      isBand: false,
      deviceId: 'ble_hrs-0a1b2c3d',
      family: 'ble_hrs',
    );

void main() {
  test('a paired sensor is experimental — the label is not gated on isBand',
      () {
    expect(_sensor().experimental, isTrue);
    // The phone has no family and must not pick the label up.
    expect(
      const HealthSource(
        name: 'This phone',
        kind: 'Motion coprocessor',
        tier: SourceTier.phone,
        icon: Icons.phone_android,
      ).experimental,
      isFalse,
    );
  });

  test('a sensor is never described in the phone\'s words', () {
    // Its own state line, whatever rung it landed on.
    expect(sourceState(_sensor()), 'Waiting for a workout');
    expect(sourceState(_sensor(connected: true)), 'Streaming beats');
    // The case that made this necessary: an unnameable tier falls back to the
    // phone's rung, and used to inherit "No steps arriving" with it.
    final unknown = _sensor(tier: 'someFutureRung');
    expect(unknown.tier, SourceTier.phone);
    expect(sourceState(unknown), 'Waiting for a workout');
  });

  test('tierNamed refuses a rung this build does not have', () {
    expect(tierNamed('beatToBeat'), SourceTier.beatToBeat);
    expect(tierNamed(null), isNull);
    expect(tierNamed(''), isNull);
    expect(tierNamed('someFutureRung'), isNull);
  });

  testWidgets('the tier-1 rung is drawn even when empty, now that it is '
      'reachable', (t) async {
    // Tall surface: the ladder sits at the foot of a ListView, and an
    // offscreen row is simply not built.
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MyDevicesView(sources: const [], onAddSensor: () {}),
    ));
    await t.pumpAndSettle();
    expect(find.text('Add a sensor'), findsOneWidget);
    const t1 = SourceTier.beatToBeat;
    final rung = find.text('Tier ${t1.rank} · ${t1.label}');
    await t.scrollUntilVisible(rung, 300, scrollable: find.byType(Scrollable).first);
    expect(rung, findsOneWidget);
    // Empty, and saying so — the rung is an invitation now, not a dead end.
    expect(find.text('Nothing here yet'), findsWidgets);
  });

  testWidgets('a paired strap does not satisfy "a band is paired"', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MyDevicesView(sources: [_sensor()], onPair: () {}, onAddSensor: () {}),
    ));
    await t.pumpAndSettle();
    // The card that offers to pair a BAND is still there, because one is not.
    expect(find.text('Pair a band'), findsOneWidget);
    expect(find.text('Polar H10'), findsOneWidget);
  });

  group('an open sensor page rereads its row', () {
    const snapshot = HealthSource(
      name: 'Colmi R02',
      kind: 'ring',
      tier: SourceTier.phone,
      icon: Icons.circle,
      connected: true,
      batteryPct: 40,
      deviceId: 'colmi-1',
      family: 'colmi',
    );

    test('a sync that rewrote the row shows on the page', () {
      final synced = DateTime(2026, 10, 17, 9, 30);
      final s = refreshedSensorSource(snapshot, [
        {'id': 'other', 'battery_pct': 5, 'last_seen': 1},
        {
          'id': 'colmi-1',
          'battery_pct': 88,
          'last_seen': synced.millisecondsSinceEpoch ~/ 1000,
        },
      ]);
      expect(s.batteryPct, 88);
      expect(s.lastData, synced);
      // Not row columns — kept as the page had them.
      expect(s.connected, isTrue);
      expect(s.name, 'Colmi R02');
      expect(s.family, 'colmi');
    });

    test('a forgotten row leaves the page as it was', () {
      final s = refreshedSensorSource(snapshot, const []);
      expect(s.batteryPct, 40);
    });

    test('the band is never rewritten from a sensor row', () {
      const band = HealthSource(
          name: 'WHOOP', kind: 'band', tier: null, icon: Icons.watch,
          isBand: true, batteryPct: 70);
      final s = refreshedSensorSource(band, [
        {'id': '', 'battery_pct': 1, 'last_seen': 1},
      ]);
      expect(identical(s, band), isTrue);
    });
  });
}
