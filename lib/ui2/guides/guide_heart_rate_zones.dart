// GUIDE #1 (phase 2): where to find the heart-rate zones.
//
//   Today ring "Strain"  ->  DayStrainDetail "How these are set"  ->
//   ZonesDetail "Set your own zones" (or "Edit your own zones" once saved).
//
// Every target is the in-app label of the REAL screen, read through the same
// AppLocalizations getter the screen prints, so the guide follows the user's
// language and cannot drift from the screen: if a label is renamed, the step
// stops resolving and its test fails. Captions take those labels as
// parameters, so they quote the app verbatim in every locale.
//
// One path serves both band generations (the screens are band-independent).

import 'package:flutter/widgets.dart';

import '../activity/day_strain.dart' show DayStrainDetail;
import '../activity/zones.dart' show ZonesDetail;
import '../app_shell.dart' show AppShell, ShellDomain;
import '../screens/home_screen.dart' show HomeScreen;
import 'demo_data.dart';
import 'guide.dart';
import 'guide_target.dart';

/// The Strain ring on the Today tab. Also step 1's anchor: the label is on no
/// other of the three screens.
final _strainRing = GuideTarget.label((l) => l.homeRingStrain);

/// The link on the right of the "Time in zones" heading. Also step 2's anchor.
final _howTheseAreSet = GuideTarget.label((l) => l.dayStrainHowSet);

/// The own-zones link; its text flips with the saved state, so both labels.
/// Also step 3's anchor.
final _ownZonesLink = GuideTarget.anyLabel([
  (l) => l.activityZonesSetYourOwnLink,
  (l) => l.activityZonesEditYourOwnLink,
]);

Guide get heartRateZonesGuide => Guide(
      id: 'heart-rate-zones',
      title: (l) => l.guideHrZonesTitle,
      intro: (l) => l.guideHrZonesIntro(l.homeRingStrain),
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-strain',
            // Home inside the tab bar, as on the phone: the bar is chrome and
            // stays legible.
            screen: (_) => AppShell(
              builder: (context, domain) => switch (domain) {
                ShellDomain.today => HomeScreen(data: GuideDemo.home, hour: 9, workoutLive: false),
                ShellDomain.sleep || ShellDomain.activity || ShellDomain.health => const SizedBox.shrink(),
              },
            ),
            target: _strainRing,
            anchor: _strainRing,
            action: GuideAction.tap,
            caption: (l) => l.guideHrZonesStep1(l.tabToday, l.homeRingStrain),
          ),
          GuideStep(
            id: 'open-zones',
            screen: (_) => DayStrainDetail(data: GuideDemo.dayStrain),
            target: _howTheseAreSet,
            anchor: _howTheseAreSet,
            action: GuideAction.scrollThenTap,
            caption: (l) => l.guideHrZonesStep2(l.dayStrainTimeInZonesSection, l.dayStrainHowSet),
          ),
          GuideStep(
            id: 'set-own-zones',
            screen: (_) => ZonesDetail(data: GuideDemo.zones),
            target: _ownZonesLink,
            anchor: _ownZonesLink,
            // The mock-up keeps "Your zones" legible: it is what the link edits.
            alsoKeep: [GuideTarget.label((l) => l.activityZonesYourZonesSection)],
            action: GuideAction.tap,
            caption: (l) => l.guideHrZonesStep3(l.activityZonesTitle, l.activityZonesSetYourOwnLink),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          title: (l) => l.guideHrZonesAltTitle,
          body: (l) => l.guideHrZonesAltBody(l.tabActivity, l.workoutTodaysStrainAction),
        ),
        GuideFooter(
          title: (l) => l.guideHrZonesMissingTitle(l.dayStrainTimeInZonesSection),
          body: (l) => l.guideHrZonesMissingBody,
        ),
      ],
    );
