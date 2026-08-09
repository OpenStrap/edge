// Labs — hand-entered blood work, with a trend per marker.
//
// The band cannot measure any of this. That is the point: a ferritin or an
// HbA1c is the context that makes a year of resting-HR drift mean something,
// and it is the one health record people already have and cannot keep anywhere
// local.
//
// The honesty line this screen holds: a value is shown against a TYPICAL adult
// reference interval, never against a verdict. Out-of-range reads as "outside
// the typical range", never "high" or "abnormal", because every laboratory
// publishes its own interval and the one on the user's own report is the one
// that applies to them. The screen never suggests what to do about a value.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../data/lab_catalogue.dart';
import '../../state/app_state.dart';
import '../design/design.dart';
import 'lab_entry_sheet.dart';

class LabsScreen extends StatefulWidget {
  const LabsScreen({super.key});
  @override
  State<LabsScreen> createState() => _LabsScreenState();
}

class _LabsScreenState extends State<LabsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _results = const [];
  List<LabMarker> _custom = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await LocalDb.labResults();
      final defs = await LocalDb.labMarkerDefs();
      if (!mounted) return;
      setState(() {
        _results = rows;
        _custom = [
          for (final d in defs)
            LabMarker(
              key: d['key'] as String,
              label: d['label'] as String,
              unit: d['unit'] as String,
              category: LabCategory.values.firstWhere(
                (c) => c.name == d['category'],
                orElse: () => LabCategory.blood,
              ),
              decimals: (d['decimals'] as num?)?.toInt() ?? 1,
              ranges: [
                if (d['ref_low'] != null && d['ref_high'] != null)
                  LabRefRange(
                    low: (d['ref_low'] as num).toDouble(),
                    high: (d['ref_high'] as num).toDouble(),
                  ),
              ],
              custom: true,
            ),
        ];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }


  Future<void> _add() async {
    if (await showLabEntrySheet(context, custom: _custom) && mounted) {
      await _load();
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final ok = await showLabEntrySheet(
      context,
      custom: _custom,
      existing: row,
    );
    if (ok && mounted) await _load();
  }

  /// Results grouped by marker, newest draw first within each.
  Map<String, List<Map<String, dynamic>>> get _byMarker {
    final out = <String, List<Map<String, dynamic>>>{};
    for (final r in _results) {
      (out[r['marker'] as String] ??= []).add(r);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _byMarker;
    // Watched, not read: setting a sex in Profile and coming back here has to
    // re-resolve the reference intervals, and several markers show none at all
    // until it is set. `read` would have left them resolved against the old
    // value until something else happened to rebuild this screen.
    final sex = context
        .select<AppState, String?>((a) => a.user?['sex'] as String?)
        ?.toLowerCase();
    return AppScaffold(
      title: 'Labs',
      actions: [
        Semantics(
          button: true,
          label: 'Add a lab result',
          child: Pressable(
            pressedScale: 0.94,
            onTap: _add,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Sp.x4,
                vertical: Sp.x3,
              ),
              decoration: BoxDecoration(
                color: AppColors.tonalFill(AppColors.accent),
                borderRadius: BorderRadius.circular(R.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 18, color: AppColors.accent),
                  const SizedBox(width: Sp.x1),
                  Text(
                    'Add',
                    style: AppText.label.copyWith(color: AppColors.accent),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppColors.accent,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            Sp.screen,
            Sp.x2,
            Sp.screen,
            dsBottomGutter(context),
          ),
          children: [
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Sp.x4),
                child: Skeleton.tileRow(rows: 3),
              )
            else if (grouped.isEmpty)
              StateCard(
                icon: OsIcon.ecgRhythm,
                title: 'No results yet',
                message: 'Add a blood test and it stays on this phone, next to '
                    'everything the band measures.',
                actionLabel: 'Add a result',
                onAction: _add,
              )
            else ...[
              for (final entry in grouped.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x3),
                  child: _MarkerCard(
                    marker: labMarker(entry.key, custom: _custom),
                    fallbackKey: entry.key,
                    results: entry.value,
                    sex: sex,
                    onTapResult: _edit,
                  ),
                ),
              const SizedBox(height: Sp.x3),
              Text(
                'Ranges shown are typical adult reference intervals, for '
                'context only. Every laboratory publishes its own, and the one '
                'printed on your report is the one that applies to you.',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MarkerCard extends StatelessWidget {
  const _MarkerCard({
    required this.marker,
    required this.fallbackKey,
    required this.results,
    required this.sex,
    required this.onTapResult,
  });

  /// Null when the definition is gone but its results remain — a deleted
  /// custom marker. Those still render, from the unit stored on each row.
  final LabMarker? marker;
  final String fallbackKey;
  final List<Map<String, dynamic>> results;
  final String? sex;
  final ValueChanged<Map<String, dynamic>> onTapResult;

  @override
  Widget build(BuildContext context) {
    final m = marker;
    final latest = results.first;
    final value = (latest['value'] as num).toDouble();
    final unit = latest['unit'] as String;
    final inRange = m?.inRange(value, sex: sex);
    final range = m?.rangeFor(sex);

    return SurfaceCard(
      padding: const EdgeInsets.all(Sp.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(m?.label ?? fallbackKey, style: AppText.title),
              ),
              Text(
                m == null ? '$value $unit' : '${m.format(value)} $unit',
                style: AppText.title.copyWith(
                  // No colour at all when there is no interval to judge
                  // against — a neutral number, not a quiet reassurance.
                  color: inRange == null
                      ? AppColors.ink
                      : (inRange ? AppColors.good : AppColors.warn),
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.x1),
          Row(
            children: [
              Expanded(
                child: Text(
                  latest['taken_on'] as String,
                  style: AppText.caption.copyWith(color: AppColors.inkMuted),
                ),
              ),
              if (range != null)
                Text(
                  inRange == true
                      ? 'within the typical range'
                      : 'outside the typical range',
                  style: AppText.caption.copyWith(color: AppColors.inkMuted),
                ),
            ],
          ),
          if (m?.note != null) ...[
            const SizedBox(height: Sp.x2),
            Text(
              m!.note!,
              style: AppText.caption.copyWith(color: AppColors.inkMuted),
            ),
          ],
          if (results.length > 1) ...[
            const SizedBox(height: Sp.x3),
            const Divider(height: 1),
            const SizedBox(height: Sp.x2),
            for (final r in results)
              Pressable(
                pressedScale: 0.98,
                onTap: () => onTapResult(r),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.x1),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          r['taken_on'] as String,
                          style: AppText.bodySoft,
                        ),
                      ),
                      Text(
                        // The row's own unit, always — the definition may have
                        // changed its canonical unit since this was entered,
                        // and only the row knows what was measured.
                        m == null
                            ? '${r['value']} ${r['unit']}'
                            : '${m.format((r['value'] as num).toDouble())} '
                                  '${r['unit']}',
                        style: AppText.body,
                      ),
                    ],
                  ),
                ),
              ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: Sp.x2),
              child: Pressable(
                pressedScale: 0.96,
                onTap: () => onTapResult(latest),
                child: Text(
                  'Edit',
                  style: AppText.label.copyWith(color: AppColors.accent),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
