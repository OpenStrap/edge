// BP research capture (developer mode only): type in a cuff reading, and
// the band's synced data from 2 minutes either side is stored next to it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/db.dart';
import '../../health/bp_research_capture.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'devices.dart' show formatDayTime;

class BpResearchScreen extends StatefulWidget {
  const BpResearchScreen({super.key});

  @override
  State<BpResearchScreen> createState() => _BpResearchScreenState();
}

class _BpResearchScreenState extends State<BpResearchScreen> {
  final _sys = TextEditingController();
  final _dia = TextEditingController();
  final _device = TextEditingController();
  final _posture = TextEditingController();
  final _conditions = TextEditingController();
  List<Map<String, Object?>> _rows = const [];
  int? _edgeMs;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _sys.dispose();
    _dia.dispose();
    _device.dispose();
    _posture.dispose();
    _conditions.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final edge = await LocalDb.fillBpResearchWindows();
    final rows = await LocalDb.bpResearchCaptures();
    if (mounted) {
      setState(() {
        _rows = rows;
        _edgeMs = edge;
      });
    }
  }

  Future<void> _capture() async {
    if (_busy) return;
    final sys = double.tryParse(_sys.text);
    final dia = double.tryParse(_dia.text);
    final l = AppLocalizations.of(context);
    if (sys == null ||
        dia == null ||
        sys < kResearchSystolicBounds.$1 ||
        sys > kResearchSystolicBounds.$2 ||
        dia < kResearchDiastolicBounds.$1 ||
        dia > kResearchDiastolicBounds.$2 ||
        dia >= sys) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l?.bpResearchBadValue ??
              'That pair is outside the supported range (systolic 50–300, '
              'diastolic 20–200 mmHg, diastolic below systolic). It was not '
              'saved.'),
        ));
      }
      return;
    }
    setState(() => _busy = true);
    var stored = false;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      // The window is filled in by _refresh once the band has synced it.
      await LocalDb.putBpResearchCapture(BpResearchCapture(
        measuredAtMs: now,
        systolicMmHg: sys,
        diastolicMmHg: dia,
        capturedAtMs: now,
        device: _device.text.trim().isEmpty ? null : _device.text.trim(),
        posture: _posture.text.trim().isEmpty ? null : _posture.text.trim(),
        conditions:
            _conditions.text.trim().isEmpty ? null : _conditions.text.trim(),
      ));
      stored = true;
      _sys.clear();
      _dia.clear();
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(stored
              ? (l?.bpResearchRefreshFailed('$e') ??
                  'Saved, but the list failed to refresh. ($e)')
              : (l?.bpResearchCaptureFailed('$e') ??
                  'Capture failed, nothing was saved. ($e)')),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    return Scaffold(
      appBar: AppBar(
        title: Text(l?.bpResearchTitle ?? 'BP research capture'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(S.x4),
        children: [
          Text(
            l?.bpResearchIntro ??
                'Experimental. Take a cuff reading, type it in and press '
                'capture. Band data from 2 minutes either side is added once '
                'the band has synced it.',
            style: F.cap.copyWith(color: p.ink2, height: 1.5),
          ),
          const SizedBox(height: S.x4),
          TextField(
            controller: _sys,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
            decoration: InputDecoration(
              labelText: l?.bpResearchSystolic ?? 'Systolic (mmHg)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _dia,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
            decoration: InputDecoration(
              labelText: l?.bpResearchDiastolic ?? 'Diastolic (mmHg)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _device,
            decoration: InputDecoration(
              labelText: l?.bpResearchDevice ?? 'Cuff device (optional)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _posture,
            decoration: InputDecoration(
              labelText: l?.bpResearchPosture ?? 'Posture (optional)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _conditions,
            decoration: InputDecoration(
              labelText: l?.bpResearchConditions ?? 'Conditions (optional)',
            ),
          ),
          const SizedBox(height: S.x4),
          FilledButton.icon(
            onPressed: _busy ? null : _capture,
            icon: const Icon(LucideIcons.plus),
            label: Text(l?.bpResearchCapture ?? 'Capture now'),
          ),
          const SizedBox(height: S.x6),
          if (_rows.isNotEmpty) ...[
            Text(l?.bpResearchHistory ?? 'Captures',
                style: F.head),
            const SizedBox(height: S.x2),
            for (final r in _rows)
              ListTile(
                dense: true,
                title: Text(
                  '${(r['systolic_mmhg'] as num).round()}/'
                  '${(r['diastolic_mmhg'] as num).round()} mmHg · '
                  '${formatDayTime(DateTime.fromMillisecondsSinceEpoch(
                      r['measured_at_ms'] as int), l)}',
                ),
                subtitle: Text(_windowSummary(r, l)),
                trailing: IconButton(
                  icon: const Icon(LucideIcons.trash2, size: 18),
                  onPressed: () async {
                    await LocalDb.deleteBpResearchCapture(r['id'] as int);
                    await _refresh();
                  },
                ),
              ),
            const SizedBox(height: S.x4),
            Text(
              l?.bpResearchExportHint ??
                  'Included in Your data › Export as spreadsheets. Backups '
                  'and an opt-in health share include them too.',
              style: F.cap.copyWith(color: p.ink2, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  String _windowSummary(Map<String, Object?> r, AppLocalizations? l) {
    final onehz = r['onehz_rows'];
    final beats = r['rr_beats'];
    final hr = r['hr_mean'];
    final rmssd = r['rmssd_ms'];

    if (onehz == null && beats == null) {
      final edge = _edgeMs;
      final end = (r['measured_at_ms'] as int) + kBpResearchWindowPostMs;
      return edge == null || end > edge
          ? (l?.bpResearchWindowPending ?? 'Waiting for the band to sync')
          : (l?.bpResearchWindowEmpty ?? 'No band data in the window');
    }
    final parts = <String>[];
    if (hr is num) {
      final v = hr.toStringAsFixed(0);
      parts.add(l?.bpResearchWindowHr(v) ?? 'HR $v bpm');
    }
    if (rmssd is num) {
      final v = rmssd.toStringAsFixed(0);
      parts.add(l?.bpResearchWindowRmssd(v) ?? 'RMSSD $v ms');
    }
    final rows = '${onehz ?? 0}', n = '${beats ?? 0}';
    parts.add(
        l?.bpResearchWindowCounts(rows, n) ?? '$rows 1 Hz rows, $n beats');
    return parts.join(' · ');
  }
}
