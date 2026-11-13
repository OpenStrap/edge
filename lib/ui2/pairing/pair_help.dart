// "Trouble connecting?", an always-open card where the pairing screens
// list their ways out: each band's official pairing-mode page and the
// project's Discord. Nothing expands, so nothing shifts. Links open in the
// user's own browser, never inside the app.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../l10n/display_text.dart' show uiText;
import '../ui2.dart';
import 'pair_text.dart';
import 'reset_steps_view.dart' show PairingModeSection;

/// Opens a link outside the app; true when something took it. An interface
/// (not a function type) so tests pass a fake without an unresolved call.
abstract interface class PairLinkOpener {
  Future<bool> open(String url);
}

/// The real one: the user's own browser or app, never a WebView.
class SystemLinkOpener implements PairLinkOpener {
  const SystemLinkOpener();
  @override
  Future<bool> open(String url) => open3rdPartyLink(url);
}

/// Opens [url] with [opener]; when nothing took it, a snackbar says so and
/// shows the address, so the user can still get there by hand.
Future<void> openOrSay(BuildContext c, PairLinkOpener opener, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(c);
  final l = pairL10n(c);
  if (await opener.open(url)) return;
  messenger?.showSnackBar(SnackBar(content: Text(l.pairLinkOpenFailed(url))));
}

/// The maker's official help page for [e], or null when the entry has none
/// (a no-official-site device, or nothing chosen yet).
String? officialHelpUrl(BandEntry? e) => e?.resetSteps?.officialUrl;

class TroubleConnectingCard extends StatelessWidget {
  /// The devices whose maker pages to offer, in order; an entry with no
  /// official page is left out. Empty offers Discord only.
  final List<BandEntry> entries;
  final PairLinkOpener openLink;

  /// Each model's pairing-mode steps, inline under its link. Off where the
  /// steps are already on the screen (the failure screen).
  final bool showSteps;

  const TroubleConnectingCard({
    super.key,
    required this.entries,
    this.openLink = const SystemLinkOpener(),
    this.showSteps = true,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final links = [
      for (final e in entries)
        if (officialHelpUrl(e) case final url?) (entry: e, url: url),
    ];
    return Surface(
      key: const ValueKey('trouble-connecting'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(LucideIcons.lifeBuoy, size: 18, color: p.ink2),
          const SizedBox(width: S.x2),
          Expanded(
            child: Text(l.pairTroubleTitle,
                style: F.head.copyWith(color: p.ink)),
          ),
        ]),
        const SizedBox(height: S.x2),
        Text(l.pairTroubleBody, style: F.cap.copyWith(color: p.ink2)),
        const SizedBox(height: S.x2),
        for (final k in links) ...[
          _LinkRow(
            key: ValueKey('trouble-link-${k.entry.id}'),
            icon: deviceKindIcon(k.entry.kind),
            title: l.pairTroubleModeLink(uiText(c, k.entry.label)),
            sub: Uri.parse(k.url).host,
            onTap: () => openOrSay(c, openLink, k.url),
          ),
          if (showSteps)
            Padding(
              padding: const EdgeInsets.only(left: 48, bottom: S.x3),
              child: PairingModeSection(
                  entry: k.entry, heading: false, link: false),
            ),
        ],
        _LinkRow(
          key: const ValueKey('trouble-link-discord'),
          icon: LucideIcons.messagesSquare,
          title: l.pairTroubleDiscord,
          sub: l.pairTroubleDiscordSub,
          onTap: () => openOrSay(c, openLink, kDiscordUrl),
        ),
      ]),
    );
  }
}

/// A link row inside the card: icon tile, title, one line, the leave-the-app
/// mark.
class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String title, sub;
  final VoidCallback onTap;
  const _LinkRow({
    super.key,
    required this.icon,
    required this.title,
    required this.sub,
    required this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: S.tap),
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        decoration:
            BoxDecoration(border: Border(top: BorderSide(color: p.line))),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: p.wash(C.blue), borderRadius: R.rMd),
            child: Icon(icon, size: 18, color: p.on(C.blue)),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: F.body
                          .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
                  Text(sub, style: F.cap.copyWith(color: p.ink3)),
                ]),
          ),
          const SizedBox(width: S.x2),
          Icon(LucideIcons.externalLink, size: 16, color: p.ink3),
        ]),
      ),
    );
  }
}
