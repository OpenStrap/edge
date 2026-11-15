// REVIEW TOOLING (never shipped): which demo screen each guide step is drawn on
// in the review renders (GuideStepView, guide_view.dart).
//
// The shipped GuideStep has no screen: the live overlay walks the user's own
// screens. The owner's sign-off images want the same steps on fixed demo data,
// so the map from step id to a demo screen builder lives here.
//
// CLAIM(demo-screens-by-id): step ids are unique across the catalogue, so one
// map keyed by id is unambiguous [guide_model_test 'step ids are unique'].

import 'package:flutter/widgets.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart' show DayStrainDetail;
import 'package:openstrap_edge/ui2/activity/zones.dart' show ZonesDetail;
import 'package:openstrap_edge/ui2/app_shell.dart' show AppShell, ShellDomain;
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show HomeScreen;

import 'guide_demo_data.dart';

final Map<String, WidgetBuilder> kGuideDemoScreens = {
  // Home inside the tab bar, as on the phone: the bar is chrome and stays legible.
  'open-strain': (_) => AppShell(
        builder: (context, domain) => switch (domain) {
          ShellDomain.today => HomeScreen(data: GuideDemo.home, hour: 9, workoutLive: false),
          ShellDomain.sleep || ShellDomain.activity || ShellDomain.health => const SizedBox.shrink(),
        },
      ),
  'open-zones': (_) => DayStrainDetail(data: GuideDemo.dayStrain),
  'set-own-zones': (_) => ZonesDetail(data: GuideDemo.zones),
};

/// The demo screen of [step]; a step with none registered is a test bug, so it
/// fails loudly instead of rendering nothing.
WidgetBuilder demoScreenFor(GuideStep step) =>
    kGuideDemoScreens[step.id] ?? (throw StateError('no demo screen registered for step "${step.id}"'));

/// Tests of the review views build synthetic steps with their own screens:
/// registers [screen] for [id] and returns the (screen-less) shipped step.
GuideStep demoStep({
  required String id,
  required WidgetBuilder screen,
  required GuideTarget target,
  required GuideTarget anchor,
  List<GuideTarget> alsoKeep = const [],
  required GuideAction action,
  required GuideText caption,
}) {
  kGuideDemoScreens[id] = screen;
  return GuideStep(id: id, target: target, anchor: anchor, alsoKeep: alsoKeep, action: action, caption: caption);
}
