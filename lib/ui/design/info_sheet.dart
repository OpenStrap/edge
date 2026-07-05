// InfoSheet — where explanatory text LIVES in the numbers-first design. The
// main view shows the number; the "what is this / how it's made / what to do"
// copy opens from an (i) tap (see [InfoDot]) or any tap-through.
//
//   showInfoSheet(context,
//     title: 'HRV (RMSSD)',
//     body: 'Beat-to-beat variability from tonight's RR intervals…',
//     bullets: ['Higher than your baseline is good', …],
//     methodNote: 'Lipponen–Tarvainen corrected RR • 5-min windows');

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';

class InfoSheet extends StatelessWidget {
  final String title;
  final String? body;

  /// Optional short bullet points under the body.
  final List<String> bullets;

  /// Optional method/source line — the honesty footer ("how it's computed").
  final String? methodNote;

  /// Optional honesty tag (est. / beta / rel.) shown beside the title.
  final Widget? tag;

  const InfoSheet({
    super.key,
    required this.title,
    this.body,
    this.bullets = const [],
    this.methodNote,
    this.tag,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Row(
        children: [
          Expanded(child: Text(title, style: AppText.h2)),
          ?tag,
        ],
      ),
      if (body != null) ...[
        const SizedBox(height: Sp.x3),
        Text(body!, style: AppText.bodySoft),
      ],
      for (final b in bullets) ...[
        const SizedBox(height: Sp.x3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: Sp.x3),
            Expanded(child: Text(b, style: AppText.bodySoft)),
          ],
        ),
      ],
      if (methodNote != null) ...[
        const SizedBox(height: Sp.x5),
        Container(
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(R.chip),
          ),
          child: Text(methodNote!, style: AppText.captionMuted),
        ),
      ],
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.x6, 0, Sp.x6, Sp.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children
              .animate(interval: 30.ms)
              .fadeIn(duration: Motion.enter.d, curve: Motion.enter.c)
              .moveY(begin: 8, end: 0, duration: Motion.enter.d),
        ),
      ),
    );
  }
}

/// Open an [InfoSheet] as a modal bottom sheet (themed: drag handle, rounded
/// top, surface fill come from the app's bottomSheetTheme).
Future<void> showInfoSheet(
  BuildContext context, {
  required String title,
  String? body,
  List<String> bullets = const [],
  String? methodNote,
  Widget? tag,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => InfoSheet(
      title: title,
      body: body,
      bullets: bullets,
      methodNote: methodNote,
      tag: tag,
    ),
  );
}
