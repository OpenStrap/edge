// BP research capture (developer mode): type in a cuff reading and the band's
// decoded window before it is saved next to it. See bp_research_capture.dart.
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

  @visibleForTesting
  static String windowSummary(Map<String, Object?> r, [AppLocalizations? l]) =>
      _BpResearchScreenState._windowSummary(r, l);

  @override
  State<BpResearchScreen> createState() => _BpResearchScreenState();
}

class _BpResearchScreenState extends State<BpResearchScreen> {
  final _sys = TextEditingController();
  final _dia = TextEditingController();
  final _device = TextEditingController();
  final _posture = TextEditingController();
  final _conditions = TextEditingController();
  final _sessionId = TextEditingController();
  // Optional back-dating: 'HH:MM' today or 'YYYY-MM-DD HH:MM'. Empty means
  // the measurement is being taken right now.
  final _measuredAt = TextEditingController();
  List<Map<String, Object?>> _rows = const [];
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
    _sessionId.dispose();
    _measuredAt.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final rows = await LocalDb.bpResearchCaptures();
    if (mounted) setState(() => _rows = rows);
  }

  Future<void> _rowAction(Future<void> Function() action) async {
    try {
      await action();
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// The measurement time field, minute precision. Empty is [now]; anything
  /// unparseable (including a rolled-over date like 2024-02-31) is null.
  DateTime? _parseMeasuredAt(DateTime now) {
    final text = _measuredAt.text.trim();
    if (text.isEmpty) return now;
    final twoPart = RegExp(r'^(\d{4}-\d{2}-\d{2})[ T](\d{1,2}):(\d{2})$');
    final m = twoPart.firstMatch(text);
    if (m != null) {
      final y = int.tryParse(m.group(1)!.substring(0, 4));
      final mo = int.tryParse(m.group(1)!.substring(5, 7));
      final d = int.tryParse(m.group(1)!.substring(8, 10));
      final h = int.tryParse(m.group(2)!);
      final min = int.tryParse(m.group(3)!);
      if (y == null || mo == null || d == null || h == null || min == null) {
        return null;
      }
      if (mo < 1 || mo > 12 || d < 1 || h > 23 || min > 59) return null;
      final parsed = DateTime(y, mo, d, h, min);
      // Overflow check: a rolled-over date no longer matches its parts.
      if (parsed.year != y || parsed.month != mo || parsed.day != d) {
        return null;
      }
      return parsed;
    }
    final hm = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text);
    if (hm != null) {
      final h = int.tryParse(hm.group(1)!);
      final min = int.tryParse(hm.group(2)!);
      if (h == null || min == null || h > 23 || min > 59) return null;
      return DateTime(now.year, now.month, now.day, h, min);
    }
    return null;
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l?.bpResearchBadValue ??
                  'That pair is outside the range this app supports \u2014 '
                      'check the numbers and try again. Nothing was stored.',
            ),
          ),
        );
      }
      return;
    }
    final enteredAt = DateTime.now();
    final measuredAt = _parseMeasuredAt(enteredAt);
    if (measuredAt == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l?.bpResearchBadTime ??
                  'Could not read the measurement time \u2014 use HH:MM or '
                      'YYYY-MM-DD HH:MM, or leave it empty for "now". Nothing was '
                      'stored.',
            ),
          ),
        );
      }
      return;
    }
    final measuredAtMs = measuredAt.millisecondsSinceEpoch;
    final enteredAtMs = enteredAt.millisecondsSinceEpoch;
    if (measuredAtMs > enteredAtMs + 60 * 1000) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l?.bpResearchFutureTime ??
                  'The measurement time is in the future. Nothing was stored.',
            ),
          ),
        );
      }
      return;
    }
    setState(() => _busy = true);
    var stored = false;
    try {
      final rows = await LocalDb.bpResearchRows(
        LocalDb.kPrimaryDeviceId,
        measuredAtMs - kResearchRestPreMs,
        measuredAtMs + kResearchWindowPostMs,
      );
      final window = researchWindowFrom(
        measuredAtMs: measuredAtMs,
        onehzRows: rows.onehz,
        rrRows: rows.rr,
        nowMs: enteredAtMs,
        dataThroughMs: rows.dataThroughMs,
      );
      await LocalDb.putBpResearchCapture(
        BpResearchCapture(
          measuredAtMs: measuredAtMs,
          measurementStartedAtMs: null,
          measurementFinishedAtMs: null,
          timePrecision: 'minute',
          systolicMmHg: sys,
          diastolicMmHg: dia,
          capturedAtMs: enteredAtMs,
          device: _device.text.trim().isEmpty ? null : _device.text.trim(),
          posture: _posture.text.trim().isEmpty ? null : _posture.text.trim(),
          conditions: _conditions.text.trim().isEmpty
              ? null
              : _conditions.text.trim(),
          bandDeviceId: LocalDb.kPrimaryDeviceId,
          measurementSessionId: _sessionId.text.trim().isEmpty
              ? null
              : _sessionId.text.trim(),
          window: window,
        ),
        snapshotOnehzRows: rows.onehz,
        snapshotRrRows: rows.rr,
      );
      stored = true;
      _sys.clear();
      _dia.clear();
      _measuredAt.clear();
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              stored
                  ? (l?.bpResearchListFailed('$e') ??
                        'Capture saved, but the list did not refresh. ($e)')
                  : (l?.bpResearchSaveFailed('$e') ??
                        'Capture failed, nothing was stored. ($e)'),
            ),
          ),
        );
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
      appBar: AppBar(title: Text(l?.bpResearchTitle ?? 'BP research capture')),
      body: ListView(
        padding: const EdgeInsets.all(S.x4),
        children: [
          Text(
            l?.bpResearchIntro ??
                'Experimental. Take a cuff reading, type it in and press '
                    'capture. The 5 minutes of band data before the reading are '
                    'saved next to it for CSV export.',
            style: F.cap.copyWith(color: p.ink2, height: 1.5),
          ),
          const SizedBox(height: S.x4),
          TextField(
            controller: _sys,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
            ],
            decoration: InputDecoration(
              labelText: l?.bpResearchSystolic ?? 'Systolic (mmHg)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _dia,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
            ],
            decoration: InputDecoration(
              labelText: l?.bpResearchDiastolic ?? 'Diastolic (mmHg)',
            ),
          ),
          const SizedBox(height: S.x2),
          TextField(
            controller: _measuredAt,
            keyboardType: TextInputType.datetime,
            decoration: InputDecoration(
              labelText:
                  l?.bpResearchMeasuredAt ??
                  'Measurement time (HH:MM or YYYY-MM-DD HH:MM; empty = now)',
              helperText:
                  l?.bpResearchMeasuredAtHint ??
                  'Back-date to the actual cuff reading \u2014 the 5-minute '
                      'band window covers the rest time BEFORE that reading, not '
                      'the typing-in. Minute precision; empty = taken just now.',
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
            controller: _sessionId,
            decoration: InputDecoration(
              labelText: l?.bpResearchSessionId ?? 'Session id (optional)',
              helperText:
                  l?.bpResearchSessionIdHint ??
                  'Groups readings taken in one sitting.',
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
            Text(l?.bpResearchHistory ?? 'Captures', style: F.head),
            const SizedBox(height: S.x2),
            for (final r in _rows)
              ListTile(
                dense: true,
                title: Text(
                  '${r['systolic_mmhg']}/${r['diastolic_mmhg']} mmHg \u2014 '
                  '${formatDayTime(DateTime.fromMillisecondsSinceEpoch(r['measured_at_ms'] as int), l)}',
                ),
                subtitle: Text(_windowSummary(r, l)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(LucideIcons.refreshCw, size: 18),
                      tooltip:
                          l?.bpResearchRefreshTooltip ?? 'Refresh band window',
                      onPressed: () => _rowAction(
                        () => LocalDb.reprocessBpResearchCapture(
                          r['id'] as int,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(LucideIcons.trash2, size: 18),
                      tooltip: l?.bpResearchDeleteTooltip ?? 'Delete capture',
                      onPressed: () => _rowAction(
                        () => LocalDb.deleteBpResearchCapture(r['id'] as int),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: S.x4),
            Text(
              l?.bpResearchExportHint ??
                  'Export the captures from Your data \u203a Export CSV, set '
                      '\u201cBP research captures\u201d.',
              style: F.cap.copyWith(color: p.ink2, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  /// One line per capture. Null stats are left out; a pending window says
  /// it is still syncing rather than "no band data".
  static String _windowSummary(Map<String, Object?> r, AppLocalizations? l) {
    final onehz = r['onehz_rows'];
    final beats = r['rr_beats'];
    final hr = r['hr_mean'];
    final rmssd = r['rmssd_ms'];
    final status = r['quality_status'];
    if (status == 'pending') {
      final parts = <String>[
        l?.bpResearchPendingSync ??
            'Band data is still syncing — refresh this window after '
                'sync.',
      ];
      if (hr is num) parts.add('HR ${hr.toStringAsFixed(0)} bpm');
      if (rmssd is num) parts.add('RMSSD ${rmssd.toStringAsFixed(0)} ms');
      if (onehz is num || beats is num) {
        parts.add('${onehz ?? 0} 1 Hz rows, ${beats ?? 0} beats so far');
      }
      return parts.join(' · ');
    }
    if (onehz == null && beats == null) {
      return l?.bpResearchNoData ??
          'No band data in the window — stored as-is.';
    }
    final parts = <String>[];
    if (hr is num) parts.add('HR ${hr.toStringAsFixed(0)} bpm');
    if (rmssd is num) parts.add('RMSSD ${rmssd.toStringAsFixed(0)} ms');
    parts.add('${onehz ?? 0} 1 Hz rows, ${beats ?? 0} beats');
    if (status is String && status.isNotEmpty && status != 'ok') {
      parts.add(status);
    }
    return parts.join(' · ');
  }
}
