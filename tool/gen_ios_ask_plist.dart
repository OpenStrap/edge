// Info.plist's AccessorySetupKit block is DERIVED from the band registry —
// from [kFramedBands] plus [kAskPickerSensors], not the whole of it. ASK
// provisions the PRIMARY band, the one that holds a link and gets its flash
// trimmed. A notify-only sensor was assumed to need no ASK descriptor because
// it is connected straight from its stored remote id — but with
// `NSAccessorySetupKitSupports` declared the app has no standard Bluetooth
// authorization, so a sensor the user never approved in a picker cannot even
// be scanned (#371/#372). The sensors in [kAskPickerSensors] are declared too,
// and ALSO listed under [kSensorServicesKey] so the WHOOP picker leaves them
// out; each gets a picker of its own, filtered to its service.
//
// Apple requires every criterion an ASK discovery descriptor matches on to be
// declared in Info.plist under NSAccessorySetupBluetoothServices. On iOS 18+
// that picker IS our pairing path, so a band missing from that array cannot be
// paired on iPhone at all — and per TN3115 note 5 it also gives up the iOS 26
// relaunch-after-force-quit / Control-Centre-toggle case. A hand-maintained
// second copy of `kBandRegistry` is exactly the drift nobody notices until a
// user's band silently stops pairing.
//
//   dart run tool/gen_ios_ask_plist.dart           # rewrite the block
//   dart run tool/gen_ios_ask_plist.dart --check   # verify, exit 1 on drift
//
// The check is also a unit test (`test/ios_ask_plist_test.dart`), which is
// what actually enforces it: `flutter test` runs on every PR, so drift fails
// CI loudly. Deliberately NOT an Xcode script phase — the registry is a Dart
// `const`, so only the Dart VM can evaluate it, and a phase that regenerates a
// tracked source file mid-build is the fail-open mode we are trying to avoid
// (a stale plist that still builds).
//
// Both keys must already exist in the plist; this rewrites their bodies and
// never invents structure.

import 'dart:io';

import 'package:openstrap_edge/ble/adapters/_registry.dart';

const String kPlistPath = 'ios/Runner/Info.plist';

/// Apple's required list of service UUIDs the ASK picker may match on.
const String kServicesKey = 'NSAccessorySetupBluetoothServices';

/// Our own key: service UUID -> picker row label. Cosmetic only — the Swift
/// falls back to a generic name — so a stale label degrades the picker text
/// rather than hiding a band.
const String kLabelsKey = 'OSBandLabels';

/// Our own key: the declared services that belong to a SENSOR rather than a
/// band. `AccessorySetup.swift` subtracts these from the band picker, so
/// declaring a ring's service cannot put a ring in the WHOOP picker.
const String kSensorServicesKey = 'OSAskSensorServices';

/// Apple's list of Bluetooth company identifiers the ASK picker may match on —
/// declared for [kAskSensorCompanyIds] only, never put on a descriptor (see
/// that map's doc for both halves of why).
const String kCompanyIdsKey = 'NSAccessorySetupBluetoothCompanyIdentifiers';

/// One company identifier as declared: `0x` and four uppercase hex digits.
String companyIdString(int id) =>
    '0x${id.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// Extra ASK match criterion NOT tied to any one [BandEntry]: the 16-bit SIG
/// member UUID `0xFD4B`, a fallback for gen5's 128-bit vendor UUID being
/// hidden in the scan-response overflow area (see AccessorySetup.swift's
/// `whoopMemberUUID16`). Apple requires every descriptor criterion used in
/// Swift to be declared here too, so this stays a fixed, always-appended
/// tail rather than something a band entry could ever express — it is a
/// platform-encoding fact, not a band.
const String kFd4bMemberUuid16 = 'FD4B';

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _servicesBody(List<BandEntry> registry) {
  final buf = StringBuffer();
  for (final e in registry) {
    buf.writeln('\t\t<string>${plistUuid(e.service)}</string>');
  }
  buf
    ..writeln('\t\t<!-- 16-bit SIG member UUID. Distinct from the 128-bit '
        'vendor service')
    ..writeln('\t\t     above, and NOT the Bluetooth-base expansion')
    ..writeln('\t\t     0000FD4B-0000-1000-8000-00805F9B34FB (no band '
        'advertises that).')
    ..writeln('\t\t     A 128-bit UUID often does not fit the 31-byte '
        'advertisement. -->')
    ..writeln('\t\t<string>$kFd4bMemberUuid16</string>');
  return buf.toString();
}

