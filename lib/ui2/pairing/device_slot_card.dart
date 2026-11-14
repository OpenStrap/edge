// a paired device's own card, said plainly: where it fits ("Every day" or
// "Workouts only"), and THE table the pairing sheets show, with the column it
// is not in faded. The note says which switch it waits for; the switch itself
// sits right under the card (DeviceUseSwitch).
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/slot_comparison.dart';
import '../ui2.dart';
import 'pair_text.dart';
import 'pair_widgets.dart';
import 'slot_comparison_view.dart';

/// The column [e] goes into when it is paired beside (or instead of) the
/// band: a ring or a watch fills every day, a workout sensor workouts only.
/// Null for a WHOOP (its own page), a Coros watch or a scale.
DeviceSlot? pairedDeviceSlot(BandEntry e) =>
    e.canBeMainDevice ? null : slotComparisonFor(e).slot;

class DeviceSlotCard extends StatelessWidget {
  final BandEntry entry;
  final DeviceSlot slot;

  const DeviceSlotCard({super.key, required this.entry, required this.slot});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final other = slot == DeviceSlot.everyDay
        ? DeviceSlot.workoutsOnly
        : DeviceSlot.everyDay;
    return Column(
      key: const ValueKey('device-slot-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A Wrap, not a Row: at 2x text the chip drops under the heading
        // instead of overflowing beside it.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: S.x2,
          runSpacing: S.x2,
          children: [
            Text(l.pairWhatItSends, style: F.head.copyWith(color: p.ink)),
            slotPill(l, slot, key: const ValueKey('device-slot-pill')),
          ],
        ),
        const SizedBox(height: S.x3),
        SlotTable(comparison: slotComparisonFor(entry), dim: other),
        slot == DeviceSlot.everyDay
            ? PairNote(LucideIcons.flaskConical, l.pairWearableCardNote,
                color: C.orange)
            : PairNote(LucideIcons.info, l.pairStrapNote),
      ],
    );
  }
}
