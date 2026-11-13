// What to do when a device will not finish pairing: the steps for this device,
// or general steps clearly marked as general. Three states (ResetKind):
//  - specific: sourced steps for this device;
//  - unverified: general steps, an orange "we haven't checked" note and a row
//    that opens the maker's own help page;
//  - noOfficialSite: general steps and no link (the maker has no site).
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'pair_help.dart' show PairLinkOpener, SystemLinkOpener, openOrSay;
import 'pair_text.dart';
import 'pair_widgets.dart';

bool isWhoopEntry(BandEntry e) =>
    kWhoopGen4.id == e.id || kWhoopGen5.id == e.id;

/// The l10n key of every step to show for [e] (its own, else the general ones).
/// [bondRefused]: the phone still holds an old pairing record the device
/// refused, which only "Forget" in Bluetooth settings clears, so that step is
/// added first when the device's own steps lack it: their last step is to
/// retry, which fails until the old record is gone.
List<String> resetStepKeysFor(BandEntry e, {bool bondRefused = false}) {
  final r = e.resetSteps;
  final keys = r?.keys?.isNotEmpty == true
      ? r!.keys!
      : kGenericResetStepKeys;
  const forget = 'pairResetGenericStep2';
  return bondRefused && !keys.contains(forget) ? [forget, ...keys] : keys;
}

String resetStepText(AppLocalizations l, String key) => switch (key) {
  'pairResetWhoop5Step1' => l.pairResetWhoop5Step1,
  'pairResetWhoop5Step2' => l.pairResetWhoop5Step2,
  'pairResetWhoop5Step3' => l.pairResetWhoop5Step3,
  'pairResetWhoop5Step4' => l.pairResetWhoop5Step4,
  'pairResetGenericStep1' => l.pairResetGenericStep1,
  'pairResetGenericStep2' => l.pairResetGenericStep2,
  'pairResetGenericStep3' => l.pairResetGenericStep3,
  _ => key,
};

/// "Your ring is paired somewhere else" for a ring, the band wording for the rest.
String resetTitle(AppLocalizations l, BandEntry e) =>
    e.kind == DeviceKind.ring ? l.pairResetTitleRing : l.pairResetTitleBand;

class ResetStepsView extends StatelessWidget {
  final BandEntry entry;
  final PairLinkOpener openLink;

  /// The device refused the bond: the Bluetooth-settings "Forget" step is
  /// always listed ([resetStepKeysFor]).
  final bool bondRefused;
  const ResetStepsView(
      {super.key,
      required this.entry,
      this.openLink = const SystemLinkOpener(),
      this.bondRefused = false});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final r = entry.resetSteps;
    final kind = r?.kind ?? ResetKind.noOfficialSite;
    final general = kind != ResetKind.specific;
    final url = kind == ResetKind.unverified ? r?.officialUrl : null;
    final keys = resetStepKeysFor(entry, bondRefused: bondRefused);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (entry.id == kOura.id) const _OuraKeyGuidance(),
          if (general) ...[
            // The orange note says so loudly for an unchecked device; a device
            // with no maker site gets the same sentence, muted.
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                    kind == ResetKind.unverified
                        ? LucideIcons.circleAlert
                        : LucideIcons.info,
                    size: 14,
                    color: kind == ResetKind.unverified
                        ? p.on(C.orange)
                        : p.ink3),
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(l.pairResetGenericNote,
                    key: const ValueKey('reset-general-note'),
                    style: F.cap.copyWith(
                        color: kind == ResetKind.unverified
                            ? p.on(C.orange)
                            : p.ink3)),
              ),
            ]),
            const SizedBox(height: S.x3),
          ],
          Surface(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.pairResetHeading,
                      style: F.head.copyWith(color: p.ink)),
                  const SizedBox(height: S.x2),
                  for (var i = 0; i < keys.length; i++)
                    PairStepRow(i + 1, resetStepText(l, keys[i])),
                ]),
          ),
          if (isWhoopEntry(entry)) ...[
            const SizedBox(height: S.x3),
            Text(l.pairResetWhoopTakeover,
                key: const ValueKey('reset-whoop-takeover'),
                style: F.cap.copyWith(color: p.ink2)),
          ],
          if (url != null) ...[
            const SizedBox(height: S.x3),
            ChoiceRow(
              LucideIcons.externalLink,
              l.pairResetOfficialLink,
              l.pairResetOfficialSub(Uri.parse(url).host),
              trailing: LucideIcons.chevronRight,
              onTap: () => openOrSay(c, openLink, url),
            ),
          ],
        ]);
  }
}

/// "Put it in pairing mode", up front on a device's sheet (and, without its
/// heading and link, under each model in "Trouble connecting?"). From the
/// entry's researched steps (ResetSteps):
///  - specific: its numbered steps;
///  - unverified: the general steps and the maker's page;
///  - noOfficialSite: one line saying there is no maker's page.
/// Always open, so nothing shifts.
class PairingModeSection extends StatelessWidget {
  final BandEntry entry;
  final PairLinkOpener openLink;

  /// The "Put it in pairing mode" heading.
  final bool heading;

  /// The maker's page row (unverified only).
  final bool link;

  const PairingModeSection({
    super.key,
    required this.entry,
    this.openLink = const SystemLinkOpener(),
    this.heading = true,
    this.link = true,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final r = entry.resetSteps;
    final kind = r?.kind ?? ResetKind.noOfficialSite;
    final url = kind == ResetKind.unverified ? r?.officialUrl : null;
    final keys = resetStepKeysFor(entry);
    return Column(
      key: ValueKey('pairing-mode-${entry.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (entry.id == kOura.id) const _OuraKeyGuidance(),
        if (heading)
          Padding(
            padding: const EdgeInsets.only(bottom: S.x2),
            child: Text(l.pairModeTitle, style: F.head.copyWith(color: p.ink)),
          ),
        if (kind == ResetKind.unverified)
          Padding(
            padding: const EdgeInsets.only(bottom: S.x2),
            child: Text(l.pairResetGenericNote,
                key: ValueKey('pairing-mode-general-note-${entry.id}'),
                style: F.cap.copyWith(color: p.on(C.orange))),
          ),
        if (kind == ResetKind.noOfficialSite)
          Text(l.pairModeNoSite,
              key: ValueKey('pairing-mode-no-site-${entry.id}'),
              style: F.cap.copyWith(color: p.ink2))
        else
          for (var i = 0; i < keys.length; i++)
            PairStepRow(i + 1, resetStepText(l, keys[i]),
                key: ValueKey('pairing-mode-step-${entry.id}-${i + 1}'),
                compact: true),
        if (link && url != null)
          Pressable(
            onTap: () => openOrSay(c, openLink, url),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x2),
              child: Row(children: [
                Icon(LucideIcons.externalLink, size: 14, color: p.on(C.blue)),
                const SizedBox(width: S.x2),
                Flexible(
                  child: Text(
                      '${l.pairResetOfficialLink} · ${Uri.parse(url).host}',
                      key: ValueKey('pairing-mode-link-${entry.id}'),
                      style: F.cap.copyWith(
                          color: p.on(C.blue), fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),
      ],
    );
  }
}

/// Keep the existing-key path safe wherever Oura's reset steps are shown.
class _OuraKeyGuidance extends StatelessWidget {
  const _OuraKeyGuidance();

  @override
  Widget build(BuildContext c) => Padding(
      padding: const EdgeInsets.only(bottom: S.x3),
      child: Text(pairL10n(c).pairOuraExistingKeyGuidance,
          style: F.body.copyWith(color: P.of(c).ink)));
}
