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
import 'guide_navigation.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';
import 'guide_target.dart';

/// The Strain ring on the Today tab. Also step 1's anchor: the label is on no
/// other of the three screens.
final _strainRing = GuideTarget.label(ScreenLabel.homeRingStrain);

/// The link on the right of the "Time in zones" heading. Also step 2's anchor.
final _howTheseAreSet = GuideTarget.label(ScreenLabel.dayStrainHowSet);

/// The own-zones link; its text flips with the saved state, so both labels.
/// The title anchors step 3 before this link is built by the lazy list.
final _ownZonesLink = GuideTarget.anyLabel([
  ScreenLabel.activityZonesSetYourOwnLink,
  ScreenLabel.activityZonesEditYourOwnLink,
]);

Guide get heartRateZonesGuide => Guide(
      id: 'heart-rate-zones',
      title: GuideCopy.hrZonesTitle,
      start: GuideStart.today,
      intro: GuideCopy.hrZonesIntro,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-strain',
            node: GuideNode.today,
            target: _strainRing,
            anchor: _strainRing,
            action: GuideAction.tap,
            caption: GuideCopy.hrZonesCaptionOpenStrain,
          ),
          GuideStep(
            id: 'open-zones',
            node: GuideNode.dayStrain,
            target: _howTheseAreSet,
            anchor: _howTheseAreSet,
            action: GuideAction.scrollThenTap,
            caption: GuideCopy.hrZonesCaptionOpenZones,
          ),
          GuideStep(
            id: 'set-own-zones',
            node: GuideNode.zones,
            target: _ownZonesLink,
            anchor: GuideTarget.label(ScreenLabel.activityZonesTitle),
            // The mock-up keeps "Your zones" legible: it is what the link edits.
            alsoKeep: [GuideTarget.label(ScreenLabel.activityZonesYourZonesSection)],
            action: GuideAction.tap,
            caption: GuideCopy.hrZonesCaptionSetOwnZones,
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.anotherWay,
          title: GuideCopy.hrZonesFooter0Title,
          body: GuideCopy.hrZonesFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: GuideCopy.hrZonesFooter1Title,
          body: GuideCopy.hrZonesFooter1Body,
        ),
      ],
    );
