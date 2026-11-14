// The words the pairing screens print for registry and slot-comparison data,
// in the user's language. Registry and compute code store l10n KEYS; this is
// the one place a key becomes text (a generated class has no lookup by name).
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/slot_comparison.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';

/// Localizations for [c]; English when none are mounted (a bare test widget),
/// the same fallback the rest of the pairing copy has.
AppLocalizations pairL10n(BuildContext c) =>
    AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));

String capabilityLabel(AppLocalizations l, DeviceCapability c) => switch (c) {
  DeviceCapability.sleep => l.capLabelSleep,
  DeviceCapability.recovery => l.capLabelRecovery,
  DeviceCapability.strain => l.capLabelStrain,
  DeviceCapability.heartRate => l.capLabelHeartRate,
  DeviceCapability.hrv => l.capLabelHrv,
  DeviceCapability.respiration => l.capLabelRespiration,
  DeviceCapability.skinTemperature => l.capLabelSkinTemperature,
  DeviceCapability.steps => l.capLabelSteps,
  DeviceCapability.bloodOxygen => l.capLabelBloodOxygen,
  DeviceCapability.workoutHeartRate => l.capLabelWorkoutHeartRate,
  DeviceCapability.workoutBeatToBeat => l.capLabelWorkoutBeatToBeat,
};

/// The one-line caption under a capability, or null when it has none.
String? capabilityReason(AppLocalizations l, CapabilityStatus s) =>
    switch (s.kind) {
      CapabilityKind.native => null,
      CapabilityKind.vendorReported => l.capVendorReported,
      CapabilityKind.conditional => switch (s.reasonKey) {
        kReasonSkinTempNights => l.capReasonSkinTempNights,
        kReasonSkinTempProvisional => l.capReasonSkinTempProvisional,
        kReasonEstimated => l.capReasonEstimated,
        kReasonEarly => l.capReasonEarly,
        kReasonFirstNights => l.capReasonFirstNights,
        kReasonOwnStagesRing => l.capReasonOwnStagesRing,
        kReasonOwnStages => l.capReasonOwnStages,
        kReasonLiveSessions => l.capReasonLiveSessions,
        kReasonUnconfirmed => l.capReasonUnconfirmed,
        kReasonPebble2Only => l.capReasonPebble2Only,
        kReasonPebble2OnlyEstimated => l.capReasonPebble2OnlyEstimated,
        _ => null,
      },
    };

/// The column's name: "Every day" or "Workouts only".
String slotLabel(AppLocalizations l, DeviceSlot s) => switch (s) {
  DeviceSlot.everyDay => l.slotEveryDay,
  DeviceSlot.workoutsOnly => l.slotWorkoutsOnly,
};

/// Each column's colour and icon, the same on the table, the chips and the
/// device card.
Color slotColor(DeviceSlot s) => switch (s) {
  DeviceSlot.everyDay => C.teal,
  DeviceSlot.workoutsOnly => C.purple,
};

IconData slotIcon(DeviceSlot s) => switch (s) {
  DeviceSlot.everyDay => LucideIcons.sun,
  DeviceSlot.workoutsOnly => LucideIcons.dumbbell,
};

/// The chip that says where a device fits.
Widget slotPill(AppLocalizations l, DeviceSlot s, {Key? key}) =>
    Pill(slotLabel(l, s), slotColor(s), icon: slotIcon(s), key: key);

/// The filter pills' groups: what the user would call the device.
/// A WHOOP is its own group; a Mi Band sits with the watches. Scales and
/// thermometers have no group and show under All only.
enum PairFilter { whoop, rings, watches, straps }

PairFilter? pairFilterOf(DeviceKind k) => switch (k) {
  DeviceKind.strap => PairFilter.whoop,
  DeviceKind.ring => PairFilter.rings,
  DeviceKind.watch || DeviceKind.band => PairFilter.watches,
  DeviceKind.chestStrap || DeviceKind.armband => PairFilter.straps,
  DeviceKind.scale || DeviceKind.thermometer || DeviceKind.other => null,
};

String pairFilterLabel(AppLocalizations l, PairFilter f) => switch (f) {
  PairFilter.whoop => 'WHOOP',
  PairFilter.rings => l.pairKindRing,
  PairFilter.watches => l.pairKindWatch,
  PairFilter.straps => l.pairKindStrap,
};

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
