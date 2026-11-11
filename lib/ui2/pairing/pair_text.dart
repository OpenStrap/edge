// The words the pairing screens print for registry and slot-comparison data,
// in the user's language. Registry and compute code store l10n KEYS; this is
// the one place a key becomes text (a generated class has no lookup by name).
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';

/// Localizations for [c]; English when none are mounted (a bare test widget),
/// the same fallback the rest of the pairing copy has.
AppLocalizations pairL10n(BuildContext c) =>
    AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));

/// The sheet title for [e]: "This is a WHOOP band", "This is a ring", ….
String deviceSheetTitle(AppLocalizations l, BandEntry e) => switch (e.kind) {
  _ when e.canBeMainDevice => l.pairThisIsWhoop,
  DeviceKind.strap => l.pairThisIsWhoop,
  DeviceKind.ring => l.pairThisIsRing,
  DeviceKind.watch => l.pairThisIsWatch,
  DeviceKind.band => l.pairThisIsFitnessBand,
  DeviceKind.chestStrap => l.pairThisIsStrap,
  DeviceKind.armband ||
  DeviceKind.scale ||
  DeviceKind.thermometer ||
  DeviceKind.other =>
    l.pairThisIsSensor,
};

IconData deviceKindIcon(DeviceKind k) => switch (k) {
  DeviceKind.ring => LucideIcons.circleDot,
  DeviceKind.strap || DeviceKind.watch || DeviceKind.band => LucideIcons.watch,
  DeviceKind.scale => LucideIcons.scale,
  DeviceKind.thermometer => LucideIcons.thermometer,
  DeviceKind.chestStrap || DeviceKind.armband || DeviceKind.other =>
    LucideIcons.heartPulse,
};
