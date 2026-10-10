// WHAT CHANGED — the nightly sweep, given a screen.
//
// The sweep already existed and already worked: `nightly_sweep.dart` measures
// each metric against THIS person's own trailing history, cuts the window at
// the most recent algorithm break so a release of ours is never reported as a
// finding about them, needs a fortnight before it will judge anything, and
// stays quiet when there is nothing to say. Its entire delivery was a push
// notification body. Dismiss the notification and the finding was gone — no
// list, no history, no way to ask "what did it say last Tuesday".
//
// So this screen adds no analysis. It calls the same two functions the evening
// briefing calls, on a day you can steer, and prints what they return.
//
// NOTHING IS THE COMMON ANSWER AND IT IS A COMPLETE ONE. `kNothingStoodOut` is
// a first-class outcome and is not padded out with the day's numbers to look
// like more — the numbers are three taps away on screens built for them, and
// restating them here would turn "nothing was unusual" into a wall of text
// that reads as though something was.
//
// NO VERDICT COLOUR. A finding is a direction and a distance, never a good or
// a bad: a high strain day and a high resting heart rate are the same
// arithmetic and only one of them is bad news, and the screen has no way to
// know which. Arrows say which way; nothing says whether.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../ai/briefing_engine.dart' show collectSweepSeries;
import '../../ai/nightly_sweep.dart';
import '../../data/local_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/sweep_text.dart';
import '../ui2.dart';
import 'day_timeline.dart' show DayTimelineScreen;
import 'home_screen.dart' show go, repoOf;
import 'metric_detail.dart'
    show dayNavRow, detailLinkRow, detailScaffold, pickDay;
import 'month_grid.dart';

class WhatChangedData {
  const WhatChangedData({
    this.day,
    this.days = const [],
    this.findings = const [],
    this.grid = const [],
    this.longestHistory = 0,
    this.hadToday = false,
  });

  final String? day;

  /// Every derived day, newest first — what `DayNav` steers over.
  final List<String> days;
  final List<SweepFinding> findings;
  final List<GridRow> grid;

  /// The most history any one metric had. This is what separates "we looked
  /// and nothing was unusual" from "we cannot look yet", and those are
  /// different sentences.
  final int longestHistory;

  /// Whether ANY metric had a value on the shown day. A day with no value has
  /// no finding for a reason that has nothing to do with the user's body.
  final bool hadToday;

  static Future<WhatChangedData> load(LocalRepository repo,
      {String? want}) async {
    final days = await repo.availableDays();
    final today = await repo.getToday();
    final day = pickDay(
        days, want, (today['status'] as Map?)?['today_day']?.toString());
    if (day == null) return WhatChangedData(days: days, grid: await loadGridRows(repo));

    // The sweep, run FOR THAT DAY. `collectSweepSeries` takes the moment to
    // read as, and treats every stored day before it as the history — so a day
    // in the past is swept against what was known then, not against everything
    // that has happened since.
    final at = DateTime.tryParse(day) ?? DateTime.now();
    final series = await collectSweepSeries(repo, at);
    var longest = 0;
    for (final s in series) {
      if (s.history.length > longest) longest = s.history.length;
    }
    return WhatChangedData(
      day: day,
      days: days,
      findings: sweepFindings(series),
      grid: await loadGridRows(repo),
      longestHistory: longest,
      hadToday: series.isNotEmpty,
    );
  }
}

class WhatChangedScreen extends StatefulWidget {
  const WhatChangedScreen({super.key, this.day, this.data});

  final String? day;
  final WhatChangedData? data;

  @override
  State<WhatChangedScreen> createState() => _WhatChangedScreenState();
}

