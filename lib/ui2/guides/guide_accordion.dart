// Accordions own their expanded state. Guides only read this boundary and point
// at its header; they never toggle it. Mating parts: GuideTarget, SettingsAccordion.
import 'package:flutter/widgets.dart';

/// Navigation that remains readable and tappable inside a dimmed or placeholder
/// card. Unlike a screen bar it does not bound the guide card's usable area.
class GuideNavigationHeader extends StatelessWidget {
  final Widget child;
  const GuideNavigationHeader({super.key, required this.child});
  @override
  Widget build(BuildContext context) => child;
}

/// A collapsed body is laid out offstage only during a guide, so ordinary widget
/// builders can reveal target ownership without showing or opening the body.
/// CLAIM(accordion-user-hop): resolution returns the outermost closed header,
/// never the hidden control [guide_accordion_navigation_test].
class GuideAccordionBody extends Offstage {
  final String title;
  final GlobalKey headerKey;
  const GuideAccordionBody({super.key, required this.title, required this.headerKey,
    required super.offstage, required super.child});
}
