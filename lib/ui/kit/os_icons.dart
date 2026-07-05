// OsAppIcon — the edge-side seam over the `openstrap_icons` package (the
// illustrated, full-colour, theme-aware icon set). The package exports its own
// `AppIcon`, which collides with the kit's HugeIcon wrapper in kit.dart, so
// the package is imported here (prefixed) exactly ONCE and every screen goes
// through [OsAppIcon] + the re-exported [OsIcon] enum instead.
//
// Design contract: these are premium colored ILLUSTRATIONS, not tintable line
// glyphs — express state with [opacity] (e.g. inactive nav tabs), never a
// color filter. Small monochrome chrome (back/close/settings/chevrons…) stays
// on the hugeicons `Ic` set.

import 'package:flutter/material.dart';
import 'package:openstrap_icons/openstrap_icons.dart' as osi;

export 'package:openstrap_icons/openstrap_icons.dart' show OsIcon;

/// Renders an OpenStrap illustrated icon. Light/dark art is resolved from the
/// ambient [Theme] by the package; missing art degrades to an empty box of
/// [size] (never throws).
class OsAppIcon extends StatelessWidget {
  final osi.OsIcon icon;
  final double size;

  /// 1.0 = full-strength. Use ~0.5 for inactive states — the illustrations
  /// are full-colour and must not be tinted.
  final double opacity;
  final String? semanticLabel;

  const OsAppIcon(
    this.icon, {
    super.key,
    this.size = 24,
    this.opacity = 1.0,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final child = osi.AppIcon(icon, size: size, semanticLabel: semanticLabel);
    if (opacity >= 1.0) return child;
    return Opacity(opacity: opacity, child: child);
  }
}
