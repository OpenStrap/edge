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
      start: GuideStart.today,
      intro: (l) => l.guideHrZonesIntro(l.homeRingStrain),
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-strain',
            target: _strainRing,
            anchor: _strainRing,
            action: GuideAction.tap,
            caption: (l) => l.guideHrZonesStep1(l.tabToday, l.homeRingStrain),
          ),
          GuideStep(
            id: 'open-zones',
            target: _howTheseAreSet,
            anchor: _howTheseAreSet,
            action: GuideAction.scrollThenTap,
            caption: (l) => l.guideHrZonesStep2(l.dayStrainTimeInZonesSection, l.dayStrainHowSet),
          ),
          GuideStep(
            id: 'set-own-zones',
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
          kind: GuideFooterKind.anotherWay,
          title: (l) => l.guideHrZonesAltTitle,
          body: (l) => l.guideHrZonesAltBody(l.tabActivity, l.workoutTodaysStrainAction),
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: (l) => l.guideHrZonesMissingTitle(l.dayStrainTimeInZonesSection),
          body: (l) => l.guideHrZonesMissingBody,
        ),
      ],
    );
