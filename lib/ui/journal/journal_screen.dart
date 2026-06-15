// Journal — log daily tags and a note, browse recent days, and see correlations
// from your own data. Uses getJournal / getJournalInsights / postJournal.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../net/api_client.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

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
  List<_Insight> _insights = const [];

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

  ApiClient? get _api => context.read<AppState>().api;

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

      List<_Insight> insights = const [];
      try {
        final ins = await api.getJournalInsights(range: '90d');
        final list = (ins['insights'] as List?) ?? const [];
        insights = list
            .whereType<Map>()
            .map((e) => _Insight.fromJson(e.cast<String, dynamic>()))
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
        _error = e is ApiException ? e.body : e.toString();
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
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          color: AppColors.coral,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: Sp.screen),
            children: [
              const SizedBox(height: Sp.x4),
              _topBar(),
              const SizedBox(height: Sp.x6),
              if (_noApi)
                _stateCard(
                  icon: Ic.profile,
                  title: 'Sign in to journal',
                  message:
                      'Your journal syncs with your account. Sign in to log '
                      'tags and unlock insights from your own data.',
                )
              else if (_loading)
                ..._skeleton()
              else if (_error != null)
                _stateCard(
                  icon: Ic.cloud,
                  title: "Couldn't load journal",
                  message: _error!,
                )
              else
                ..._content(),
              const SizedBox(height: 110),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).pop()),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Journal', style: AppText.h1),
              const SizedBox(height: 4),
              Text('Tag your days — see what moves your body',
                  style: AppText.caption),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _content() {
    return [
      _editorCard(),
      const SizedBox(height: Sp.x6),
      SectionHeader('Recent days'),
      _recentList(),
      const SizedBox(height: Sp.x6),
      SectionHeader('What moves your body'),
      ..._insightsSection(),
    ];
  }

  // ── editor ──────────────────────────────────────────────────────────────────

  Widget _editorCard() {
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(Ic.edit, size: 19, color: AppColors.coral),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Text(
                  _isToday ? "Today's tags" : 'Editing $_editingDate',
                  style: AppText.h2,
                ),
              ),
              if (!_isToday)
                GestureDetector(
                  onTap: () => _bindEditor(_fmtDate(DateTime.now())),
                  child: Tag('today', color: AppColors.coral),
                ),
            ],
          ),
          const SizedBox(height: Sp.x4),
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final tag in _presetTags)
                _tagChip(tag, _selectedTags.contains(tag)),
            ],
          ),
          const SizedBox(height: Sp.x5),
          TextField(
            controller: _noteCtrl,
            minLines: 2,
            maxLines: 5,
            style: AppText.body,
            decoration: const InputDecoration(
              hintText: 'Anything notable? (optional note)',
            ),
          ),
          const SizedBox(height: Sp.x4),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white),
                  )
                : Text(_isToday ? 'Save day' : 'Save $_editingDate'),
          ),
        ],
      ),
    );
  }

  Widget _tagChip(String tag, bool selected) {
    return GestureDetector(
      onTap: () => setState(() {
        if (selected) {
          _selectedTags.remove(tag);
        } else {
          _selectedTags.add(tag);
        }
      }),
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding:
            const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
        decoration: BoxDecoration(
          color: selected ? AppColors.coral : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(R.pill),
        ),
        child: Text(
          tag,
          style: AppText.label.copyWith(
            color: selected ? Colors.white : AppColors.inkSoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  // ── recent days ───────────────────────────────────────────────────────────────

  Widget _recentList() {
    if (_rows.isEmpty) {
      return _stateCard(
        icon: Ic.calendar,
        title: 'No entries yet',
        message: 'Tag today above and your recent days will appear here.',
      );
    }
    return Column(
      children: [
        for (int i = 0; i < _rows.length; i++) ...[
          _recentTile(_rows[i]),
          if (i != _rows.length - 1) const SizedBox(height: Sp.x3),
        ],
      ],
    );
  }

  Widget _recentTile(_JournalRow row) {
    final active = row.date == _editingDate;
    return ProCard(
      onTap: () => _bindEditor(row.date),
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_prettyDate(row.date),
                    style: AppText.title, maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (active)
                Tag('editing', color: AppColors.coral)
              else
                AppIcon(Ic.edit, size: 16, color: AppColors.inkMuted),
            ],
          ),
          if (row.tags.isNotEmpty) ...[
            const SizedBox(height: Sp.x3),
            Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [for (final t in row.tags) _readChip(t)],
            ),
          ],
          if (row.note.isNotEmpty) ...[
            const SizedBox(height: Sp.x3),
            Text(
              row.note,
              style: AppText.bodySoft,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _readChip(String tag) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.coralSoft,
          borderRadius: BorderRadius.circular(R.pill),
        ),
        child: Text(tag,
            style: AppText.caption.copyWith(
                color: AppColors.coralInk, fontWeight: FontWeight.w600)),
      );

  // ── insights ──────────────────────────────────────────────────────────────────

  List<Widget> _insightsSection() {
    if (_insights.isEmpty) {
      return [
        _stateCard(
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
      for (int i = 0; i < _insights.length; i++) ...[
        _insightCard(_insights[i]),
        if (i != _insights.length - 1) const SizedBox(height: Sp.x3),
      ],
      const SizedBox(height: Sp.x4),
      _honestyFooter(),
    ];
  }

  Widget _insightCard(_Insight insight) {
    // Show the top 2-3 effects.
    final effects = insight.effects.take(3).toList();
    return ProCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(insight.tag, style: AppText.h2,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: Sp.x2),
              Text('${insight.days} days', style: AppText.captionMuted),
            ],
          ),
          const SizedBox(height: Sp.x4),
          for (int i = 0; i < effects.length; i++) ...[
            _effectRow(effects[i]),
            if (i != effects.length - 1) const SizedBox(height: Sp.x3),
          ],
        ],
      ),
    );
  }

  Widget _effectRow(_Effect e) {
    final c = e.better ? AppColors.good : AppColors.bad;
    final sign = e.deltaPct >= 0 ? '+' : '−';
    final pct = '$sign${e.deltaPct.abs().toStringAsFixed(1)}%';
    return Row(
      children: [
        Expanded(
          child: Text(e.label, style: AppText.body,
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: Sp.x3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 3),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(R.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(e.better ? Ic.up : Ic.down, size: 13, color: c),
              const SizedBox(width: 3),
              Text(pct,
                  style: AppText.caption
                      .copyWith(color: c, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        if (e.nWith > 0) ...[
          const SizedBox(width: Sp.x2),
          Text('· ${e.nWith} days', style: AppText.captionMuted),
        ],
      ],
    );
  }

  Widget _honestyFooter() {
    return Row(
      children: [
        AppIcon(Ic.info, size: 14, color: AppColors.inkMuted),
        const SizedBox(width: Sp.x2),
        Expanded(
          child: Text(
            'Patterns from your own data — correlation, not cause.',
            style: AppText.captionMuted,
          ),
        ),
      ],
    );
  }

  // ── shared state cards / skeleton ──────────────────────────────────────────────

  Widget _stateCard({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return ProCard(
      padding: const EdgeInsets.all(Sp.x6),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(Sp.x4),
            decoration: BoxDecoration(
              color: AppColors.coralSoft,
              shape: BoxShape.circle,
            ),
            child: AppIcon(icon, size: 28, color: AppColors.coralDeep),
          ),
          const SizedBox(height: Sp.x4),
          Text(title, style: AppText.h2, textAlign: TextAlign.center),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.bodySoft, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  List<Widget> _skeleton() => const [
        ProCard(child: SizedBox(height: 220)),
        SizedBox(height: Sp.x6),
        ProCard(padding: EdgeInsets.all(Sp.x4), child: SizedBox(height: 64)),
        SizedBox(height: Sp.x3),
        ProCard(padding: EdgeInsets.all(Sp.x4), child: SizedBox(height: 64)),
        SizedBox(height: Sp.x6),
        ProCard(child: SizedBox(height: 120)),
      ];
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
String _prettyDate(String iso) {
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
  final s = e is ApiException ? e.body : e.toString();
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
        ((j['tags'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        (j['note'] ?? '').toString(),
      );
}

class _Insight {
  final String tag;
  final int days;
  final List<_Effect> effects;
  const _Insight(this.tag, this.days, this.effects);

  factory _Insight.fromJson(Map<String, dynamic> j) => _Insight(
        (j['tag'] ?? '').toString(),
        (j['days'] as num?)?.toInt() ?? 0,
        ((j['effects'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => _Effect.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

class _Effect {
  final String label;
  final double deltaPct;
  final bool better;
  final int nWith;
  const _Effect(this.label, this.deltaPct, this.better, this.nWith);

  factory _Effect.fromJson(Map<String, dynamic> j) => _Effect(
        (j['label'] ?? '').toString(),
        (j['delta_pct'] as num?)?.toDouble() ?? 0,
        j['better'] == true,
        (j['n_with'] as num?)?.toInt() ?? 0,
      );
}
