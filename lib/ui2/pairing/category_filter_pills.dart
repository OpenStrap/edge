// filter pills over a device list ("All · WHOOP · Rings · Watches ·
// Straps"). One widget, one file, so the list grouping can be swapped for
// another style (accordions, plain headers) without touching a screen.
import 'package:flutter/material.dart';

import '../../ble/adapters/_registry.dart';
import '../ui2.dart';
import 'pair_text.dart';

/// [entries] narrowed to [group]; null keeps them all.
List<BandEntry> filterByGroup(Iterable<BandEntry> entries, PairFilter? group) => [
  for (final e in entries)
    if (group == null || pairFilterOf(e.kind) == group) e,
];

class CategoryFilterPills extends StatelessWidget {
  /// The kind of every entry currently in the list (repeats are fine). Only
  /// groups that have one get a pill; they show in [PairFilter] order.
  final Iterable<DeviceKind> kinds;

  /// The chosen group; null means All. Set by a tap, listened to by the screen.
  final ValueNotifier<PairFilter?> selection;

  const CategoryFilterPills({
    super.key,
    required this.kinds,
    required this.selection,
  });

  @override
  Widget build(BuildContext c) {
    final present = {for (final k in kinds) ?pairFilterOf(k)};
    final shown = [
      for (final f in PairFilter.values)
        if (present.contains(f)) f,
    ];
    // One group (or none) has nothing to filter between.
    if (shown.length < 2) return const SizedBox.shrink();
    final l = pairL10n(c);
    return ValueListenableBuilder<PairFilter?>(
      valueListenable: selection,
      builder: (_, selected, _) => Wrap(
        spacing: S.x2,
        runSpacing: S.x2,
        children: [
          _Pill(const ValueKey('pill-all'), l.pairKindAll, selected == null,
              () => selection.value = null),
          for (final f in shown)
            _Pill(ValueKey('pill-${f.name}'), pairFilterLabel(l, f),
                selected == f, () => selection.value = f),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const _Pill(Key key, this.text, this.selected, this.onTap) : super(key: key);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? Color.alphaBlend(p.wash(C.blue), p.card) : null,
            borderRadius: R.rPill,
            border: Border.all(
                color: selected ? p.on(C.blue).withValues(alpha: .7) : p.line),
          ),
          child: Text(text,
              style: F.cap.copyWith(
                  color: selected ? p.ink : p.ink2,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
        ),
      ),
    );
  }
}
