// Cycle — menstrual cycle tracking. Log period starts; see current phase, next
// predicted period + fertile window (log-anchored calendar method), and how your
// skin-temp / resting-HR / HRV shift across the cycle. Honest: an estimate, not
// medical or contraceptive guidance. Uses getCycle / postCycleLog / deleteCycleLog.
//
// On the design language: a rose-plum domain accent, the cycle day as a clean
// open-arc ring hero, predictions as quiet rows, the body's shifts as a bento,
// symptoms as calm toggle chips, and the honesty copy behind the (i).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local_repository.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

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

  LocalRepository? get _api => context.read<AppState>().repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

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
      setState(() {
        _loading = false;
        _error = e is RepositoryException ? e.body : e.toString();
      });
    }
  }

  static String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // LOCAL dates: cycle logs are keyed by the local day label like the rest of
  // the day model. (The old .toUtc() logged the UTC date — and shifted a picked
  // local-midnight date to the PREVIOUS day for any UTC+ timezone.)
  Future<void> _logToday() => _logDate(DateTime.now());

  Future<void> _logDate(DateTime day) async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      await api.postCycleLog(_fmt(day), kind: 'start');
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                "Couldn't log: ${e is RepositoryException ? e.body : e}")));
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
    if (picked != null) await _logDate(picked);
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

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Cycle',
      subtitle: 'Phase, predictions & body shifts',
      actions: [
        InfoDot(
          title: 'Cycle tracking',
          body:
              'Predictions use the calendar method anchored on your logged '
              'period starts — an estimate that sharpens as you log more '
              'cycles. Everything stays on this phone.',
          bullets: const [
            'Not medical or contraceptive guidance.',
            'Body shifts (temp, resting HR, HRV) are context, not the prediction.',
          ],
          methodNote: 'Log-anchored calendar method · on-device',
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _load,
        color: DomainAccent.cycle,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding:
              const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x8),
          children: [
            if (_noApi)
              const StateCard(
                icon: Ic.calendar,
                title: 'Cycle tracking unavailable',
                message:
                    'Pair your strap to log periods and see predictions. '
                    'Everything stays on this phone.',
              )
            else if (_loading) ...[
              Skeleton.hero(),
              const SizedBox(height: Sp.x3),
              Skeleton.tileRow(rows: 2),
            ] else if (_error != null)
              StateCard(
                icon: Ic.cloud,
                title: "Couldn't load cycle",
                message: _error!,
                actionLabel: 'Try again',
                onAction: _load,
              )
            else
              CycleContent(
                data: _data!,
                symptoms: _symptoms,
                onToggleSymptom: _toggleSymptom,
                onLogToday: _logToday,
                onPickDate: _pickAndLog,
                onDelete: _delete,
              ),
          ],
        ),
      ),
    );
  }
}

/// The pure cycle board — testable with a sample /cycle payload.
class CycleContent extends StatelessWidget {
  final Map<String, dynamic> data;
  final Set<String> symptoms;
  final ValueChanged<String>? onToggleSymptom;
  final VoidCallback? onLogToday;
  final VoidCallback? onPickDate;
  final ValueChanged<String>? onDelete;

  const CycleContent({
    super.key,
    required this.data,
    this.symptoms = const {},
    this.onToggleSymptom,
    this.onLogToday,
    this.onPickDate,
    this.onDelete,
  });

