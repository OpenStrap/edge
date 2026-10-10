// A device paired under a family this build no longer has (its row and its
// banked data outlive the removal). It must degrade, never crash: listed as
// unsupported, no sync, no timeline candidate, and still forgettable
// (forget is pinned in hrs_link_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/ble/session_link.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';

const _removed = 'ringconn';

void main() {
  test('a removed family is unknown to the registry and to every lookup', () {
    expect(kBandRegistry.map((e) => e.id), isNot(contains(_removed)));
    expect(bandLabelFor(_removed), isNull,
        reason: 'the sources list falls back to "Not supported"');
    expect(sensorIcon(_removed), LucideIcons.heartPulse);
    expect(declaredSignals(_removed), isEmpty);
    expect(SessionLink.forId(_removed), isNull, reason: 'nothing syncs it');
  });

  testWidgets('it is never a timeline device-filter candidate', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }));
    const source = HealthSource(
      name: 'Old ring',
      kind: 'Not supported by this version',
      tier: SourceTier.phone,
      icon: Icons.circle,
      isBand: false,
      deviceId: 'ringconn-0a1b2c3d',
      family: _removed,
    );
    expect(
        candidatesFromSources(ctx, [source],
            requires: {InputSignal.hrSparse}),
        isEmpty);
  });
}
