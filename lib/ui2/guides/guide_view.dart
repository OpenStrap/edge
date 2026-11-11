// GUIDE VIEWS (phase 2) — RED-PHASE STUBS ONLY.

import 'package:flutter/widgets.dart';

import 'guide.dart';

/// Logical size the demo screen is laid out at inside the frame; the frame
/// scales it down to fit its width.
const kGuidePhoneSize = Size(390, 780);

class GuideStepView extends StatefulWidget {
  /// 1-based, shown in the caption badge.
  final int number;
  final GuideStep step;

  /// Rendered width of the phone frame.
  final double width;

  const GuideStepView({
    super.key,
    required this.number,
    required this.step,
    this.width = 280,
  });

  static const frameKey = ValueKey('guide-frame');
  static const captionKey = ValueKey('guide-caption');
  static const numberKey = ValueKey('guide-number');
  static const outlineKey = ValueKey('guide-outline');
  static const tapPillKey = ValueKey('guide-tap-pill');
  static const scrollMarkerKey = ValueKey('guide-scroll-marker');

  /// Shown INSTEAD of the frame when the target does not resolve.
  static const failureKey = ValueKey('guide-failure');

  @override
  State<GuideStepView> createState() => _GuideStepViewState();
}

class _GuideStepViewState extends State<GuideStepView> {
  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

class GuideView extends StatelessWidget {
  final Guide guide;

  /// The user's band; null = unknown.
  final BandGeneration? band;

  const GuideView({super.key, required this.guide, this.band});

  /// Shown INSTEAD of the steps when the guide has no variant for [band].
  static const noVariantKey = ValueKey('guide-no-variant');

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
