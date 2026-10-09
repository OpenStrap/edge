import '../../l10n/display_text.dart';
// Choose an activity.
//
// Two ways in, because there are two kinds of user: the one who does the same
// six things (the recent row, one tap) and the one who did something unusual
// today (search, then eight collapsed groups). Both land on the same setup
// screen, so there is one path to a live session, not two.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../grammar.dart';
import '../theme.dart';
import 'catalogue.dart';
import 'live.dart';
import 'setup.dart';

class ActivityPicker extends StatefulWidget {
  /// Body weight for the per-row calorie hint. Null hides it rather than
  /// inventing a 70 kg default.
  final double? weightKg;

  /// The app behind the session this picker starts.
  final ActivityHost host;

  /// The activities this user actually did, most recent first. Empty means
  /// there is no history to show, and the row falls back to [quickStart]
  /// under its own honest heading.
  final List<Activity> recent;

  /// Where a chosen activity goes. Defaults to [ActivitySetup].
  final void Function(BuildContext c, Activity a)? onPick;

  const ActivityPicker({
    super.key,
    this.weightKg,
    this.host = ActivityHost.none,
    this.recent = const [],
    this.onPick,
  });

  @override
  State<ActivityPicker> createState() => _ActivityPickerState();
}

class _ActivityPickerState extends State<ActivityPicker> {
  String q = '';
  int group = -1;

  /// The group that was open before this one. [AnimatedCrossFade] builds both
  /// of its children whatever it is showing, so building every group's rows
  /// unconditionally cost about 960 widgets for the twelve on screen. Only the
  /// open group is built now, plus this one so its collapse still has
  /// something to fade out.
  int closing = -1;

