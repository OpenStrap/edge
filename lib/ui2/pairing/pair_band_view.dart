// First-run "Pair your band": the devices that can be the user's main band,
// each marked "Every day", the always-open "Trouble connecting?" card, and
// the ways out (a heart-rate strap only, skip).
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ble/adapters/_registry.dart';
import '../../ble/slot_comparison.dart';
import '../../l10n/display_text.dart';
import '../ui2.dart';
import 'category_filter_pills.dart';
import 'pair_help.dart';
import 'pair_sheets.dart';
import 'pair_text.dart';
import 'pair_widgets.dart';
import 'whoop_firmware_warning.dart';

/// The devices the first run offers as the main band, in registry order.
List<BandEntry> firstRunBandEntries() => [
  for (final e in kBandRegistry)
    if (e.canBeMainDevice) e,
];

/// What the first-run list asks of the screen around it.
abstract interface class PairBandHost {
  /// A device row was tapped.
  void pickBand(BandEntry entry);

  /// The user confirmed pairing a heart-rate strap as a sensor (no band).
  void strapOnlyConfirmed();
}

class PairBandView extends StatefulWidget {
  final List<BandEntry> entries;
  final PairBandHost host;

  /// Non-null only at true first run: walk past pairing.
  final VoidCallback? onSkip;

  /// Where the back chevron goes when there is no route underneath to pop
  /// (first-run onboarding); null keeps the default `Navigator.maybePop`.
  final VoidCallback? onBack;

  /// The last failure, in a sentence.
  final String? problem;
  final PairLinkOpener openLink;

  const PairBandView({
    super.key,
    required this.entries,
    required this.host,
    this.onSkip,
    this.onBack,
    this.problem,
    this.openLink = const SystemLinkOpener(),
  });

  @override
  State<PairBandView> createState() => _PairBandViewState();
}

class _PairBandViewState extends State<PairBandView> {
  final _group = ValueNotifier<PairFilter?>(null);

  @override
  void initState() {
    super.initState();
    _group.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _group.dispose();
    super.dispose();
  }

  Future<void> _strapOnly() async {
    if (await showStrapSheet(context, sensor: kBleHrs)) {
      widget.host.strapOnlyConfirmed();
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final shown = filterByGroup(widget.entries, _group.value);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l.pairSetUpTitle, onBack: widget.onBack),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x10),
              children: [
                const WhoopFirmwareWarning(),
                const SizedBox(height: S.x4),
                Text(l.pairBandTitle,
                    key: const ValueKey('pair-band-title'),
                    style: F.t1.copyWith(color: p.ink)),
                const SizedBox(height: S.x2),
                Text(l.pairBandSubtitle, style: F.body.copyWith(color: p.ink2)),
                const SizedBox(height: S.x2),
                Text(l.pairMainBandWhoopOnly,
                    key: const ValueKey('main-band-whoop-only-note'),
                    style: F.cap.copyWith(color: p.ink3)),
                const SizedBox(height: S.x4),
                CategoryFilterPills(
                  kinds: [for (final e in widget.entries) e.kind],
                  selection: _group,
                ),
                if (shown.isNotEmpty) const SizedBox(height: S.x3),
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) const SizedBox(height: S.x3),
                  _BandRow(
                    entry: shown[i],
                    onTap: () => widget.host.pickBand(shown[i]),
                  ),
                ],
                if (widget.problem != null) ...[
                  const SizedBox(height: S.x4),
                  StatusCard(l.pairSensorThatDidNotWork, widget.problem!,
                      icon: LucideIcons.circleAlert),
                ],
                const SizedBox(height: S.x4),
                TroubleConnectingCard(
                    entries: widget.entries, openLink: widget.openLink),
                TextLinkButton(l.pairStrapOnlyLink, onTap: _strapOnly),
                if (widget.onSkip != null) ...[
                  BigButton(l.pairingSkipForNow,
                      color: C.blue, soft: true, onTap: widget.onSkip),
                  const SizedBox(height: S.x2),
                  Text(l.pairingSkipNote,
                      style: F.cap.copyWith(color: p.ink3)),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// The line under a row says what a WHOOP sends. It is WHOOP copy, so another
/// main-band entry added later gets no line until it has its own.
bool _isWhoop(BandEntry e) => e.id == kWhoopGen4.id || e.id == kWhoopGen5.id;

class _BandRow extends StatelessWidget {
  final BandEntry entry;
  final VoidCallback onTap;
  const _BandRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = pairL10n(c);
    final slot = slotComparisonFor(entry).slot;
    return Surface(
      key: ValueKey('band-row-${entry.id}'),
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.card2, borderRadius: R.rMd),
          child: Icon(deviceKindIcon(entry.kind), size: 22, color: p.ink2),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(uiText(c, entry.label),
                    style: F.body
                        .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
                if (_isWhoop(entry)) ...[
                  const SizedBox(height: 2),
                  Text(l.pairWhoopRowLine,
                      style: F.cap.copyWith(color: p.ink2)),
                ],
                if (slot != null) ...[
                  const SizedBox(height: S.x2),
                  slotPill(l, slot),
                ],
              ]),
        ),
        Icon(LucideIcons.chevronRight, size: 18, color: p.ink3),
      ]),
    );
  }
}
