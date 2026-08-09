// Journal — log daily tags and a note, browse recent days, and see correlations
// from your own data. Uses getJournal / getJournalInsights / postJournal.
//
// On the design language: AppScaffold chrome, a SurfaceCard editor with soft
// multi-select tag chips, recent days as quiet tiles, and each insight as a
// card whose effects read as tinted delta pills. Correlation honesty lives
// behind the (i) and a whispered footer.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/journal_ai.dart' show kJournalPresetTags;
import '../../data/journal_fields.dart';
import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart';
import '../design/design.dart';
import 'custom_journal_field_sheet.dart';
import 'journal_compose_screen.dart';
import 'journal_metric_editor.dart';

class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key});
  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  // Preset tag vocabulary shown as toggle chips. Shared with the compose
  // screen and the AI prompt — this used to be a second private copy, which is
  // how the two screens would have drifted apart the first time either list
  // changed.
  static const _presetTags = kJournalPresetTags;

  /// Built-in numeric fields followed by the user's own.
  List<JournalFieldSpec> _fieldSpecs = kJournalFields;

  /// The editing day's numeric values. A field absent here is unset, which is
  /// a different state from zero.
  Map<String, JournalMetricValue> _metrics = const {};

  final _noteCtrl = TextEditingController();
  final Set<String> _selectedTags = <String>{};

  // The day being edited (defaults to today; a recent-day tap rebinds it).
  String _editingDate = _fmtDate(DateTime.now());

  // Loaded data.
  List<_JournalRow> _rows = const [];
  List<Map<String, dynamic>> _insights = const [];

  /// Rank correlations over the numeric fields. Kept apart from [_insights]
  /// because they answer a different question and carry different evidence —
  /// a tag says "those days were different", a dose says "more of this goes
  /// with less of that".
  List<Map<String, dynamic>> _numericInsights = const [];

  bool _loading = true;
  bool _saving = false;
  String? _error; // network/load error
  bool _noApi = false; // not signed in / api null

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  // ── data ────────────────────────────────────────────────────────────────────

  LocalRepository? get _api => context.read<AppState>().repo;

  Future<void> _load() async {
    final api = _api;
    if (api == null) {
      setState(() {
        _loading = false;
        _noApi = true;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _noApi = false;
    });
    try {
      // Journal list is required; insights are best-effort (engine may have none).
      final journal = await api.getJournal(range: '30d');
      final rows = journal.map(_JournalRow.fromJson).toList();

      List<Map<String, dynamic>> insights = const [];
      List<Map<String, dynamic>> numeric = const [];
      try {
        final ins = await api.getJournalInsights(range: '90d');
        insights = ((ins['insights'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        numeric = ((ins['numeric_insights'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      } catch (_) {
        // Insights are optional — never fail the screen for them.
      }

      final specs = await api.getJournalFields();

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _insights = insights;
        _numericInsights = numeric;
        _fieldSpecs = specs;
        _loading = false;
      });
      _bindEditor(_editingDate);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  /// Load the given date's existing tags + note into the editor (if present).
  void _bindEditor(String date) {
    final existing = _rows.where((r) => r.date == date).toList();
    setState(() {
      _editingDate = date;
      _selectedTags
        ..clear()
        ..addAll(existing.isEmpty ? const <String>[] : existing.first.tags);
      _noteCtrl.text = existing.isEmpty ? '' : existing.first.note;
      // Cleared immediately rather than left showing the previous day's
      // numbers while the read is in flight — a stale 3 coffees sitting in the
      // editor is one Save away from becoming a reading the user never made.
      _metrics = const {};
    });
    unawaited(_loadMetricsFor(date));
  }

  Future<void> _loadMetricsFor(String date) async {
    final api = _api;
    if (api == null) return;
    try {
      final m = await api.getJournalMetrics(date);
      // The user can rebind to another day while this is in flight; only the
      // read for the day still on screen may land.
      if (!mounted || _editingDate != date) return;
      setState(() => _metrics = m);
    } catch (_) {
      // The tags editor still works without them.
    }
  }

  Future<void> _addCustomField() async {
    final api = _api;
    if (api == null) return;
    final spec = await showCustomJournalFieldSheet(
      context,
      existingKeys: _fieldSpecs.map((f) => f.key).toSet(),
    );
    if (spec == null) return;
    await api.postCustomJournalField(spec);
    if (!mounted) return;
    setState(() => _fieldSpecs = [..._fieldSpecs, spec]);
  }

  Future<void> _removeCustomField(JournalFieldSpec spec) async {
    final api = _api;
    if (api == null) return;
    await api.deleteCustomJournalField(spec.key);
    if (!mounted) return;
    setState(() {
      _fieldSpecs = [..._fieldSpecs]..removeWhere((f) => f.key == spec.key);
      // Its recorded values are deliberately left in the database — those
      // readings were real, and forgetting a label should not delete history.
      _metrics = {..._metrics}..remove(spec.key);
    });
  }

  Future<void> _save() async {
    final api = _api;
    if (api == null || _saving) return;
    setState(() => _saving = true);
    try {
      await api.postJournal(
        _editingDate,
        _selectedTags.toList(),
        _noteCtrl.text.trim(),
      );
      await api.postJournalMetrics(_editingDate, _metrics);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${_isToday ? 'today' : _editingDate}')),
      );
      await _load(); // refresh recent days + insights
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn\'t save — ${_shortErr(e)}')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _isToday => _editingDate == _fmtDate(DateTime.now());

  // ── build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Journal',
      subtitle: 'What you did — what it moved',
      actions: [
        // Talk-it-through entry point (manual + AI chat compose).
        RoundIconButton(
          OsIcon.ai,
          onTap: () => Navigator.of(context)
              .push(themedRoute((_) => const JournalComposeScreen(),
                  name: 'JournalComposeScreen'))
              .then((_) => _load()),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.accent,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding:
              const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x8),
          children: [
            if (_noApi)
              StateCard(
                icon: OsIcon.profile,
                title: 'Journal unavailable',
                message: 'Pair your strap to log tags and unlock insights '
                    'from your own data.',
              ).dsEnter()
            else if (_loading) ...[
              Skeleton.box(height: 220),
              const SizedBox(height: Sp.x3),
              Skeleton.tileRow(rows: 2),
            ] else if (_error != null)
              StateCard(
                icon: OsIcon.sync,
                title: "Couldn't load journal",
                message: _error!,
                actionLabel: 'Try again',
                onAction: _load,
              ).dsEnter()
            else
              ..._content(),
          ],
        ),
      ),
    );
  }

  List<Widget> _content() {
    return [
      _editorCard().dsEnter(index: 0),
      const SizedBox(height: Sp.x6),
      const SectionHeader('Recent days'),
      ..._recentList(),
      const SizedBox(height: Sp.x6),
      Row(
        children: [
          const Expanded(child: SectionHeader('What moves your body')),
          InfoDot(
            title: 'What moves your body',
            body:
                'How what you log tracks with your recovery, sleep and heart '
                'data — computed from your own days only. Tags are compared as '
                'happened-or-not; numbers are ranked, so five coffees and one '
                'are not the same day.',
            methodNote: 'Correlation, not cause · tags need ≥3 tagged days, '
                'numbers need ≥8 days with a value',
          ),
        ],
      ),
      ..._insightsSection(),
    ];
  }

  // ── editor ──────────────────────────────────────────────────────────────────

  Widget _editorCard() {
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (_isToday ? 'TODAY' : 'EDITING $_editingDate')
                      .toUpperCase(),
                  style: AppText.overline.copyWith(color: AppColors.inkMuted),
                ),
              ),
              if (!_isToday)
                Pressable(
                  pressedScale: 0.94,
                  onTap: () => _bindEditor(_fmtDate(DateTime.now())),
                  child: const StatusChip('Back to today',
                      tone: ChipTone.accent),
                ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Text(
            'TAGS',
            style: AppText.overline.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: Sp.x2),
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final tag in _presetTags)
                ToggleChip(
                  tag,
                  selected: _selectedTags.contains(tag),
                  onTap: () => setState(() {
                    if (!_selectedTags.remove(tag)) _selectedTags.add(tag);
                  }),
                ),
            ],
          ),
          const SizedBox(height: Sp.x5),
          Text(
            'NUMBERS',
            style: AppText.overline.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: Sp.x3),
          JournalMetricEditor(
            specs: _fieldSpecs,
            values: _metrics,
            onChanged: (m) => setState(() => _metrics = m),
            onAddField: _addCustomField,
            onRemoveField: _removeCustomField,
          ),
          const SizedBox(height: Sp.x4),
          TextField(
            controller: _noteCtrl,
            minLines: 2,
            maxLines: 5,
            style: AppText.body,
            decoration: InputDecoration(
              hintText: 'Anything notable? (optional note)',
              hintStyle: AppText.bodySoft.copyWith(color: AppColors.inkMuted),
              filled: true,
              fillColor: AppColors.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(R.cardSm),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: Sp.x4),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(
                _saving
                    ? 'Saving…'
                    : (_isToday ? 'Save day' : 'Save $_editingDate'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── recent days ─────────────────────────────────────────────────────────────

  List<Widget> _recentList() {
    if (_rows.isEmpty) {
      return [
        const StateCard(
          icon: OsIcon.calendar,
          title: 'No entries yet',
          message: 'Tag today above and your recent days will appear here.',
        ),
      ];
    }
    return [
      for (var i = 0; i < _rows.length; i++) ...[
        JournalDayTile(
          date: _rows[i].date,
          tags: _rows[i].tags,
          note: _rows[i].note,
          active: _rows[i].date == _editingDate,
          onTap: () => _bindEditor(_rows[i].date),
        ).dsEnter(index: i + 1),
        if (i != _rows.length - 1) const SizedBox(height: Sp.x3),
      ],
    ];
  }

  // ── insights ────────────────────────────────────────────────────────────────

  List<Widget> _insightsSection() {
    if (_insights.isEmpty && _numericInsights.isEmpty) {
      return const [
        StateCard(
          icon: OsIcon.activity,
          title: 'Insights build over time',
          message:
              'Log a few days — tags, numbers or both — and OpenStrap starts '
              'surfacing how each habit tracks with your recovery, sleep and '
              'heart rate, drawn from your own data.',
        ),
      ];
    }
    return [
      for (var i = 0; i < _insights.length; i++) ...[
        JournalInsightCard(insight: _insights[i]).dsEnter(index: i),
        if (i != _insights.length - 1) const SizedBox(height: Sp.x3),
      ],
      if (_numericInsights.isNotEmpty) ...[
        if (_insights.isNotEmpty) const SizedBox(height: Sp.x4),
        const SectionHeader('How much of it'),
        for (var i = 0; i < _numericInsights.length; i++) ...[
          JournalDoseInsightCard(
            insight: _numericInsights[i],
          ).dsEnter(index: i),
          if (i != _numericInsights.length - 1) const SizedBox(height: Sp.x3),
        ],
      ],
      const SizedBox(height: Sp.x4),
      Center(
        child: Text(
          'Patterns from your own data — correlation, not cause.',
          style: AppText.captionMuted,
        ),
      ),
    ];
  }
}

// ── pure presentation widgets (render-testable) ────────────────────────────────

/// One recent journal day — date, its tags as quiet chips, a note preview.
class JournalDayTile extends StatelessWidget {
  final String date; // 'YYYY-MM-DD'
  final List<String> tags;
  final String note;
  final bool active;
  final VoidCallback? onTap;
  const JournalDayTile({
    super.key,
    required this.date,
    required this.tags,
    required this.note,
    this.active = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(prettyJournalDate(date),
                    style: AppText.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (active)
                const StatusChip('Editing', tone: ChipTone.accent)
              else if (onTap != null)
                const OsAppIcon(OsIcon.edit, size: 22),
            ],
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: Sp.x3),
            Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [for (final t in tags) StatusChip(t)],
            ),
          ],
          if (note.isNotEmpty) ...[
            const SizedBox(height: Sp.x3),
            Text(
              note,
              style: AppText.bodySoft,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// One tag's correlation card — the tag, how many days it was logged, and the
/// top effects as tinted delta pills. Parses the /journal/insights row shape
/// defensively (presentation only).
class JournalInsightCard extends StatelessWidget {
  final Map<String, dynamic> insight;
  const JournalInsightCard({super.key, required this.insight});

  @override
  Widget build(BuildContext context) {
    final tag = (insight['tag'] ?? '').toString();
    final days = (insight['days'] as num?)?.toInt() ?? 0;
    final effects = ((insight['effects'] as List?) ?? const [])
        .whereType<Map>()
        .take(3)
        .toList();
    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(tag,
                    style: AppText.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: Sp.x2),
              Text('$days days', style: AppText.captionMuted),
            ],
          ),
          const SizedBox(height: Sp.x3),
          for (var i = 0; i < effects.length; i++) ...[
            _effectRow(effects[i]),
            if (i != effects.length - 1) const SizedBox(height: Sp.x2),
          ],
        ],
      ),
    );
  }

  Widget _effectRow(Map e) {
    final label = (e['label'] ?? '').toString();
    final deltaPct = (e['delta_pct'] as num?)?.toDouble() ?? 0;
    final better = e['better'] == true;
    final nWith = (e['n_with'] as num?)?.toInt() ?? 0;
    final sign = deltaPct >= 0 ? '+' : '−';
    final pct = '$sign${deltaPct.abs().toStringAsFixed(1)}%';
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: AppText.body, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: Sp.x3),
        StatusChip(
          pct,
          icon: better ? OsIcon.up : OsIcon.down,
          tone: better ? ChipTone.positive : ChipTone.critical,
        ),
        if (nWith > 0) ...[
          const SizedBox(width: Sp.x2),
          Text('· $nWith days', style: AppText.captionMuted),
        ],
      ],
    );
  }
}

