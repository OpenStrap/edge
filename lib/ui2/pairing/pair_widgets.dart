// Small pieces the pairing screens share: a numbered step, a text link and a
// tappable icon row. Kept in one file so the screens read
// alike; none of them knows anything about pairing itself.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui2.dart';

/// A numbered step: a round badge and the instruction beside it.
class PairStepRow extends StatelessWidget {
  final int number;
  final String text;

  /// The small one for sheets and cards: a smaller badge, caption text.
  final bool compact;
  const PairStepRow(this.number, this.text, {super.key, this.compact = false});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final badge = compact ? 22.0 : 28.0;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? S.x1 : S.x2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: badge,
          height: badge,
          alignment: Alignment.center,
          decoration:
              BoxDecoration(color: p.wash(C.blue), shape: BoxShape.circle),
          child: Text('$number',
              style: F.cap
                  .copyWith(color: p.on(C.blue), fontWeight: FontWeight.w700)),
        ),
        SizedBox(width: compact ? S.x2 : S.x3),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: compact ? 2 : 3),
            child: Text(text,
                style: (compact ? F.cap.copyWith(color: p.ink2) : F.body)
                    .copyWith(color: compact ? p.ink2 : p.ink)),
          ),
        ),
      ]),
    );
  }
}

/// Centred blue text that acts as a link.
class TextLinkButton extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  const TextLinkButton(this.text, {super.key, this.onTap});

  @override
  Widget build(BuildContext c) => Pressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x3),
          child: Center(
            child: Text(text,
                textAlign: TextAlign.center,
                style: F.body.copyWith(
                    color: P.of(c).on(C.blue), fontWeight: FontWeight.w600)),
          ),
        ),
      );
}

/// A card row: an icon tile, a title with one line beneath, a trailing icon.
class ChoiceRow extends StatelessWidget {
  final IconData icon, trailing;
  final String title, sub;
  final VoidCallback? onTap;
  const ChoiceRow(this.icon, this.title, this.sub,
      {super.key, this.trailing = LucideIcons.externalLink, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(S.x3),
        decoration: BoxDecoration(
            color: p.card2,
            borderRadius: R.rLg,
            border: Border.all(color: p.line)),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: p.wash(C.blue), borderRadius: R.rMd),
            child: Icon(icon, size: 22, color: p.on(C.blue)),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: F.body
                          .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, style: F.cap.copyWith(color: p.ink2)),
                ]),
          ),
          const SizedBox(width: S.x2),
          Icon(trailing, size: 18, color: p.ink3),
        ]),
      ),
    );
  }
}

/// A caption with its icon, under pairing content: grey by default, or in [color]'s
/// ink (the orange "Experimental" note).
class PairNote extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const PairNote(this.icon, this.text, {super.key, this.color});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = color == null ? p.ink2 : p.on(color!);
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 15, color: ink)),
        const SizedBox(width: S.x2),
        Expanded(child: Text(text, style: F.cap.copyWith(color: ink))),
      ]),
    );
  }
}
