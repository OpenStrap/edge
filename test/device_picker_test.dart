// The unified pairing screen's pure states, rendered — not read. This
// project has paid for layout faults that inspecting a widget tree misses
// more than once; see pair_sensor_test.dart's header for the precedent this
// file follows.

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart' show kPairableSensors;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

BandCandidate _cand(String id, String entryId, {String? label, int rssi = -60}) =>
    (device: BluetoothDevice.fromId(id), label: label, rssi: rssi, entryId: entryId);

Future<void> _pump(WidgetTester t, DevicePickerView view,
    {bool settle = true}) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(theme: buildTheme(Brightness.light), home: view),
  );
  // `settle: false` for any state carrying a CircularProgressIndicator — an
  // indeterminate spinner animates forever, so `pumpAndSettle` never
  // "settles" and times out. A handful of fixed frames is enough for layout
  // to land without waiting out an animation designed not to stop.
  if (settle) {
    await t.pumpAndSettle();
  } else {
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }
}

DevicePickerView _view({
  List<BandCandidate> found = const [],
  bool scanning = false,
  String? heldBack,
  String? problem,
  String? busyRemoteId,
  List<({BandEntry entry, String blurb, IconData icon})> categories = const [],
  VoidCallback? onSkip,
}) =>
    DevicePickerView(
      query: TextEditingController(),
      title: 'Connect your devices',
      subtitle: 'Bring whatever you use.',
      found: found,
      scanning: scanning,
      heldBack: heldBack,
      problem: problem,
      busyRemoteId: busyRemoteId,
      categories: categories,
      onSkip: onSkip,
    );

void main() {
  group('the nearby section names what it is', () {
    testWidgets('nothing found and not scanning is a status card, not a blank list',
        (t) async {
      await _pump(t, _view());
      expect(find.text('Nothing found yet'), findsOneWidget);
    });

    testWidgets('scanning shows a live row even with nothing found yet', (t) async {
      await _pump(t, _view(scanning: true), settle: false);
      expect(find.text('Scanning for devices nearby…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a found Oura candidate and a found HRS candidate get distinct icons',
        (t) async {
      await _pump(
          t,
          _view(found: [
            _cand('AA', 'oura', label: 'Oura Ring'),
            _cand('BB', 'ble_hrs', label: 'Polar H10'),
          ]));
      expect(find.text('Oura Ring'), findsOneWidget);
      expect(find.text('Polar H10'), findsOneWidget);
      // sensorIcon('oura') => circleDot, everything else => heartPulse — the
      // whole point of stamping `entryId` onto a mixed-type scan result.
      expect(find.byIcon(LucideIcons.circleDot), findsOneWidget);
      expect(find.byIcon(LucideIcons.heartPulse), findsOneWidget);
    });

    testWidgets('an unnamed candidate shows its remote-id tail, not a blank row',
        (t) async {
      await _pump(t, _view(found: [_cand('0A1B2C3D4E5F', 'ble_hrs')]));
      expect(find.textContaining('4E5F'), findsOneWidget);
    });

    testWidgets('the candidate mid-pair says so and the row cannot be tapped again',
        (t) async {
      await _pump(t,
          _view(found: [_cand('AA', 'ble_hrs', label: 'Strap')], busyRemoteId: 'AA'));
      expect(find.text('Pairing…'), findsOneWidget);
    });
  });

  group('the iOS gate is a status card with its own fix, not a silent scan',
      () {
    testWidgets('held back shows the reason and a search-anyway fix', (t) async {
      await _pump(t, _view(heldBack: 'Searching would hide the WHOOP sheet.'));
      expect(find.text('Searching would hide the WHOOP sheet.'), findsOneWidget);
      expect(find.text('Search anyway'), findsOneWidget);
    });

    testWidgets('held back suppresses the nearby section entirely', (t) async {
      await _pump(t, _view(heldBack: 'held back', scanning: true), settle: false);
      // Scanning is true, but the gate is checked FIRST — a scan cannot
      // actually be running while iOS is refusing to let one start.
      expect(find.text('Scanning for devices nearby…'), findsNothing);
    });
  });

  testWidgets('a scan failure is its own card, distinct from "nothing found"',
      (t) async {
    await _pump(t, _view(problem: 'Bluetooth is off.'));
    expect(find.text('That did not work'), findsOneWidget);
    expect(find.text('Bluetooth is off.'), findsOneWidget);
  });

  group('categories are plain text and a generic glyph, never a fetched brand asset',
      () {
    testWidgets('every category renders its label and blurb as plain text',
        (t) async {
      await _pump(
          t,
          _view(categories: [
            (entry: kWhoopGen4, blurb: 'WHOOP 4 or 5.', icon: LucideIcons.watch),
            (entry: kOura, blurb: 'Reads the ring directly.', icon: LucideIcons.circleDot),
          ]));
      expect(find.text(kWhoopGen4.label), findsOneWidget);
      expect(find.text('WHOOP 4 or 5.'), findsOneWidget);
      expect(find.text(kOura.label), findsOneWidget);
      // No Image/Icon.network/asset-backed logo widget anywhere on the
      // screen — every glyph here is a LucideIcons constant, compiled into
      // the app, never a runtime-fetched brand mark.
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('an empty category list (search matched nothing) shows no section',
        (t) async {
      await _pump(t, _view(categories: const []));
      expect(find.text('Browse by category'), findsNothing);
    });
  });

  testWidgets('skip is offered only when the caller gave a way out', (t) async {
    await _pump(t, _view());
    expect(find.text('Skip for now'), findsNothing);
    await _pump(t, _view(onSkip: () {}));
    expect(find.text('Skip for now'), findsOneWidget);
  });

  test('every category the picker lists has a pairing step behind it', () {
    // The category list is `kBandRegistry`; the pairing steps are
    // `kPairableSensors`. Two lists, one tap — a notify-class entry added to
    // the first and forgotten in the second is a row that navigates nowhere.
    // `_openEntry` has a guard for that (it says so rather than throwing), and
    // this is the check that makes the guard unreachable in a shipped build.
    final steps = kPairableSensors.map((s) => s.entry.id).toSet();
    for (final e in kBandRegistry.where((e) => !e.isFramed)) {
      expect(steps, contains(e.id),
          reason: '${e.id} is offered by the picker with no way to pair it');
    }
  });
}
