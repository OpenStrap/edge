// Cycle — menstrual cycle tracking. Log period starts; see current phase, next
// predicted period + fertile window (log-anchored calendar method), and how your
// skin-temp / resting-HR / HRV shift across the cycle. Honest: an estimate, not
// medical or contraceptive guidance. Uses getCycle / postCycleLog / deleteCycleLog.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';
import '../kit/charts.dart';

class CycleScreen extends StatefulWidget {
  const CycleScreen({super.key});
  @override
  State<CycleScreen> createState() => _CycleScreenState();
}

class _CycleScreenState extends State<CycleScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _noApi = false;
  String? _error;
  final Set<String> _symptoms = {}; // today's logged symptoms

  // Common menstrual symptoms the user can tap to log for today.
  static const _symptomOptions = <String>[
    'cramps', 'headache', 'bloating', 'fatigue', 'mood swings',
    'tender breasts', 'acne', 'back pain', 'nausea', 'cravings',
    'insomnia', 'spotting',
  ];

  LocalRepository? get _api => context.read<AppState>().repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null) {
      setState(() { _loading = false; _noApi = true; });
      return;
    }
    setState(() { _loading = true; _error = null; _noApi = false; });
    try {
      final d = await api.getCycle();
      final sym = await api.getCycleSymptoms();
      if (!mounted) return;
      setState(() {
        _data = d;
        _symptoms
          ..clear()
          ..addAll(sym[_fmt(DateTime.now())] ?? const []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e is RepositoryException ? e.body : e.toString(); });
    }
  }

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _logToday() => _logDate(DateTime.now().toUtc());

  Future<void> _logDate(DateTime day) async {
    final api = _api;
    if (api == null) { return; }
    try {
      await api.postCycleLog(_fmt(day), kind: 'start');
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Couldn't log: ${e is RepositoryException ? e.body : e}")));
      }
    }
  }

  Future<void> _pickAndLog() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
    );
    if (picked != null) await _logDate(picked.toUtc());
  }

  Future<void> _delete(String date) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.deleteCycleLog(date);
      await _load();
    } catch (_) {}
  }

  Future<void> _toggleSymptom(String s) async {
    setState(() {
      if (!_symptoms.add(s)) _symptoms.remove(s);
    });
    final api = _api;
    if (api == null) return;
    try {
      await api.postCycleSymptoms(_fmt(DateTime.now()), _symptoms.toList());
    } catch (_) {/* best-effort */}
  }

  // ── phase presentation ──────────────────────────────────────────────────────
  static const _phaseLabel = {
    'menstrual': 'Menstruation',
    'follicular': 'Follicular phase',
    'ovulation': 'Ovulation window',
    'luteal': 'Luteal phase',
    'unknown': 'Cycle',
  };
  Color _phaseColor(String p) {
    switch (p) {
      case 'menstrual': return AppColors.coral;
      case 'follicular': return AppColors.good;
      case 'ovulation': return AppColors.coralDeep;
      case 'luteal': return AppColors.warn;
      default: return AppColors.inkSoft;
    }
  }

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
                _stateCard('Cycle tracking unavailable',
                    'Pair your strap to log periods and see predictions. Everything stays on this phone.')
              else if (_loading)
                const Padding(padding: EdgeInsets.all(Sp.x8), child: Center(child: CircularProgressIndicator()))
              else if (_error != null)
                _stateCard("Couldn't load cycle", _error!)
              else
                ..._content(),
              const SizedBox(height: 110),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() => Row(children: [
        RoundIconButton(Ic.arrowLeft, onTap: () => Navigator.of(context).pop()),
        const SizedBox(width: Sp.x3),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Cycle', style: AppText.h1),
          const SizedBox(height: 4),
          Text('Log periods — see phase, fertile window & body shifts', style: AppText.caption),
        ])),
      ]);

  List<Widget> _content() {
    final d = _data!;
    if (d['enabled'] == false) {
      return [_stateCard('Cycle tracking is off',
          (d['note'] as String?) ?? 'Enable it in your profile to start tracking.')];
    }
    final phase = (d['phase'] as String?) ?? 'unknown';
    final cycleDay = d['cycle_day'] as num?;
    final daysUntil = d['days_until_next'] as num?;
    final next = d['predicted_next'] as String?;
    final fertileStart = d['fertile_start'] as String?;
    final fertileEnd = d['fertile_end'] as String?;
    final ovulation = d['ovulation_est'] as String?;
    final meanLen = d['mean_length'] as num?;
    final note = (d['note'] as String?) ?? '';
    final conf = (d['confidence'] as num?) ?? 0;
    final logs = (d['logs'] as List?)?.whereType<Map>().toList() ?? const [];
    final overlay = (d['overlay'] as List?)?.whereType<Map>().toList() ?? const [];
    final accent = _phaseColor(phase);

    final hasPrediction = next != null && conf > 0;

    return [
      // HERO — current phase + cycle day.
      GlowCard(
        padding: const EdgeInsets.all(Sp.x6),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              AppIcon(Ic.calendar, size: 16, color: accent),
              const SizedBox(width: Sp.x2),
              Text('YOUR CYCLE', style: AppText.overline),
            ]),
            const SizedBox(height: Sp.x3),
            Text(_phaseLabel[phase] ?? 'Cycle', style: AppText.h2.copyWith(color: accent)),
            const SizedBox(height: Sp.x2),
            Text(cycleDay != null ? 'Day ${cycleDay.round()} of your cycle' : 'Log a period to begin',
                style: AppText.bodySoft),
          ])),
          if (cycleDay != null && meanLen != null)
            RingStat(
              t: (cycleDay / meanLen).clamp(0.0, 1.0),
              color: accent, size: 92, stroke: 11,
              center: Text('${cycleDay.round()}', style: AppText.metricSm),
            ),
        ]),
      ),

      // PREDICTION.
      if (hasPrediction) ...[
        const SizedBox(height: Sp.x6),
        SectionHeader('Prediction'),
        ProCard(child: Column(children: [
          _row(Ic.droplet, AppColors.coral, 'Next period',
              daysUntil != null && daysUntil >= 0 ? 'in ${daysUntil.round()} days' : (next),
              sub: next),
          if (fertileStart != null && fertileEnd != null)
            _row(Ic.heart, AppColors.good, 'Fertile window', '${_md(fertileStart)} – ${_md(fertileEnd)}'),
          if (ovulation != null)
            _row(Ic.up, AppColors.coralDeep, 'Estimated ovulation', _md(ovulation)),
        ])),
        const SizedBox(height: Sp.x2),
        Text(note, style: AppText.captionMuted),
      ],

      // BIOMETRIC OVERLAY — how the body is shifting this cycle (descriptive).
      if (overlay.isNotEmpty) ...[
        const SizedBox(height: Sp.x6),
        SectionHeader('Body this cycle'),
        ProCard(child: Column(children: [
          _overlayRow(Ic.thermometer, AppColors.coralDeep, 'Skin temp vs baseline', overlay, 'skin_temp_idx', 'Δ', signed: true),
          _overlayRow(Ic.heart, AppColors.coral, 'Resting HR', overlay, 'resting_hr', 'bpm'),
          _overlayRow(Ic.pulse, AppColors.good, 'HRV (RMSSD)', overlay, 'hrv_rmssd', 'ms'),
        ])),
        const SizedBox(height: Sp.x2),
        Text('Skin temp and resting HR often rise, and HRV dips, in the luteal phase. '
            'Shown for context — the prediction is based on your logged periods, not these.',
            style: AppText.captionMuted),
      ],

      // SYMPTOMS — tap to log how you feel today (feeds the cycle picture).
      const SizedBox(height: Sp.x6),
      SectionHeader('Symptoms today'),
      ProCard(
        child: Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            for (final s in _symptomOptions)
              FilterChip(
                label: Text(s),
                selected: _symptoms.contains(s),
                onSelected: (_) => _toggleSymptom(s),
                showCheckmark: false,
                selectedColor: AppColors.coral.withValues(alpha: 0.18),
                labelStyle: AppText.caption.copyWith(
                    color: _symptoms.contains(s)
                        ? AppColors.coralDeep
                        : AppColors.inkSoft),
                backgroundColor: AppColors.surface,
                shape: StadiumBorder(
                    side: BorderSide(
                        color: _symptoms.contains(s)
                            ? AppColors.coral
                            : AppColors.divider)),
              ),
          ],
        ),
      ),
      const SizedBox(height: Sp.x2),
      Text('Logged symptoms ride along with your phase + recovery — over time '
          'they sharpen the picture.', style: AppText.captionMuted),

      // LOG actions.
      const SizedBox(height: Sp.x6),
      SectionHeader('Log a period'),
      Row(children: [
        Expanded(child: FilledButton.icon(
          onPressed: _logToday,
          icon: const AppIcon(Ic.droplet, size: 18, color: Colors.white),
          label: const Text('Period started today'),
        )),
        const SizedBox(width: Sp.x3),
        OutlinedButton(onPressed: _pickAndLog, child: const Text('Pick date')),
      ]),

      // RECENT LOGS.
      if (logs.isNotEmpty) ...[
        const SizedBox(height: Sp.x6),
        SectionHeader('Logged periods'),
        ProCard(child: Column(children: [
          for (final l in logs.take(12))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                AppIcon(Ic.droplet, size: 15, color: AppColors.coral),
                const SizedBox(width: Sp.x3),
                Expanded(child: Text('${l['date']}  ·  ${l['kind']}', style: AppText.body)),
                IconButton(
                  icon: AppIcon(Ic.cancel, size: 16, color: AppColors.inkMuted),
                  onPressed: () => _delete('${l['date']}'),
                  visualDensity: VisualDensity.compact,
                ),
              ]),
            ),
        ])),
      ],
    ];
  }

  // MM-DD short date.
  String _md(String iso) => iso.length >= 10 ? iso.substring(5) : iso;

  Widget _row(IconData icon, Color accent, String label, String? value, {String? sub}) =>
      Padding(padding: const EdgeInsets.symmetric(vertical: Sp.x2), child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(R.chip)),
          child: AppIcon(icon, size: 16, color: accent),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppText.label),
          if (sub != null) Text(sub, style: AppText.captionMuted),
        ])),
        Text(value ?? '—', style: AppText.label),
      ]));

  // Latest non-null value of [key] across the cycle, with a signed/plain format.
  Widget _overlayRow(IconData icon, Color accent, String label, List<Map> series, String key, String unit, {bool signed = false}) {
    num? latest;
    for (final r in series.reversed) {
      final v = r[key];
      if (v is num) { latest = v; break; }
    }
    String val = '—';
    if (latest != null) {
      final s = signed ? latest.toStringAsFixed(1) : latest.round().toString();
      val = signed && latest > 0 ? '+$s $unit' : '$s $unit';
    }
    return Padding(padding: const EdgeInsets.symmetric(vertical: Sp.x2), child: Row(children: [
      AppIcon(icon, size: 15, color: accent),
      const SizedBox(width: Sp.x3),
      Expanded(child: Text(label, style: AppText.body)),
      Text(val, style: AppText.label),
    ]));
  }

  Widget _stateCard(String title, String message) => ProCard(
        child: Padding(padding: const EdgeInsets.all(Sp.x4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: AppText.label),
          const SizedBox(height: Sp.x2),
          Text(message, style: AppText.captionMuted),
        ])),
      );
}
