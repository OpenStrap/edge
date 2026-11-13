// The Apple Watch reads only what ios/WatchBridge.swift copies out of the App
// Group, and that copy is a hand-written key list in Swift. Before the recovery
// ring and the held-over reason were on it, every morning before the night
// finalized (and every night of a new user's calibration) the phone said
// "68 · Finishing up" or "Calibrating 2 of 4 nights" while the wrist said a
// bare "Not scored": `readiness` is -1 for all of those, and the keys that tell
// them apart were dropped before WCSession.
//
// Same shape as ios_ask_plist_test.dart: platform config asserted from Dart so
// a key added to WidgetService.push() and forgotten on the watch fails CI.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/widget/widget_service.dart';

void main() {
  final bridge = File('ios/WatchBridge.swift').readAsStringSync();
  final metrics =
      File('ios/OpenStrapWatch Watch App/WatchMetrics.swift').readAsStringSync();

  // Every quoted string inside the four `private static let …Keys = [...]`.
  Set<String> mirrored() {
    final out = <String>{};
    final lists = RegExp(r'static let \w+Keys = \[([^\]]*)\]', multiLine: true);
    for (final m in lists.allMatches(bridge)) {
      out.addAll(RegExp(r'"([^"]+)"').allMatches(m.group(1)!).map((e) => e.group(1)!));
    }
    return out;
  }

  final watchNeeds = [
    'readiness',
    'readiness_tier',
    'readiness_band',
    'overnight_why',
    for (final k in WidgetService.fingerprintKeyOrder)
      if (k.startsWith('ring_recovery_')) k,
  ];

  test('the watch bridge mirrors the recovery ring and held-over reason', () {
    expect(watchNeeds.where((k) => k.startsWith('ring_recovery_')), hasLength(5));
    final keys = mirrored();
    for (final k in watchNeeds) {
      expect(keys, contains(k), reason: '$k is written for the widgets but '
          'never reaches the watch');
    }
  });

  test('the watch reads every key it is sent for the readiness hero', () {
    for (final k in watchNeeds) {
      expect(metrics, contains('forKey: "$k"'),
          reason: 'WatchMetrics.load() never reads $k');
    }
  });
}