// ── formatting helpers (no intl) ────────────────────────────────────────────────

/// 'YYYY-MM-DD' for the API.
String _fmtDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// 'Jun 11' (or 'Today' / 'Yesterday' for the obvious cases). Falls back to the
/// raw string if it doesn't parse as YYYY-MM-DD.
String prettyJournalDate(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final today = DateTime.now();
  final t0 = DateTime(today.year, today.month, today.day);
  final d0 = DateTime(parsed.year, parsed.month, parsed.day);
  final diff = t0.difference(d0).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return '${_months[parsed.month - 1]} ${parsed.day}';
}

String _shortErr(Object e) {
  final s = e is RepositoryException ? e.body : e.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

// ── models (parsed defensively) ────────────────────────────────────────────────

class _JournalRow {
  final String date;
  final List<String> tags;
  final String note;
  const _JournalRow(this.date, this.tags, this.note);

  factory _JournalRow.fromJson(Map<String, dynamic> j) => _JournalRow(
        (j['date'] ?? '').toString(),
        ((j['tags'] as List?) ?? const []).map((e) => e.toString()).toList(),
        (j['note'] ?? '').toString(),
      );
}

/// One numeric-field finding: "each extra coffee, about 4 ms less HRV".
///
/// Deliberately leads with the SLOPE in the outcome's own units, not with the
/// correlation coefficient. Rho carries whether the relationship holds at all
/// and is shown as supporting detail; "0.62" is not a sentence anybody can act
/// on, and "about 4 ms per cup" is.
class JournalDoseInsightCard extends StatelessWidget {
  final Map<String, dynamic> insight;
  const JournalDoseInsightCard({super.key, required this.insight});

  @override
  Widget build(BuildContext context) {
    final field = (insight['field_label'] ?? '').toString();
    final fieldUnit = (insight['field_unit'] ?? '').toString();
    final outcome = (insight['outcome_label'] ?? '').toString();
    final outcomeUnit = (insight['unit'] ?? '').toString();
    final slope = (insight['slope_per_unit'] as num?)?.toDouble();
    final rho = (insight['rho'] as num?)?.toDouble() ?? 0;
    final n = (insight['n'] as num?)?.toInt() ?? 0;
    final helped = insight['helped'] == true;
    final tint = helped ? AppColors.good : AppColors.warn;

    // "per 250 ml", "per unit", or just "per point" for a 1–5 rating.
    final per = fieldUnit.isEmpty ? 'point' : fieldUnit;

    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(field, style: AppText.title)),
              Text(
                '$n days',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ),
          const SizedBox(height: Sp.x2),
          Text(
            slope == null
                // Theil–Sen could not fit a slope. The direction still holds,
                // so say that and nothing more rather than invent a magnitude.
                ? '${rho > 0 ? 'More' : 'Less'} $field goes with '
                      'higher $outcome'
                : 'About ${_fmtSlope(slope)}'
                      '${outcomeUnit.isEmpty ? '' : ' $outcomeUnit'} '
                      '$outcome per extra $per',
            style: AppText.body.copyWith(color: tint),
          ),
          const SizedBox(height: Sp.x1),
          Text(
            'rank correlation ${rho.toStringAsFixed(2)}',
            style: AppText.captionMuted,
          ),
        ],
      ),
    );
  }

  /// Signed, so "−4 ms" reads as a fall rather than needing the sentence to
  /// carry the direction separately.
  String _fmtSlope(double v) {
    final a = v.abs();
    final s = a >= 10 ? a.round().toString() : a.toStringAsFixed(1);
    return v < 0 ? '−$s' : '+$s';
  }
}
