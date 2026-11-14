// THE table of what a device gives "Every day" and "Workouts only": a row
// per capability, a check on a tint where it sends, a muted cross where it
// does not (never a dash). The pairing sheets wash the column the device goes
// into; the device page fades the column it is not in. One widget, one file,
// so the comparison style can be swapped without touching a screen. The facts
// come from `slotComparisonFor`; this only draws.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/slot_comparison.dart';
import '../ui2.dart';
import 'pair_text.dart';

/// One table row: null in a column means that column does not send it.
typedef SlotRow = ({
  DeviceCapability capability,
  CapabilityStatus? everyDay,
  CapabilityStatus? workouts,
});

/// The rows of [c]: every row of the table ([kTableRows]), in order.
List<SlotRow> slotRowsFor(SlotComparison c) => [
  for (final k in kTableRows)
    (
      capability: k,
      everyDay: c.everyDay.sends[k],
      workouts: c.workoutsOnly.sends[k],
    ),
];

class SlotTable extends StatelessWidget {
  final SlotComparison comparison;

  /// The column the device goes into, washed in its colour (the sheets).
  final DeviceSlot? focus;

  /// The column the device is not in, faded (the device page).
  final DeviceSlot? dim;

  const SlotTable({super.key, required this.comparison, this.focus, this.dim});

  static const double colWidth = 104;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    Widget cell(DeviceSlot s, Widget child) => Container(
          key: ValueKey('slot-cell-${s.name}'),
          width: colWidth,
          alignment: Alignment.center,
          color: focus == s ? p.wash(slotColor(s), strength: .55) : null,
          child: Opacity(opacity: dim == s ? .28 : 1, child: child),
        );
    Widget line(Widget label, Widget a, Widget b,
            {Key? key, bool top = true, double v = S.x3}) =>
        Container(
          key: key,
          decoration: BoxDecoration(
              border: top ? Border(top: BorderSide(color: p.line)) : null),
          child: IntrinsicHeight(
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(S.x4, v, S.x2, v),
                      child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: label),
                    ),
                  ),
                  cell(DeviceSlot.everyDay, a),
                  cell(DeviceSlot.workoutsOnly, b),
                ]),
          ),
        );
    Widget head(DeviceSlot s) => Padding(
          // Room above the icons, so they do not sit on the table's edge.
          padding: const EdgeInsets.fromLTRB(S.x1, S.x3, S.x1, S.x2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(slotIcon(s), size: 16, color: p.on(slotColor(s))),
            const SizedBox(height: 3),
            Text(slotLabel(l, s),
                key: ValueKey('slot-head-${s.name}'),
                textAlign: TextAlign.center,
                style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w700)),
          ]),
        );
    Widget row(SlotRow r) {
      final k = r.capability.name;
      final reasons = <String>[];
      for (final (slot, status) in [
        (DeviceSlot.everyDay, r.everyDay),
        (DeviceSlot.workoutsOnly, r.workouts),
      ]) {
        final reason = status == null ? null : capabilityReason(l, status);
        if (reason != null) {
          reasons.add(l.slotColumnReason(slotLabel(l, slot), reason));
        }
      }
      return line(
        key: ValueKey('slot-row-$k'),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(capabilityLabel(l, r.capability),
              style: F.body.copyWith(color: p.ink)),
          for (final reason in reasons)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(reason, style: F.cap.copyWith(color: p.ink3)),
            ),
        ]),
        SlotMark(r.everyDay != null, capability: r.capability,
            slot: DeviceSlot.everyDay, reason: r.everyDay?.kind == CapabilityKind.conditional
                ? capabilityReason(l, r.everyDay!) : null, key: ValueKey('slot-everyDay-$k')),
        SlotMark(r.workouts != null, capability: r.capability,
            slot: DeviceSlot.workoutsOnly, reason: r.workouts?.kind == CapabilityKind.conditional
                ? capabilityReason(l, r.workouts!) : null, key: ValueKey('slot-workoutsOnly-$k')),
      );
    }

    final rows = slotRowsFor(comparison);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
          color: p.card2, borderRadius: R.rLg, border: Border.all(color: p.line)),
      child: Column(children: [
        line(const SizedBox.shrink(), head(DeviceSlot.everyDay),
            head(DeviceSlot.workoutsOnly),
            top: false, v: S.x2),
        // The workout rows name themselves ("… during workouts"); no group
        // row.
        for (final r in rows) row(r),
      ]),
    );
  }
}

/// A check on a green tint where the column sends the row, a muted cross where
/// it does not. Announces the capability, column and status to a screen reader.
class SlotMark extends StatelessWidget {
  final bool sends;
  final DeviceCapability capability;
  final DeviceSlot slot;
  final String? reason;
  const SlotMark(this.sends,
      {super.key, required this.capability, required this.slot, this.reason});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final status = sends ? l.slotSendsHeading : l.slotDoesntSendHeading;
    return Semantics(
      label: l.slotCapabilityStatus(capabilityLabel(l, capability),
          slotLabel(l, slot), reason == null ? status : '$status. $reason'),
      excludeSemantics: true,
      child: sends
          ? Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration:
                  BoxDecoration(color: p.wash(C.green), shape: BoxShape.circle),
              child: Icon(LucideIcons.check, size: 15, color: p.on(C.green)),
            )
          : SizedBox(
              width: 24,
              height: 24,
              child: Icon(LucideIcons.x, size: 16, color: p.ink3)),
    );
  }
}

