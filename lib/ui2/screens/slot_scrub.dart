// One day-per-slot chart that reads under the finger: a scroll-first
// [Scrubber] over the plot and an always-present [ChartPanel] under it.
//
// Used by the Health HRV line, the two Workout bar charts and the month-grid
// strips, which all share the same shape: `series` has one slot per calendar
// day, the last slot is the caller's anchor day, a null slot is a day with nothing recorded. The
// panel reads LATEST on the newest recorded day and SELECTED on the touched
// one; a null day reads a dash, never a neighbour.
import 'package:flutter/material.dart';

import '../../data/day_label.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'metric_detail.dart' show dayNavLabel;

class SlotScrub extends StatefulWidget {
  const SlotScrub({
    super.key,
    required this.series,
    required this.anchor,
    required this.bars,
    required this.label,
    required this.color,
    required this.format,
    required this.builder,
    this.dayWord,
  });

  /// One slot per calendar day, oldest first, the last slot on [anchor].
  final List<double?> series;

  /// The calendar day of the last slot: the day the series was built for, not
  /// the day it is touched. A chart left open across midnight keeps labelling
  /// its data with the days the data is from.
  final DateTime anchor;

  /// Bars sit in the middle of their slot (`(i + .5) / n`); a line has its
  /// points on the ends (`i / (n - 1)`).
  final bool bars;

  /// What the chart is, for the slider and the panel's cell.
  final String label;

  /// The series colour, already resolved for the theme.
  final Color color;

  /// A recorded value as the panel and the slider say it.
  final String Function(double v) format;

  /// The caller's own word for a slot (HRV calls its last slot "Last night"),
  /// or null to use the day name. The panel and the slider both use it.
  final String? Function(int slot)? dayWord;

  /// [scrub] wraps the painted plot; [panel] goes under the chart; [pick] is
  /// the touched slot (null at rest) for a painter that highlights it.
  final Widget Function(BuildContext context, int? pick,
      Widget Function(Widget plot) scrub, Widget panel) builder;

  @override
  State<SlotScrub> createState() => _SlotScrubState();
}

class _SlotScrubState extends State<SlotScrub> {
  int? _pick;

  int get _n => widget.series.length;

  int _slot(double v) => widget.bars
      ? (v * _n).floor().clamp(0, _n - 1)
      : (v * (_n - 1)).round().clamp(0, _n - 1);

  double _at(int i) => widget.bars ? (i + .5) / _n : i / (_n - 1);

  String _day(BuildContext c, int slot) {
    final word = widget.dayWord?.call(slot);
    if (word != null) return word;
    final a = widget.anchor;
    return dayNavLabel(
        dayLabelOf(DateTime(a.year, a.month, a.day - (_n - 1 - slot))),
        AppLocalizations.of(c));
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final s = widget.series;
    var latest = _n - 1;
    while (latest > 0 && s[latest] == null) {
      latest--;
    }
    // No slots at all: nothing to read, so an empty reading.
    final shown = _n == 0 ? null : (_pick ?? latest).clamp(0, _n - 1);
    final v = shown == null ? null : s[shown];
    // No slot has a value: LATEST would name a day with no reading.
    final none = _pick == null && v == null;
    final panel = ChartPanel(
      time: none || shown == null ? null : _day(c, shown),
      timeSpan: [for (var i = 0; i < _n; i++) _day(c, i)],
      scrubbed: _pick != null,
      color: widget.color,
      cells: [
        ChartPanelCell(widget.label,
            color: widget.color, value: v == null ? null : widget.format(v)),
      ],
    );
    Widget scrub(Widget plot) => _n < 2
        ? plot
        : Scrubber(
            value: _pick == null ? null : _at(_pick!),
            step: 1 / (widget.bars ? _n : _n - 1),
            label: widget.label,
            describe: (x) {
              final i = _slot(x);
              final day = _day(c, i);
              final at = s[i];
              return at == null
                  ? (l?.metricDetailSlotNoRecord(day) ?? '$day, no record')
                  : '$day, ${widget.format(at)}';
            },
            onChanged: (x) => setState(() => _pick = _slot(x)),
            child: plot,
          );
    return widget.builder(c, _pick, scrub, panel);
  }
}