  // Common menstrual symptoms the user can tap to log for today.
  static const symptomOptions = <String>[
    'cramps', 'headache', 'bloating', 'fatigue', 'mood swings',
    'tender breasts', 'acne', 'back pain', 'nausea', 'cravings',
    'insomnia', 'spotting',
  ];

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
      case 'menstrual':
        return DomainAccent.cycle;
      case 'follicular':
        return DomainAccent.recovery;
      case 'ovulation':
        return DomainAccent.cyclePlum;
      case 'luteal':
        return DomainAccent.strain;
      default:
        return AppColors.inkSoft;
    }
  }

  // MM-DD short date.
  String _md(String iso) => iso.length >= 10 ? iso.substring(5) : iso;

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d['enabled'] == false) {
      return StateCard(
        icon: Ic.calendar,
        title: 'Cycle tracking is off',
        message: (d['note'] as String?) ??
            'Enable it in your profile to start tracking.',
      );
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
    final overlay =
        (d['overlay'] as List?)?.whereType<Map>().toList() ?? const [];
    final accent = _phaseColor(phase);
    final hasPrediction = next != null && conf > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // HERO — the cycle-day ring floats on the page, no card chrome.
        _hero(phase, accent, cycleDay, meanLen).dsEnter(index: 0),

        // PREDICTION.
        if (hasPrediction) ...[
          const SizedBox(height: Sp.x5),
          const SectionHeader('Prediction'),
          SurfaceCard(
            padding:
                const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
            child: Column(
              children: [
                DetailRow(
                  icon: Ic.droplet,
                  label: 'Next period',
                  value: daysUntil != null && daysUntil >= 0
                      ? 'in ${daysUntil.round()} days'
                      : _md(next),
                ),
                if (fertileStart != null && fertileEnd != null)
                  DetailRow(
                    icon: Ic.heart,
                    label: 'Fertile window',
                    value: '${_md(fertileStart)} – ${_md(fertileEnd)}',
                  ),
                if (ovulation != null)
                  DetailRow(
                    icon: Ic.up,
                    label: 'Estimated ovulation',
                    value: _md(ovulation),
                  ),
              ],
            ),
          ).dsEnter(index: 1),
          if (note.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            Text(note, style: AppText.captionMuted),
          ],
        ],

        // BIOMETRIC OVERLAY — how the body is shifting this cycle (descriptive).
        if (overlay.isNotEmpty) ...[
          const SizedBox(height: Sp.x5),
          Row(
            children: [
              const Expanded(child: SectionHeader('Body this cycle')),
              InfoDot(
                title: 'Body this cycle',
                body:
                    'Skin temp and resting HR often rise, and HRV dips, in the '
                    'luteal phase. Shown for context — the prediction is based '
                    'on your logged periods, not these.',
              ),
            ],
          ),
          _overlayBento(overlay),
        ],

        // SYMPTOMS — tap to log how you feel today (feeds the cycle picture).
        const SizedBox(height: Sp.x5),
        const SectionHeader('Symptoms today'),
        SurfaceCard(
          padding: const EdgeInsets.all(Sp.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: Sp.x2,
                runSpacing: Sp.x2,
                children: [
                  for (final s in symptomOptions)
                    ToggleChip(
                      s,
                      selected: symptoms.contains(s),
                      accent: DomainAccent.cycle,
                      onTap: onToggleSymptom == null
                          ? null
                          : () => onToggleSymptom!(s),
                    ),
                ],
              ),
              const SizedBox(height: Sp.x3),
              Text(
                'Symptoms ride along with your phase + recovery — over time '
                'they sharpen the picture.',
                style: AppText.captionMuted,
              ),
            ],
          ),
        ).dsEnter(index: 2),

        // LOG actions.
        const SizedBox(height: Sp.x5),
        const SectionHeader('Log a period'),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: onLogToday,
                style: FilledButton.styleFrom(
                  backgroundColor: DomainAccent.cycle,
                ),
                icon: const AppIcon(Ic.droplet, size: 18, color: Colors.white),
                label: const Text('Period started today'),
              ),
            ),
            const SizedBox(width: Sp.x3),
            OutlinedButton(
                onPressed: onPickDate, child: const Text('Pick date')),
          ],
        ),

        // RECENT LOGS.
        if (logs.isNotEmpty) ...[
          const SizedBox(height: Sp.x5),
          const SectionHeader('Logged periods'),
          SurfaceCard(
            padding:
                const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
            child: Column(
              children: [
                for (final l in logs.take(12))
                  DetailRow(
                    icon: Ic.droplet,
                    label: '${l['date']}',
                    value: '${l['kind']}',
                    trailing: onDelete == null
                        ? null
                        : IconButton(
                            icon: AppIcon(Ic.cancel,
                                size: 16, color: AppColors.inkMuted),
                            onPressed: () => onDelete!('${l['date']}'),
                            visualDensity: VisualDensity.compact,
                          ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ── hero — cycle-day arc + phase chip ─────────────────────────────────────────
  Widget _hero(String phase, Color accent, num? cycleDay, num? meanLen) {
    final hasDay = cycleDay != null && meanLen != null && meanLen > 0;
    return Column(
      children: [
        const SizedBox(height: Sp.x3),
        ArcGauge(
          value: hasDay ? (cycleDay / meanLen).clamp(0.0, 1.0) : double.nan,
          color: accent,
          size: 180,
          stroke: 14,
          sweepFraction: 0.75,
          endDot: hasDay,
          center: hasDay
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${cycleDay.round()}',
                        style: AppText.metric.copyWith(fontSize: 40)),
                    Text('DAY',
                        style: AppText.overline
                            .copyWith(color: AppColors.inkMuted)),
                  ],
                )
              : AppIcon(Ic.calendar, size: 42, color: AppColors.inkMuted),
        ),
        const SizedBox(height: Sp.x3),
        StatusChip(
          _phaseLabel[phase] ?? 'Cycle',
          icon: Ic.calendar,
          tone: ChipTone.neutral,
        ),
        const SizedBox(height: Sp.x2),
        Text(
          hasDay
              ? 'Day ${cycleDay.round()} of ~${meanLen.round()}'
              : 'Log a period to begin',
          style: AppText.bodySoft,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Sp.x2),
      ],
    );
  }

  // ── the body-shift bento ──────────────────────────────────────────────────────
  // Latest non-null value of [key] across the cycle.
  num? _latest(List<Map> series, String key) {
    for (final r in series.reversed) {
      final v = r[key];
      if (v is num) return v;
    }
    return null;
  }

  Widget _overlayBento(List<Map> overlay) {
    final temp = _latest(overlay, 'skin_temp_idx');
    final rhr = _latest(overlay, 'resting_hr');
    final hrv = _latest(overlay, 'hrv_rmssd');
    String? signed(num? v) => v == null
        ? null
        : (v > 0 ? '+${v.toStringAsFixed(1)}' : v.toStringAsFixed(1));
    return BentoColumns(
      left: [
        BentoTile(
          tone: BentoTone.soft,
          accent: DomainAccent.cycle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const TileHeader('Skin temp',
                  icon: Ic.thermometer, osIcon: OsIcon.skinTemperature),
              const SizedBox(height: Sp.x2),
              BigStat(value: signed(temp), unit: 'Δ', caption: 'vs baseline'),
            ],
          ),
        ),
        BentoTile(
          accent: DomainAccent.recovery,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const TileHeader('HRV', icon: Ic.pulse, osIcon: OsIcon.hrv),
              const SizedBox(height: Sp.x2),
              BigStat(
                value: hrv?.round().toString(),
                unit: 'ms',
                caption: 'RMSSD',
              ),
            ],
          ),
        ),
      ],
      right: [
        BentoTile(
          accent: DomainAccent.heart,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const TileHeader('Resting HR',
                  icon: Ic.heart, osIcon: OsIcon.restingHeartRate),
              const SizedBox(height: Sp.x2),
              BigStat(
                value: rhr?.round().toString(),
                unit: 'bpm',
                caption: 'this cycle',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