class _WhatChangedScreenState extends State<WhatChangedScreen> {
  WhatChangedData? _d;
  bool _loading = true;
  String? _day;
  // A quick second tap on the day stepper starts a second load; the first
  // can finish last and must not paint the old day under the new label.
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _day = widget.day;
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final d = await WhatChangedData.load(repo, want: _day);
      if (mounted && token == _loadToken) {
        setState(() => (_d = d, _loading = false));
      }
    } catch (_) {
      if (mounted && token == _loadToken) setState(() => _loading = false);
    }
  }

  void _goDay(String day) {
    setState(() {
      _day = day;
      _loading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext c) {
    final d = _d ?? const WhatChangedData();
    final l = AppLocalizations.of(c);
    return detailScaffold(
        c, l?.whatChangedTitle ?? 'What changed',
        sub: l?.whatChangedSub ?? 'AGAINST YOUR OWN HISTORY', [
      ...dayNavRow(_day ?? d.day, d.days, _goDay),
      if (_loading) ...[
        const SizedBox(height: S.x8),
        const Center(child: CircularProgressIndicator()),
      ] else
        ...whatChangedBody(c, d),
    ]);
  }
}

/// The body, given loaded data. Split out so the gallery can build every state
/// without a repository.
List<Widget> whatChangedBody(BuildContext c, WhatChangedData d) {
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  final pairing = sweepPairing(d.findings);
  return [
    if (!d.hadToday)
      StatusCard(
        l?.whatChangedNoDataTitle ?? 'Nothing has landed for this day yet',
        l?.whatChangedNoDataBody ??
            'This day has no values to compare with the days before it, so nothing can stand out.',
        icon: LucideIcons.circleSlash,
      )
    else if (d.findings.isEmpty && d.longestHistory < kSweepMinHistory) ...[
      StatusCard(
        l?.whatChangedLearningTitle ?? 'Still learning your usual',
        l?.whatChangedLearningBody(d.longestHistory, kSweepMinHistory) ??
            'Spotting the unusual needs a range first. There '
                '${d.longestHistory == 1 ? 'is' : 'are'} ${d.longestHistory} '
                'day${d.longestHistory == 1 ? '' : 's'} of history so far; '
                'checks start at $kSweepMinHistory.',
        icon: LucideIcons.hourglass,
      ),
    ] else if (d.findings.isEmpty)
      // The same outcome `kNothingStoodOut` names for the briefing, in the
      // present tense rather than that constant's "tonight": this screen can be
      // steered onto a day in March, and a sentence about tonight is wrong on
      // every one of them.
      StatusCard(
        l?.whatChangedNothingTitle ?? 'Nothing stood out',
        l?.whatChangedNothingBody ??
            'Every metric with enough history sat inside the range your own days '
                'have set. That is the normal answer, and it is a complete one.',
        icon: LucideIcons.check,
      )
    else ...[
      Surface(
        pad: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x2),
        child: Column(
          children: [for (final f in d.findings) SweepFindingRow(f)],
        ),
      ),
      if (pairing != null) ...[
        const SizedBox(height: S.x3),
        Surface(
          color: p.card2,
          elevation: 0,
          child: Text(
            sweepText(l, pairing),
            style: F.cap.copyWith(color: p.ink2, height: 1.5),
          ),
        ),
      ],
      const SizedBox(height: S.x3),
      Text(
        l?.whatChangedMethodologyNote ??
            'Compared with your own recent days, in your own units, with the window shown. Nothing here is a cause or a diagnosis.',
        style: F.over.copyWith(color: p.ink3, height: 1.5),
      ),
    ],
    if (d.day != null) ...[
      const SizedBox(height: S.x4),
      detailLinkRow(
        c,
        LucideIcons.listOrdered,
        l?.whatChangedDayLinkTitle ?? 'What happened that day',
        l?.whatChangedDayLinkSub ?? 'Sleep, sessions, meals and logs in time order',
        () => go(c, DayTimelineScreen(day: d.day)),
      ),
    ],
    if (d.grid.isNotEmpty)
      Section(l?.whatChangedMonthSection ?? 'The month behind it', MonthGrid(d.grid)),
  ];
}

/// One finding, translated for display with its evidence and window intact.
class SweepFindingRow extends StatelessWidget {
  const SweepFindingRow(this.f, {super.key});
  final SweepFinding f;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              f.high ? LucideIcons.arrowUp : LucideIcons.arrowDown,
              size: 17,
              // Direction, in plain ink. A red arrow would be this screen
              // deciding that up is bad, which it cannot know for strain,
              // steps or time asleep.
              color: p.ink3,
            ),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Text(
              sweepText(AppLocalizations.of(c), f.text),
              style: F.body.copyWith(color: p.ink, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
