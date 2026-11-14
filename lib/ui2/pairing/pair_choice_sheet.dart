// The confirm sheet the pairing screens share: the device, a title and a lead,
// THE table with the device's column washed, a note, one filled main button,
// an optional second choice as a text link, and "Go back". The callers differ
// only in words, so there is one sheet.
import 'package:flutter/material.dart';

import '../../ble/slot_comparison.dart';
import '../ui2.dart';
import 'pair_widgets.dart';
import 'slot_comparison_view.dart';

/// What the user picked on a [PairChoiceSheet].
enum PairChoice { primary, secondary, back }

class PairChoiceSheet extends StatelessWidget {
  /// The device's tile and its name ("WHOOP 5 · 7C21", "Oura Ring").
  final IconData deviceIcon;
  final String deviceName;

  final String title;
  final String? lead;
  final SlotComparison comparison;

  /// The column the device goes into; washed on the table.
  final DeviceSlot? focus;

  /// Icon-and-caption notes under the table.
  final List<Widget> notes;

  /// "Put it in pairing mode", above the main button; null shows none.
  final Widget? pairingMode;

  final String primaryLabel;
  final IconData? primaryIcon;

  /// The second choice, a text link under the button. Null hides it.
  final String? secondaryLabel;
  final String backLabel;

  const PairChoiceSheet({
    super.key,
    required this.deviceIcon,
    required this.deviceName,
    required this.title,
    this.lead,
    required this.comparison,
    this.focus,
    this.notes = const [],
    this.pairingMode,
    required this.primaryLabel,
    this.primaryIcon,
    this.secondaryLabel,
    required this.backLabel,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    void pop(PairChoice v) => Navigator.of(c).pop(v);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration:
                      BoxDecoration(color: p.card2, borderRadius: R.rSm),
                  child: Icon(deviceIcon, size: 16, color: p.ink2),
                ),
                const SizedBox(width: S.x2),
                Expanded(
                  child: Text(deviceName,
                      key: const ValueKey('choice-device'),
                      style: F.cap.copyWith(
                          color: p.ink2, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: S.x3),
              Text(title,
                  key: const ValueKey('choice-title'),
                  style: F.t1.copyWith(color: p.ink)),
              if (lead != null) ...[
                const SizedBox(height: S.x2),
                Text(lead!, style: F.body.copyWith(color: p.ink2)),
              ],
              const SizedBox(height: S.x4),
              SlotTable(comparison: comparison, focus: focus),
              ...notes,
              if (pairingMode != null) ...[
                const SizedBox(height: S.x5),
                pairingMode!,
              ],
              const SizedBox(height: S.x5),
              BigButton(primaryLabel,
                  key: const ValueKey('choice-primary'),
                  icon: primaryIcon,
                  onTap: () => pop(PairChoice.primary)),
              if (secondaryLabel != null)
                TextLinkButton(secondaryLabel!,
                    onTap: () => pop(PairChoice.secondary)),
              TextLinkButton(backLabel, onTap: () => pop(PairChoice.back)),
            ]),
      ),
    );
  }
}

/// Shows [sheet] from the bottom; null when dismissed without a choice.
Future<PairChoice?> showPairChoiceSheet(BuildContext c, PairChoiceSheet sheet) {
  final p = P.of(c);
  return showModalBottomSheet<PairChoice>(
    context: c,
    backgroundColor: p.card,
    isScrollControlled: true,
    // Honours Reduce Motion like every other modal sheet in ui2.
    sheetAnimationStyle: sheetMotion(c),
    // A full-height sheet must not slide under the status bar or a notch.
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => sheet,
  );
}