  void _pick(BuildContext c, Activity a) {
    if (widget.onPick != null) return widget.onPick!(c, a);
    Navigator.of(c).push(MaterialPageRoute(
        builder: (_) =>
            ActivitySetup(a, weightKg: widget.weightKg, host: widget.host)));
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final searching = q.trim().isNotEmpty;
    final needle = q.trim().toLowerCase();
    final results = searching
        ? [
            for (final a in allActivities)
              if (a.displayName(c).toLowerCase().contains(needle) ||
                  a.name.toLowerCase().contains(needle))
                a,
          ]
        : const <Activity>[];

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.activityPickerTitle ?? 'Choose activity'),
          ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: Container(
                constraints: const BoxConstraints(minHeight: S.tap),
                padding: const EdgeInsets.symmetric(horizontal: S.x4),
              decoration:
                  BoxDecoration(color: p.card2, borderRadius: R.rMd),
              child: Row(children: [
                Icon(LucideIcons.search, size: 17, color: p.ink3),
                const SizedBox(width: S.x2),
                Expanded(
                  // Labelled and focused: this screen's entire purpose is the
                  // search, and a hint-only field announces nothing once a
                  // character is in it.
                  child: Semantics(
                    label: l?.activityPickerSearchLabel ?? 'Search activities',
                    textField: true,
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setState(() => q = v),
                      style: F.body.copyWith(color: p.ink),
                      cursorColor: p.on(C.purple),
                      decoration: InputDecoration.collapsed(
                          hintText: l?.activityPickerSearchHint(
                                  allActivities.length) ??
                              'Search ${allActivities.length} activities',
                          hintStyle: F.body.copyWith(color: p.ink3)),
                    ),
                  ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: S.x4),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
                children: [
                  if (searching)
                    if (results.isEmpty)
                      // No `fix`: the 'Custom activity' row it pointed at is
                      // gone (it carried an invented MET), and a fix string
                      // paints a call to action that cannot be tapped.
                    StatusCard(
                      l?.activityPickerNoMatchTitle ??
                          'No activity matches that',
                      l?.activityPickerNoMatchBody ??
                          'The catalogue covers about seventy activities '
                              'with a published energy cost. Pick the '
                              'closest one.',
                      icon: LucideIcons.search,
                    )
                  else
                    Surface(
                      pad: const EdgeInsets.symmetric(horizontal: S.x4),
                      child: Column(children: [
                        for (var i = 0; i < results.length; i++) ...[
                          ActivityRow(results[i],
                              weightKg: widget.weightKg,
                              onTap: () => _pick(c, results[i])),
                          if (i < results.length - 1)
                            Divider(color: p.line, height: 1),
                        ],
                      ]),
                    )
                else ...[
                  // "RECENT" over a fixed six-item constant was a lie the
                  // first time anyone read it. The heading follows the data.
                  Text(
                      widget.recent.isEmpty
                          ? (l?.activityPickerQuickStart ?? 'QUICK START')
                          : (l?.activityPickerRecent ?? 'RECENT'),
                      style: F.over.copyWith(color: p.ink3)),
                  const SizedBox(height: S.x3),
                  Builder(builder: (_) {
                    final row = widget.recent.isEmpty
                        ? quickStart
                        : widget.recent;
                    return SizedBox(
                      height: 96,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: row.length,
                        separatorBuilder: (_, _) => const SizedBox(width: S.x3),
                        itemBuilder: (_, i) =>
                            _Quick(row[i], () => _pick(c, row[i])),
                      ),
                    );
                  }),
                  const SizedBox(height: S.x5),
                  for (var gi = 0; gi < activityLibrary.length; gi++) ...[
                    Pressable(
                      onTap: () => setState(() {
                        closing = group;
                        group = group == gi ? -1 : gi;
                      }),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: S.x3),
                        child: Row(children: [
                          Icon(activityLibrary[gi].icon,
                              size: 18, color: p.ink2),
                              const SizedBox(width: S.x3),
                              Expanded(
                                child: Text(
                                  activityLibrary[gi].displayName(c),
                                  style: F.head.copyWith(color: p.ink),
                                ),
                              ),
                          Text('${activityLibrary[gi].items.length}',
                              style: F.cap.copyWith(color: p.ink3)),
                          const SizedBox(width: S.x2),
                          AnimatedRotation(
                            turns: group == gi ? .25 : 0,
                            duration: motion(c, Motion.base),
                            child: Icon(LucideIcons.chevronRight,
                                size: 18, color: p.ink3),
                          ),
                            ],
                          ),
                        ),
                      ),
                    AnimatedCrossFade(
                      duration: motion(c, Motion.base),
                      crossFadeState: group == gi
                          ? CrossFadeState.showFirst
                          : CrossFadeState.showSecond,
                      firstChild: group == gi || closing == gi
                          ? Surface(
                              pad: const EdgeInsets.symmetric(
                                  horizontal: S.x4),
                              child: Column(children: [
                                for (var i = 0;
                                    i < activityLibrary[gi].items.length;
                                    i++) ...[
                                  ActivityRow(activityLibrary[gi].items[i],
                                      weightKg: widget.weightKg,
                                      onTap: () => _pick(
                                          c, activityLibrary[gi].items[i])),
                                  if (i <
                                      activityLibrary[gi].items.length - 1)
                                    Divider(color: p.line, height: 1),
                                ],
                              ]),
                            )
                          : const SizedBox(width: double.infinity),
                      secondChild: const SizedBox(width: double.infinity),
                    ),
                    Divider(color: p.line, height: 1),
                  ],
                  if (widget.weightKg != null) ...[
                    const SizedBox(height: S.x5),
                    StatusCard(
                      l?.activityPickerCalorieEstimatesTitle ??
                          'Calorie figures are estimates',
                        uiText(c, kCalorieWhy),
                        icon: LucideIcons.flame,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One catalogue row — icon, name, its privacy and GPS marks, and either a
/// calorie estimate or the MET it would be computed from.
class ActivityRow extends StatelessWidget {
  final Activity a;
  final double? weightKg;
  final VoidCallback? onTap;
  const ActivityRow(this.a, {super.key, this.weightKg, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final kcal = a.kcal(weightKg, 30);
    final met = a.met;
    final metStr = met?.toStringAsFixed(1);
    // An unpriced row (the catch-all, Padel) has neither: no weight means no
    // kcal, and there is no MET to fall back to. It gets no trailing number
    // rather than a placeholder standing in for one.
    final trailing = kcal != null
        ? '$kcal kcal / 30 min'
        : metStr == null
            ? null
            : '$metStr MET';
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(
          children: [
            Icon(a.icon, size: 18, color: p.on(a.color)),
            const SizedBox(width: S.x3),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      a.displayName(c),
                      style: F.body.copyWith(color: p.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)),
              if (a.private) ...[
                const SizedBox(width: S.x2),
                Icon(LucideIcons.lock, size: 12, color: p.ink3),
              ],
              if (a.gps) ...[
                const SizedBox(width: S.x2),
                Icon(LucideIcons.mapPin, size: 12, color: p.ink3),
              ],
            ]),
          ),
          // THE ROW RULE: the name is the only flexible part, so the calorie
          // estimates line up down the list. At an accessibility size the
          // estimate drops off the row rather than overflowing it — the name
          // and the tap are what the row is for, and the same number is on
          // the setup screen the tap opens.
          if (!bigText(c) && trailing != null) ...[
            const SizedBox(width: S.x2),
            Text(
                kcal == null
                    ? (l?.activityPickerMetValue(metStr!) ?? '$metStr MET')
                    : (l?.activityPickerKcalPer30(kcal) ??
                        '$kcal kcal / 30 min'),
                style: F.over.copyWith(color: p.ink3)),
          ],
          const SizedBox(width: S.x2),
          Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
        ]),
      ),
    );
  }
}

class _Quick extends StatelessWidget {
  final Activity a;
  final VoidCallback onTap;
  const _Quick(this.a, this.onTap);

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: a.displayName(c),
      child: Container(
        width: 84,
        decoration: BoxDecoration(
            color: p.card, borderRadius: R.rLg, boxShadow: p.el(1)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 38,
            height: 38,
            decoration:
                BoxDecoration(color: p.wash(a.color), borderRadius: R.rMd),
            child: Icon(a.icon, size: 18, color: p.on(a.color)),
          ),
            const SizedBox(height: S.x2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x1),
              child: Text(
                a.displayName(c),
                style: F.over.copyWith(color: p.ink2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      ),
    );
  }
}
