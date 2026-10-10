// What a double-tap on the band does.
//
// The engine for this shipped a long time ago — the event decode, the recency
// and debounce guards, the persisted mapping, the native channel — and then the
// screen that sets it died with the old `lib/ui` tree. So the mapping sat on its
// `none` default with nothing able to change it: a feature that ran on every
// live event and could never do anything. This is the missing half.
//
// The list is not a fixed menu. It is whatever THIS phone said it can actually
// do — `GestureSettings.supported`, seeded from `DeviceActions.capabilities()`.
// An action drawn here and then silently doing nothing is worse than one that
// was never offered: iOS cannot touch system volume or a third-party player, and
// only Android has the Tasker broadcast, so on an iPhone those are simply not in
// the list. When native answers with nothing at all, the phone actions are
// absent AND SAY SO, rather than leaving a gap to guess at.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../gestures/device_action.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'profile.dart';

class BandGestures extends StatelessWidget {
  const BandGestures({super.key});

  @override
  Widget build(BuildContext c) {
    // `gestureSettings` is a ChangeNotifier the dispatcher reads live, so the
    // screen listens to the same object rather than keeping its own copy —
    // picking an action has to move the thing the band is about to consult.
    final g = c.read<AppState>().gestureSettings;
    return ListenableBuilder(
      listenable: g,
      builder: (c, _) => BandGesturesView(
        chosen: g.doubleTap,
        supported: g.supported,
        onPick: g.setDoubleTap,
      ),
    );
  }
}

class BandGesturesView extends StatelessWidget {
  final DeviceAction chosen;

  /// What this phone can do. Always contains [DeviceAction.none].
  final Set<DeviceAction> supported;

  final ValueChanged<DeviceAction>? onPick;

  const BandGesturesView({
    super.key,
    required this.chosen,
    required this.supported,
    this.onPick,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    // Enum order, filtered to this phone: nothing first (it is the default and
    // the way back out), then the in-app actions, then whatever the OS offered.
    final offered = [
      DeviceAction.none,
      ...DeviceAction.values.where((a) => a.isInApp && supported.contains(a)),
      ...DeviceAction.values.where((a) => a.isNative && supported.contains(a)),
    ];
    final noPhoneActions = !offered.any((a) => a.isNative);

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.gesturesNavTitle ?? 'Double-tap'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Section(
                  l?.gesturesSectionTitle ?? 'Tap the band twice',
                  Surface(
                    child: Text(
                      l?.gesturesSectionBody ??
                          'Works only while the app is connected. A tap the band saved while your phone was away is ignored, so it never fires hours late.',
                      style: F.body.copyWith(color: p.ink2, height: 1.4),
                    ),
                  ),
                ),
                settingsGroup(c, l?.gesturesItDoesTitle ?? 'It does', [
                  for (final a in offered)
                    _ActionRow(
                      action: a,
                      selected: a == chosen,
                      onTap: onPick == null ? null : () => onPick!(a),
                    ),
                ]),
                if (noPhoneActions) ...[
                  const SizedBox(height: S.x5),
                  Section(
                    l?.gesturesNoPhoneActionsTitle ?? 'Nothing on the phone?',
                    Surface(
                      child: Text(
                        l?.gesturesNoPhoneActionsBody ??
                            'Ring my phone and flashlight are missing because the app could not reach the system to ask what’s allowed. Reopen the app and come back.',
                        style: F.body.copyWith(color: p.ink2, height: 1.4),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// One choice. Label, what it does, and a tick when it is the live mapping.
class _ActionRow extends StatelessWidget {
  final DeviceAction action;
  final bool selected;
  final VoidCallback? onTap;

  const _ActionRow({required this.action, required this.selected, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: '${action.localizedLabel(c)}. ${action.localizedBlurb(c)}'
          '${selected ? (l?.settingsSelectedSuffix ?? ' Selected.') : ''}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(children: [
          // THE ROW RULE (see SetRow): exactly one flexible child, so every
          // tick in the list lands on the same right edge. Two would split the
          // width by ratio instead.
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(action.localizedLabel(c),
                  style: F.body.copyWith(
                      color: selected ? p.on(C.indigo) : p.ink,
                      fontWeight: selected ? FontWeight.w600 : null)),
              Text(action.localizedBlurb(c),
                  style: F.over.copyWith(color: p.ink3)),
            ]),
          ),
          const SizedBox(width: S.x2),
          Icon(selected ? LucideIcons.check : LucideIcons.circle,
              size: 17, color: selected ? p.on(C.indigo) : p.line),
        ]),
      ),
    );
  }
}
