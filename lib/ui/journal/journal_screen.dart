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

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart';
import '../design/design.dart';
import 'journal_compose_screen.dart';

class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key});
  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  // Preset tag vocabulary shown as toggle chips.
  static const _presetTags = <String>[
    'caffeine', 'alcohol', 'late meal', 'stress', 'poor sleep', 'travel',
    'screens late', 'meds', 'sick', 'sauna', 'cold plunge', 'social',
    'workout', 'rest day',
  ];

  final _noteCtrl = TextEditingController();
  final Set<String> _selectedTags = <String>{};

  // The day being edited (defaults to today; a recent-day tap rebinds it).
  String _editingDate = _fmtDate(DateTime.now());

  // Loaded data.
  List<_JournalRow> _rows = const [];
  List<Map<String, dynamic>> _insights = const [];

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
      try {
        final ins = await api.getJournalInsights(range: '90d');
        insights = ((ins['insights'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      } catch (_) {
        // Insights are optional — never fail the screen for them.
      }

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _insights = insights;
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
          Ic.ai,
          osIcon: OsIcon.ai,
          onTap: () => Navigator.of(context)
              .push(themedRoute((_) => const JournalComposeScreen()))
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
                icon: Ic.profile,
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
                icon: Ic.cloud,
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
                'How each tag tracks with your recovery, sleep and heart data — '
                'computed from your own tagged days only.',
            methodNote: 'Correlation, not cause · needs ≥3 tagged days per tag',
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
                  (_isToday ? "TODAY'S TAGS" : 'EDITING $_editingDate')
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
          icon: Ic.calendar,
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
    if (_insights.isEmpty) {
      return const [
        StateCard(
          icon: Ic.chart,
          title: 'Insights build over time',
          message:
              'Tag at least 3 days with how you lived, and OpenStrap starts '
              'surfacing how each habit tracks with your recovery, sleep and '
              'heart rate — drawn from your own data.',
        ),
      ];
    }
    return [
      for (var i = 0; i < _insights.length; i++) ...[
        JournalInsightCard(insight: _insights[i]).dsEnter(index: i),
        if (i != _insights.length - 1) const SizedBox(height: Sp.x3),
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
          icon: better ? Ic.up : Ic.down,
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
