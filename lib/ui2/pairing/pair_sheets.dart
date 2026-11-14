// The confirm sheets of the "Add a device" flow, all built on one
// PairChoiceSheet with THE table:
//  - a WHOOP: "Pair it as my band" (or, with a band already paired, "Unpair
//    <old> and pair this one" and its one confirm), and "Use it for workouts
//    only";
//  - a ring or a watch: "Every day" washed, the experimental note, "Pair (it)";
//  - a heart-rate strap with no band paired: "Workouts only" washed.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/slot_comparison.dart';
import '../../l10n/display_text.dart';
import '../ui2.dart';
import 'pair_choice_sheet.dart';
import 'pair_text.dart';
import 'pair_widgets.dart';
import 'reset_steps_view.dart' show PairingModeSection;

/// What the user picked on the band-found sheet. Going back is null.
enum BandSheetChoice {
  /// Pair it as the main band (no band paired yet).
  asBand,

  /// Pair the replacement before retiring the current main band. Only
  /// offered with a band paired; the caller confirms once before acting.
  replaceBand,

  /// Pair it as itself, not as the main band: a WHOOP kept for workouts only
  /// (read as a heart-rate sensor), or a ring or a watch.
  asSensor,
}

/// "This is a WHOOP band" (or a ring, or a watch). [afterConnect] is the same
/// sheet after the connect found the band (nothing was saved), with the
/// sentence that says so. [modelKnown] false: only the name matched, so the
/// sheet names no model. [deviceName] is the advertised name, when the scan
/// heard one. [mainBandName] names the band paired now ([hasMainBand]).
Future<BandSheetChoice?> showBandFoundSheet(
  BuildContext c, {
  required BandEntry band,
  required bool hasMainBand,
  String? mainBandName,
  bool afterConnect = false,
  bool modelKnown = true,
  String? deviceName,
}) async {
  final l = pairL10n(c);
  final label = modelKnown ? uiText(c, band.label) : 'WHOOP';
  final cmp = slotComparisonFor(band, modelKnown: modelKnown);
  final icon = deviceKindIcon(band.kind);
  final name = deviceName ?? label;
  if (!band.canBeMainDevice) {
    // A ring or a watch: it fills every day as the active wearable, behind
    // its own switch; a Coros watch fits neither column.
    final wearable = cmp.slot == DeviceSlot.everyDay;
    final choice = await showPairChoiceSheet(
      c,
      PairChoiceSheet(
        deviceIcon: icon,
        deviceName: name,
        title: deviceSheetTitle(l, band),
        lead: afterConnect
            ? l.pairIdentifiedBody(label)
            : wearable
                ? band.id == kPebble.id
                    ? l.pairWearableLeadPebble
                    : l.pairWearableLead
                : null,
        comparison: cmp,
        focus: cmp.slot,
        notes: [
          wearable
              ? PairNote(LucideIcons.flaskConical, l.pairWearableNote,
                  color: C.orange)
              : PairNote(LucideIcons.info, l.pairSensorExplainerCoros),
        ],
        pairingMode: PairingModeSection(entry: band),
        primaryLabel: l.pairDeviceNamed(label),
        primaryIcon: LucideIcons.bluetooth,
        backLabel: l.pairGoBack,
      ),
    );
    return choice == PairChoice.primary ? BandSheetChoice.asSensor : null;
  }
  final current = mainBandName ?? l.pairCurrentBandFallback;
  final choice = await showPairChoiceSheet(
    c,
    PairChoiceSheet(
      deviceIcon: icon,
      deviceName: name,
      title: l.pairThisIsWhoop,
      lead: afterConnect
          ? l.pairIdentifiedBody(label)
          : hasMainBand
              ? l.pairBandFoundBodyHasBand
              : l.pairBandFoundBody,
      comparison: cmp,
      focus: DeviceSlot.everyDay,
      notes: [
        if (hasMainBand) PairNote(LucideIcons.watch, l.pairBandNow(current)),
      ],
      // A WHOOP heard by name only gets no model's steps.
      pairingMode: modelKnown ? PairingModeSection(entry: band) : null,
      primaryLabel:
          hasMainBand ? l.pairReplaceBand(current) : l.pairAsMyBand,
      primaryIcon:
          hasMainBand ? LucideIcons.arrowLeftRight : LucideIcons.watch,
      secondaryLabel: l.pairUseForWorkouts,
      backLabel: l.pairGoBack,
    ),
  );
  return switch (choice) {
    PairChoice.primary =>
      hasMainBand ? BandSheetChoice.replaceBand : BandSheetChoice.asBand,
    PairChoice.secondary => BandSheetChoice.asSensor,
    _ => null,
  };
}

/// Confirm replacement while preserving the old pairing on failed setup.
/// True only on the explicit yes.
Future<bool> showReplaceBandConfirm(BuildContext c, {String? mainBandName}) async {
  final l = pairL10n(c);
  final name = mainBandName ?? l.pairCurrentBandFallback;
  final ok = await showDialog<bool>(
    context: c,
    builder: (d) {
      final p = P.of(d);
      return Dialog(
        backgroundColor: p.card,
        insetPadding: const EdgeInsets.symmetric(horizontal: S.x6),
        shape: RoundedRectangleBorder(
            borderRadius: R.rXl, side: BorderSide(color: p.line)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(S.x5, S.x5, S.x5, S.x2),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(LucideIcons.arrowLeftRight, size: 24, color: p.ink2),
                const SizedBox(height: S.x3),
                Text(l.pairReplaceConfirmTitle(name),
                    key: const ValueKey('replace-confirm-title'),
                    style: F.t2.copyWith(color: p.ink)),
                const SizedBox(height: S.x2),
                Text(l.pairReplaceConfirmBody,
                    style: F.body.copyWith(color: p.ink2)),
                const SizedBox(height: S.x5),
                BigButton(l.pairReplaceConfirmYes,
                    key: const ValueKey('replace-confirm-yes'),
                    onTap: () => Navigator.of(d).pop(true)),
                TextLinkButton(l.actionCancel,
                    onTap: () => Navigator.of(d).pop(false)),
              ]),
        ),
      );
    },
  );
  return ok == true;
}

/// "This is a heart-rate strap": "Workouts only" washed, the switch note and
/// "Pair (it)". True when the user chose to go ahead. [deviceName] is the
/// advertised name, when the scan heard one.
Future<bool> showStrapSheet(BuildContext c,
    {required BandEntry sensor, String? deviceName}) async {
  final l = pairL10n(c);
  final label = uiText(c, sensor.label);
  final cmp = slotComparisonFor(sensor);
  final choice = await showPairChoiceSheet(
    c,
    PairChoiceSheet(
      deviceIcon: deviceKindIcon(sensor.kind),
      deviceName: deviceName ?? label,
      title: deviceSheetTitle(l, sensor),
      lead: l.pairStrapLead,
      comparison: cmp,
      focus: DeviceSlot.workoutsOnly,
      notes: [PairNote(LucideIcons.info, l.pairStrapNote)],
      pairingMode: PairingModeSection(entry: sensor),
      primaryLabel: l.pairDeviceNamed(label),
      primaryIcon: LucideIcons.bluetooth,
      backLabel: l.pairGoBack,
    ),
  );
  return choice == PairChoice.primary;
}