String _sensorServicesBody(List<BandEntry> sensors) => sensors
    .map((e) => '\t\t<string>${plistUuid(e.service)}</string>\n')
    .join();

String _companyIdsBody(List<BandEntry> sensors) => [
      for (final e in sensors)
        if (kAskSensorCompanyIds[e.id] case final id?)
          '\t\t<string>${companyIdString(id)}</string>\n',
    ].join();

String _labelsBody(List<BandEntry> registry) => registry
    .map((e) => '\t\t<key>${plistUuid(e.service)}</key>\n'
        '\t\t<string>${_esc(e.label)}</string>\n')
    .join();

String _replaceBody(String plist, String key, String tag, String body) {
  final re = RegExp(
    '(\\t<key>$key</key>\\n\\t<$tag>\\n).*?(\\t</$tag>\\n)',
    dotAll: true,
  );
  final m = re.firstMatch(plist);
  if (m == null) {
    throw StateError(
        '$kPlistPath has no <$tag> block for <key>$key</key> — add one '
        '(with at least one child) before running this.');
  }
  return plist.replaceRange(m.start, m.end, '${m[1]}$body${m[2]}');
}

/// [plist] with every generated block rebuilt from [bands] and [sensors].
String applyBlocks(
  String plist,
  List<BandEntry> bands, [
  List<BandEntry> sensors = const [],
]) {
  final all = [...bands, ...sensors];
  var out = _replaceBody(plist, kServicesKey, 'array', _servicesBody(all));
  out = _replaceBody(out, kLabelsKey, 'dict', _labelsBody(all));
  out = _replaceBody(
      out, kSensorServicesKey, 'array', _sensorServicesBody(sensors));
  out = _replaceBody(out, kCompanyIdsKey, 'array', _companyIdsBody(sensors));
  return out;
}

void main(List<String> args) {
  final file = File(kPlistPath);
  if (!file.existsSync()) {
    stderr.writeln('$kPlistPath not found — run from the edge/ package root.');
    exit(2);
  }
  final current = file.readAsStringSync();
  final wanted = applyBlocks(current, kFramedBands, kAskPickerSensors);
  if (current == wanted) {
    stdout.writeln('$kPlistPath is in sync with kFramedBands + '
        'kAskPickerSensors.');
    return;
  }
  if (args.contains('--check')) {
    final all = [...kFramedBands, ...kAskPickerSensors];
    stderr.writeln('$kPlistPath is STALE. Expected:\n'
        '\t<key>$kServicesKey</key>\n\t<array>\n${_servicesBody(all)}'
        '\t</array>\n'
        '\t<key>$kLabelsKey</key>\n\t<dict>\n${_labelsBody(all)}'
        '\t</dict>\n'
        '\t<key>$kSensorServicesKey</key>\n\t<array>\n'
        '${_sensorServicesBody(kAskPickerSensors)}\t</array>\n'
        '\t<key>$kCompanyIdsKey</key>\n\t<array>\n'
        '${_companyIdsBody(kAskPickerSensors)}\t</array>\n'
        'Run: dart run tool/gen_ios_ask_plist.dart');
    exit(1);
  }
  file.writeAsStringSync(wanted);
  stdout.writeln('$kPlistPath updated from kFramedBands + kAskPickerSensors '
      '(${kFramedBands.length} band(s), ${kAskPickerSensors.length} '
      'sensor(s)).');
}
