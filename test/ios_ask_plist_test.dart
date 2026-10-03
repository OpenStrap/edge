// The iOS AccessorySetupKit block in Info.plist is DERIVED from kFramedBands
// plus kAskPickerSensors.
//
// Not the whole registry: ASK provisions the PRIMARY band — the one that holds
// a link and gets its flash trimmed. A sensor is declared only when it pairs
// through a picker of its own (kAskPickerSensors), because without ASK
// approval the app cannot scan for it at all (#371/#372); it is also listed
// under OSAskSensorServices so the WHOOP picker leaves it out.
//
// This is the enforcement half of tool/gen_ios_ask_plist.dart: `flutter test`
// runs on every PR, so a band added to the registry and forgotten in the plist
// fails CI. It has to fail loudly, because the symptom otherwise is invisible —
// on iOS 18+ the ASK picker is the pairing path, so an undeclared service just
// means that band never appears in the picker.
//
// Same shape as telemetry_consent_default_test.dart, which already asserts
// platform config from Dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';

import '../tool/gen_ios_ask_plist.dart';

void main() {
  final plist = File(kPlistPath).readAsStringSync();

  test('Info.plist ASK block is in sync with kFramedBands + kAskPickerSensors',
      () {
    expect(
      applyBlocks(plist, kFramedBands, kAskPickerSensors),
      plist,
      reason: 'stale — run `dart run tool/gen_ios_ask_plist.dart`',
    );
  });

  test('every framed service is declared, uppercased', () {
    for (final e in kFramedBands) {
      expect(plist, contains('<string>${e.service.toUpperCase()}</string>'));
    }
  });

  test('every ASK sensor is declared AND marked as a sensor', () {
    expect(kAskPickerSensors, isNotEmpty);
    final marked = RegExp(
      '<key>$kSensorServicesKey</key>\\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist)?.group(1);
    expect(marked, isNotNull, reason: '$kSensorServicesKey block missing');
    for (final e in kAskPickerSensors) {
      final svc = '<string>${e.service.toUpperCase()}</string>';
      expect(plist, contains(svc));
      expect(marked, contains(svc),
          reason: '${e.id} would show up in the WHOOP picker');
    }
    // A band marked as a sensor would vanish from the WHOOP picker.
    for (final e in kFramedBands) {
      expect(marked, isNot(contains(e.service.toUpperCase())));
    }
  });

  test("every ASK sensor's company id is declared, never on a descriptor", () {
    final declared = RegExp(
      '<key>$kCompanyIdsKey</key>\\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist)?.group(1);
    expect(declared, isNotNull, reason: '$kCompanyIdsKey block missing');
    for (final e in kAskPickerSensors) {
      final id = kAskSensorCompanyIds[e.id];
      if (id == null) continue;
      expect(declared, contains('<string>${companyIdString(id)}</string>'),
          reason: '${e.id}: without it the picker finds nothing');
    }
    // Setting it on the descriptor traps on iOS 27 — see kAskSensorCompanyIds.
    final swift = File('ios/Runner/AccessorySetup.swift').readAsStringSync();
    expect(swift, isNot(contains('bluetoothCompanyIdentifier =')));
  });

  test('ASK sensors are notify-class, never framed bands', () {
    for (final e in kAskPickerSensors) {
      expect(e.isFramed, isFalse, reason: e.id);
    }
  });

  test('AccessorySetup.swift keeps no second copy of the UUIDs', () {
    // The Swift reads NSAccessorySetupBluetoothServices at runtime. A literal
    // back in the source is the drift this whole thing exists to prevent.
    final swift =
        File('ios/Runner/AccessorySetup.swift').readAsStringSync().toLowerCase();
    for (final e in [...kFramedBands, ...kAskPickerSensors]) {
      expect(swift, isNot(contains(e.service.toLowerCase())));
    }
  });
}
