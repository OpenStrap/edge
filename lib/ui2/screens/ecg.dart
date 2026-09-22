// WHOOP MG ECG — the Heart Screener entry (history + Take ECG), the capture
// screen and the reading detail.
//
// The entry is gated on the paired band being a REMEMBERED WHOOP MG; inside
// it, saved readings read fine while the band is away and "Take ECG" needs
// the MG connected and READY. Everything shown as a result is the band's own
// category — labelled so — never a phone-side classification.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../coach/coach_config.dart';
import '../../data/db.dart';
import '../../ecg/ecg_controller.dart';
import '../../ecg/ecg_models.dart';
import '../../ecg/ecg_waveform_buffer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart' show themedRoute;
import '../ui2.dart';
import 'coach.dart';
import 'home_screen.dart' show go, pad;

/// Whether the paired band is a remembered WHOOP MG — false outside an
/// AppState (goldens), like every other provider read in this folder.
bool pairedIsMaverickOf(BuildContext c) {
  try {
    return c.watch<AppState>().pairedIsMaverick;
  } catch (_) {
    return false;
  }
}

String ecgCategoryLabel(AppLocalizations? l, EcgCategory c) => switch (c) {
  EcgCategory.sinusRhythm => l?.ecgCategorySinus ?? 'Sinus rhythm',
  EcgCategory.lowHeartRate => l?.ecgCategoryLowHr ?? 'Low heart rate',
  EcgCategory.possibleAfib => l?.ecgCategoryPossibleAfib ?? 'Possible AFib',
  EcgCategory.afibHighHeartRate =>
    l?.ecgCategoryAfibHighHr ?? 'AFib with high heart rate',
  EcgCategory.highHeartRate => l?.ecgCategoryHighHr ?? 'High heart rate',
  EcgCategory.highHeartRateNoAfib =>
    l?.ecgCategoryHighHrNoAfib ?? 'High heart rate, no AFib detected',
  EcgCategory.inconclusive => l?.ecgCategoryInconclusive ?? 'Inconclusive',
  EcgCategory.unreadable => l?.ecgCategoryUnreadable ?? 'Unreadable',
};

List<String> ecgReasonLabels(AppLocalizations? l, int mask) => [
  if (mask & 0x01 != 0) l?.ecgReasonLowAmplitude ?? 'Low amplitude',
  if (mask & 0x02 != 0) l?.ecgReasonNoise ?? 'Significant noise',
  if (mask & 0x04 != 0) l?.ecgReasonUnstable ?? 'Unstable signal',
  if (mask & 0x08 != 0) l?.ecgReasonNotEnoughData ?? 'Not enough data',
];

String _wristLabel(AppLocalizations? l, EcgWrist w) => w == EcgWrist.left
    ? (l?.ecgWristLeft ?? 'Left wrist')
    : (l?.ecgWristRight ?? 'Right wrist');

String _fmtWhen(int epochS) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochS * 1000);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

// ═══════════════════ entry card (Health overview) ═══════════════════

/// The Health-overview door. Only built when [pairedIsMaverickOf] is true.
class EcgEntryCard extends StatelessWidget {
  const EcgEntryCard({super.key});

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    return ActionCard(
      l?.ecgHeartScreener ?? 'Heart Screener',
      l?.ecgEntryMeta ?? 'WHOOP MG · band-reported',
      l?.ecgOpen ?? 'Open',
      LucideIcons.activity,
      C.domHealth,
      onTap: () => go(c, const EcgHomeScreen()),
    );
  }
}

// ═══════════════════ home: history + Take ECG ═══════════════════

class EcgHomeScreen extends StatefulWidget {
  const EcgHomeScreen({super.key});

  @override
  State<EcgHomeScreen> createState() => _EcgHomeScreenState();
}

class _EcgHomeScreenState extends State<EcgHomeScreen> {
  List<EcgReading> _readings = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await LocalDb.listEcgReadings();
      final list = [for (final r in rows) ?EcgReading.fromRow(r)];
      if (!mounted) return;
      setState(() {
        _readings = list;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _take(BuildContext c, AppState app) async {
    final serial = app.ecg.transport.serial;
    final remembered = serial == null
        ? null
        : await app.ecg.guard.wrist(serial);
    if (!c.mounted) return;
    final wrist = await showModalBottomSheet<EcgWrist>(
      context: c,
      sheetAnimationStyle: sheetMotion(c),
      builder: (_) => EcgWristSheet(current: remembered),
    );
    if (wrist == null || !c.mounted) return;
    await Navigator.of(c).push(
      themedRoute(
        (_) => EcgCaptureScreen(wrist: wrist),
        name: 'EcgCaptureScreen',
      ),
    );
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    final id = app.ecg.state.readingId;
    if (app.ecg.state.phase == EcgCapturePhase.completed && id != null) {
      unawaited(_openDetail(context, id));
    }
  }

  Future<void> _openDetail(BuildContext c, String id) async {
    final data = await EcgDetailData.load(id);
    if (!c.mounted || data == null) return;
    await Navigator.of(c).push(
      themedRoute((_) => EcgDetailScreen(data: data), name: 'EcgDetailScreen'),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final app = c.watch<AppState>();
    final canTake = app.engine.isConnected && app.engine.isMaverick;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        title: Text(l?.ecgHeartScreener ?? 'Heart Screener'),
      ),
      body: ListView(
        padding: pad,
        children: [
          ActionCard(
            l?.ecgTakeEcg ?? 'Take ECG',
            canTake
                ? (l?.ecgEntryMeta ?? 'WHOOP MG · band-reported')
                : (l?.ecgNeedsMg ?? 'Take ECG needs a connected WHOOP MG.'),
            l?.ecgTakeEcg ?? 'Take ECG',
            LucideIcons.heartPulse,
            C.domHealth,
            onTap: canTake ? () => _take(c, app) : null,
          ),
          const SizedBox(height: S.x4),
          if (_loaded && _readings.isEmpty)
            StatusCard(
              l?.ecgHistoryEmpty ?? 'No readings yet.',
              l?.ecgHistoryEmptyWhy ??
                  'Readings you take are saved here and stay readable while '
                      'the band is away.',
              icon: LucideIcons.activity,
            ),
          if (_readings.isNotEmpty)
            Section(
              l?.ecgTitle ?? 'ECG',
              Surface(
                pad: const EdgeInsets.symmetric(vertical: S.x1),
                child: Column(
                  children: [
                    for (var i = 0; i < _readings.length; i++) ...[
                      if (i > 0) Divider(color: p.line, height: 1),
                      EcgReadingRow(
                        reading: _readings[i],
                        onTap: () => _openDetail(c, _readings[i].id),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One saved reading in the history list.
class EcgReadingRow extends StatelessWidget {
  final EcgReading reading;
  final VoidCallback? onTap;
  const EcgReadingRow({super.key, required this.reading, this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final cat = ecgCategoryLabel(l, reading.category);
    final hr = reading.avgHr;
    return Pressable(
      onTap: onTap,
      semanticLabel:
          '$cat, ${hr == null ? '' : '$hr bpm, '}${_fmtWhen(reading.startTs)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(cat, style: F.body.copyWith(color: p.ink)),
                  const SizedBox(height: S.x1),
                  Text(
                    '${_fmtWhen(reading.startTs)} · ${_wristLabel(l, reading.wrist)}',
                    style: F.cap.copyWith(color: p.ink3),
                  ),
                ],
              ),
            ),
            if (hr != null) Text('$hr', style: F.n24.copyWith(color: p.ink)),
            if (hr != null) const SizedBox(width: S.x1),
            if (hr != null) Text('bpm', style: F.cap.copyWith(color: p.ink3)),
            const SizedBox(width: S.x2),
            Icon(LucideIcons.chevronRight, size: 16, color: p.ink3),
          ],
        ),
      ),
    );
  }
}

/// "Which wrist is the band on?" — pops the choice.
class EcgWristSheet extends StatelessWidget {
  final EcgWrist? current;
  const EcgWristSheet({super.key, this.current});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    Widget option(EcgWrist w, IconData icon) => Pressable(
      semanticLabel: _wristLabel(l, w),
      onTap: () => Navigator.of(c).pop(w),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: S.x5, vertical: S.x4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: p.ink2),
            const SizedBox(width: S.x3),
            Expanded(
              child: Text(
                _wristLabel(l, w),
                style: F.body.copyWith(color: p.ink),
              ),
            ),
            if (current == w)
              Icon(LucideIcons.check, size: 18, color: C.domHealth),
          ],
        ),
      ),
    );
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(S.x5, S.x5, S.x5, S.x2),
            child: Text(
              l?.ecgWristPrompt ?? 'Which wrist is the band on?',
              style: F.head.copyWith(color: p.ink),
            ),
          ),
          option(EcgWrist.left, LucideIcons.arrowLeft),
          option(EcgWrist.right, LucideIcons.arrowRight),
          const SizedBox(height: S.x3),
        ],
      ),
    );
  }
}

// ═══════════════════ capture ═══════════════════

class EcgCaptureScreen extends StatefulWidget {
  final EcgWrist wrist;

  /// The controller to drive; defaults to the app's. Tests hand in their own.
  final EcgController? controller;
  const EcgCaptureScreen({super.key, required this.wrist, this.controller});

  @override
  State<EcgCaptureScreen> createState() => _EcgCaptureScreenState();
}

class _EcgCaptureScreenState extends State<EcgCaptureScreen>
    with SingleTickerProviderStateMixin {
  EcgController? _c;
  Ticker? _ticker;
  Timer? _slowTick;
  double _phase = 0;
  Duration _lastPreview = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = widget.controller ?? context.read<AppState>().ecg;
      c.addListener(_onController);
      setState(() => _c = c);
      _startClock();
      unawaited(c.begin(widget.wrist));
    });
  }

  void _startClock() {
    if (Motion.enabled(context)) {
      _ticker = createTicker(_onTick)..start();
    } else {
      // Reduced motion: no animation, but the live preview still needs a
      // clock to repaint on — one coalesced repaint per second.
      _slowTick = Timer.periodic(Motion.tick, (_) {
        _c?.preview.tick();
      });
    }
  }

  void _onTick(Duration elapsed) {
    final pulseMs = Motion.ecgPulse.inMilliseconds;
    final t = (elapsed.inMilliseconds % pulseMs) / pulseMs;
    if (elapsed - _lastPreview >= Motion.ecgPreviewTick) {
      _lastPreview = elapsed;
      _c?.preview.tick();
    }
    if (mounted) setState(() => _phase = t);
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _slowTick?.cancel();
    _c?.removeListener(_onController);
    // Leaving the screen by any route stops the reading (fire-and-forget:
    // the controller's own cleanup path is idempotent).
    final c = _c;
    if (c != null && c.isCapturing) unawaited(c.cancel());
    super.dispose();
  }

  Future<void> _close(BuildContext c) async {
    final ctl = _c;
    if (ctl != null && ctl.isCapturing) await ctl.cancel();
    if (c.mounted) Navigator.of(c).pop();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final ctl = _c;
    final s = ctl?.state ?? const EcgCaptureState();
    final busy = ctl?.isCapturing ?? false;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !busy) return;
        await _close(c);
      },
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Pressable(
                    semanticLabel: l?.ecgClose ?? 'Close ECG',
                    onTap: () => _close(c),
                    child: Icon(LucideIcons.x, size: 22, color: p.ink2),
                  ),
                ),
                Expanded(
                  child: ctl == null
                      ? const SizedBox.shrink()
                      : EcgCaptureBody(
                          state: s,
                          wrist: widget.wrist,
                          phase: _phase,
                          live: ctl.live,
                          scheduler: ctl.preview,
                          onRetry: ctl.retry,
                          onTakeAnother: () => ctl.begin(widget.wrist),
                          onDone: () => _close(c),
                          onView: () async {
                            final id = s.readingId;
                            if (id == null) return;
                            final data = await EcgDetailData.load(id);
                            if (!c.mounted || data == null) return;
                            await Navigator.of(c).pushReplacement(
                              themedRoute(
                                (_) => EcgDetailScreen(data: data),
                                name: 'EcgDetailScreen',
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The capture screen's content for one [state] — pure, data in, callbacks
/// out, so every phase can be pumped in a test without a band.
class EcgCaptureBody extends StatelessWidget {
  final EcgCaptureState state;
  final EcgWrist wrist;
  final double phase;
  final EcgWaveformBuffer live;
  final EcgPreviewScheduler scheduler;
  final VoidCallback onRetry;
  final VoidCallback onTakeAnother;
  final VoidCallback onDone;
  final VoidCallback onView;

  const EcgCaptureBody({
    super.key,
    required this.state,
    required this.wrist,
    required this.phase,
    required this.live,
    required this.scheduler,
    required this.onRetry,
    required this.onTakeAnother,
    required this.onDone,
    required this.onView,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final s = state;
    Widget title(String t) => Text(t, style: F.t2.copyWith(color: p.ink));
    Widget body(String t) =>
        Text(t, style: F.body.copyWith(color: p.ink2, height: 1.4));
    Widget button(String label, VoidCallback? onTap, {bool primary = true}) =>
        Pressable(
          semanticLabel: label,
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: S.x3),
            decoration: BoxDecoration(
              color: primary ? p.fill(C.domHealth) : p.card2,
              borderRadius: R.rMd,
            ),
            child: Text(
              label,
              style: F.body.copyWith(
                color: primary ? p.inkOnFill : p.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );

    final capturing = switch (s.phase) {
      EcgCapturePhase.recovering ||
      EcgCapturePhase.preparing ||
      EcgCapturePhase.starting ||
      EcgCapturePhase.waiting ||
      EcgCapturePhase.active ||
      EcgCapturePhase.contactLost ||
      EcgCapturePhase.restarting => true,
      _ => false,
    };
    final armed = switch (s.phase) {
      EcgCapturePhase.starting ||
      EcgCapturePhase.waiting ||
      EcgCapturePhase.active ||
      EcgCapturePhase.contactLost ||
      EcgCapturePhase.restarting => true,
      _ => false,
    };
    final measuring =
        s.phase == EcgCapturePhase.active ||
        s.phase == EcgCapturePhase.contactLost ||
        s.phase == EcgCapturePhase.restarting;

    if (capturing) {
      final status = switch (s.phase) {
        EcgCapturePhase.recovering =>
          l?.ecgRecovering ?? 'Stopping a previous reading first…',
        EcgCapturePhase.preparing => l?.ecgPreparing ?? 'Preparing the band…',
        EcgCapturePhase.starting ||
        EcgCapturePhase.waiting => l?.ecgWaiting ?? 'Waiting for contact',
        EcgCapturePhase.active => l?.ecgMeasuring ?? 'Measuring',
        EcgCapturePhase.contactLost =>
          l?.ecgContactLost ?? 'Adjust your fingers and keep still',
        EcgCapturePhase.restarting => l?.ecgRestarting ?? 'Restarting…',
        _ => '',
      };
      return ListView(
        padding: const EdgeInsets.only(bottom: S.x8),
        children: [
          const SizedBox(height: S.x2),
          EcgTouchIllustration(
            wrist: wrist,
            t: phase,
            contact: measuring,
            semanticLabel:
                l?.ecgIllustration ??
                'Illustration: the band on your wrist, and the thumb and index '
                    'finger of your other hand touching its two metal sides.',
          ),
          const SizedBox(height: S.x4),
          body(
            l?.ecgInstruction ??
                'Rest your arm. Touch both metal sides with your opposite thumb '
                    'and index finger. Keep still.',
          ),
          const SizedBox(height: S.x4),
          Text(
            status,
            key: const ValueKey('ecg-status'),
            style: F.head.copyWith(
              color: s.phase == EcgCapturePhase.contactLost ? C.orange : p.ink,
            ),
          ),
          if (measuring) ...[
            const SizedBox(height: S.x2),
            Semantics(
              label: l?.ecgProgress(s.progress) ?? '${s.progress}% complete',
              child: ClipRRect(
                borderRadius: R.rSm,
                child: LinearProgressIndicator(
                  value: s.progress / 100,
                  minHeight: 8,
                  backgroundColor: p.track,
                  color: C.domHealth,
                ),
              ),
            ),
            const SizedBox(height: S.x2),
            Row(
              children: [
                Text(
                  l?.ecgProgress(s.progress) ?? '${s.progress}% complete',
                  style: F.cap.copyWith(color: p.ink3),
                ),
                const Spacer(),
                if (s.liveHr != null) ...[
                  Text('${s.liveHr}', style: F.n24.copyWith(color: p.ink)),
                  const SizedBox(width: S.x1),
                  Text('bpm', style: F.cap.copyWith(color: p.ink3)),
                ],
              ],
            ),
          ],
          if (armed) ...[
            const SizedBox(height: S.x4),
            EcgLivePreview(
              buffer: live,
              scheduler: scheduler,
              label: l?.ecgLivePreview ?? 'Live signal preview',
              unit: 'µV',
            ),
          ],
        ],
      );
    }

    switch (s.phase) {
      case EcgCapturePhase.idle:
        return const SizedBox.shrink();
      case EcgCapturePhase.incompatible:
        return StatusCard(
          l?.ecgIncompatible ?? 'This band is not a WHOOP MG.',
          l?.ecgNeedsMg ?? 'Take ECG needs a connected WHOOP MG.',
          icon: LucideIcons.circleOff,
        );
      case EcgCapturePhase.disconnected:
        return StatusCard(
          l?.ecgDisconnected ?? 'Connect your WHOOP MG first.',
          l?.ecgNeedsMg ?? 'Take ECG needs a connected WHOOP MG.',
          icon: LucideIcons.bluetoothOff,
        );
      case EcgCapturePhase.busy:
        return StatusCard(
          l?.ecgBusy ?? 'Finish the other live session first.',
          s.reason ?? '',
          icon: LucideIcons.hourglass,
        );
      case EcgCapturePhase.saving:
      case EcgCapturePhase.cleaningUp:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: S.x4),
              body(
                s.phase == EcgCapturePhase.saving
                    ? (l?.ecgSaving ?? 'Saving…')
                    : (l?.ecgCleaningUp ?? 'Stopping the band…'),
              ),
            ],
          ),
        );
      case EcgCapturePhase.completed:
        return ListView(
          children: [
            const SizedBox(height: S.x6),
            title(l?.ecgCompleted ?? 'Reading saved'),
            const SizedBox(height: S.x2),
            body(
              l?.ecgNotDiagnosis ??
                  'The category comes from the band. This is not a diagnosis.',
            ),
            if (s.cleanupIncomplete) ...[
              const SizedBox(height: S.x3),
              body(
                l?.ecgCleanupIncomplete ??
                    'The band may still be generating. It will be stopped on '
                        'the next connection.',
              ),
            ],
            const SizedBox(height: S.x6),
            button(l?.ecgViewReading ?? 'View reading', onView),
            const SizedBox(height: S.x3),
            button(l?.ecgDone ?? 'Done', onDone, primary: false),
          ],
        );
      case EcgCapturePhase.unreadable:
        final reasons = ecgReasonLabels(l, s.unreadableMask);
        return ListView(
          children: [
            const SizedBox(height: S.x6),
            title(l?.ecgUnreadableTitle ?? 'The band could not read this'),
            const SizedBox(height: S.x2),
            body(l?.ecgBandReported ?? 'Band-reported result'),
            for (final r in reasons) ...[
              const SizedBox(height: S.x1),
              Text('· $r', style: F.body.copyWith(color: p.ink)),
            ],
            const SizedBox(height: S.x6),
            button(l?.ecgTakeAnother ?? 'Take another', onTakeAnother),
            const SizedBox(height: S.x3),
            button(l?.ecgDone ?? 'Done', onDone, primary: false),
          ],
        );
      case EcgCapturePhase.inconclusiveRetry:
        return ListView(
          children: [
            const SizedBox(height: S.x6),
            title(l?.ecgInconclusiveTitle ?? 'Inconclusive'),
            const SizedBox(height: S.x2),
            body(
              l?.ecgInconclusiveRetryHint ??
                  'The band could not decide. You can try once more.',
            ),
            const SizedBox(height: S.x6),
            button(l?.ecgTryOnceMore ?? 'Try once more', onRetry),
            const SizedBox(height: S.x3),
            button(l?.ecgDone ?? 'Done', onDone, primary: false),
          ],
        );
      case EcgCapturePhase.cancelled:
      case EcgCapturePhase.failed:
        final why = switch (s.reason) {
          'disconnected' =>
            l?.ecgFailedDisconnected ?? 'The band disconnected.',
          'timeout' => l?.ecgFailedTimeout ?? 'No result within two minutes.',
          'cancelled' || 'paused' || null => '',
          final r =>
            l?.ecgFailedGeneric(r) ??
                'The band did not accept the reading ($r).',
        };
        return ListView(
          children: [
            const SizedBox(height: S.x6),
            title(
              s.phase == EcgCapturePhase.cancelled
                  ? (l?.ecgCancelledTitle ?? 'Reading cancelled')
                  : (l?.ecgFailedTitle ?? 'Reading failed'),
            ),
            if (why.isNotEmpty) ...[const SizedBox(height: S.x2), body(why)],
            if (s.cleanupIncomplete) ...[
              const SizedBox(height: S.x3),
              body(
                l?.ecgCleanupIncomplete ??
                    'The band may still be generating. It will be stopped on '
                        'the next connection.',
              ),
            ],
            const SizedBox(height: S.x6),
            button(l?.ecgTakeAnother ?? 'Take another', onTakeAnother),
            const SizedBox(height: S.x3),
            button(l?.ecgDone ?? 'Done', onDone, primary: false),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

// ═══════════════════ detail ═══════════════════

class EcgDetailData {
  final EcgReading reading;
  final List<EcgAcceptedPacket> packets;
  const EcgDetailData({required this.reading, required this.packets});

  static Future<EcgDetailData?> load(String id) async {
    final row = await LocalDb.ecgReading(id);
    final reading = row == null ? null : EcgReading.fromRow(row);
    if (reading == null) return null;
    final packets = (await LocalDb.ecgReadingPackets(
      id,
    )).map(EcgPacketCodec.fromRow).toList();
    return EcgDetailData(reading: reading, packets: packets);
  }
}

class EcgDetailScreen extends StatefulWidget {
  final EcgDetailData data;
  const EcgDetailScreen({super.key, required this.data});

  @override
  State<EcgDetailScreen> createState() => _EcgDetailScreenState();
}

/// The message the coach receives for "Analyze now" — sent visibly as the
/// user's own turn; the model must call `get_ecg_reading` itself.
String ecgAnalyzePrompt(String id) =>
    'Analyse my ECG reading $id. Use get_ecg_reading. Start with signal '
    'quality and the band-reported result, then read the waveform itself — '
    'rate, rhythm and its regularity, intervals and morphology — and give '
    'your impression. Say where the trace or its unproven polarity does not '
    'support a reading, and say so if you disagree with the band.';

class _EcgDetailScreenState extends State<EcgDetailScreen> {
  static const _scales = [40.0, 80.0, 160.0, 320.0];
  int _scale = 1;

  Future<void> _analyze(BuildContext c) async {
    final l = AppLocalizations.of(c);
    final id = widget.data.reading.id;
    if (!coachReadyNow(c)) {
      await Navigator.of(
        c,
      ).push(themedRoute((_) => const CoachSetup(), name: 'CoachSetup'));
      if (!c.mounted || !coachReadyNow(c)) return;
    }
    final cfg = c.read<CoachConfig>();
    if (!cfg.isLocalEndpoint) {
      final host = Uri.tryParse(cfg.apiBase)?.host ?? cfg.apiBase;
      final ok = await showDialog<bool>(
        context: c,
        builder: (dc) => AlertDialog(
          title: Text(
            l?.ecgAnalyzeCloudTitle ?? 'Send this reading to your model?',
          ),
          content: Text(
            l?.ecgAnalyzeCloudBody(host, cfg.model) ??
                'The reading summary and the full waveform (every sample the '
                    'band recorded, 100 per second) will be sent to $host as '
                    '${cfg.model}. No raw frames, no band serial.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dc).pop(false),
              child: Text(l?.ecgCancel ?? 'Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dc).pop(true),
              child: Text(l?.ecgContinue ?? 'Continue'),
            ),
          ],
        ),
      );
      if (ok != true || !c.mounted) return;
    }
    await Navigator.of(c).push(
      themedRoute(
        (_) => CoachScreen(
          initialMessage: ecgAnalyzePrompt(id),
          startNewSession: true,
        ),
        name: 'CoachScreen',
      ),
    );
  }

  Future<void> _delete(BuildContext c) async {
    await LocalDb.deleteEcgReading(widget.data.reading.id);
    if (c.mounted) Navigator.of(c).pop();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final r = widget.data.reading;
    final packets = widget.data.packets;
    final px = _scales[_scale];
    final cat = ecgCategoryLabel(l, r.category);
    Widget kv(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x1),
      child: Row(
        children: [
          Expanded(
            child: Text(k, style: F.body.copyWith(color: p.ink2)),
          ),
          Text(v, style: F.body.copyWith(color: p.ink)),
        ],
      ),
    );
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(backgroundColor: p.bg, title: Text(l?.ecgTitle ?? 'ECG')),
      body: ListView(
        padding: pad,
        children: [
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l?.ecgBandReported ?? 'Band-reported result',
                  style: F.cap.copyWith(color: p.ink3),
                ),
                const SizedBox(height: S.x1),
                Text(cat, style: F.t2.copyWith(color: p.ink)),
                const SizedBox(height: S.x1),
                Text(_fmtWhen(r.startTs), style: F.cap.copyWith(color: p.ink3)),
                if (r.status == EcgReadingStatus.inconclusive ||
                    r.category == EcgCategory.unreadable) ...[
                  const SizedBox(height: S.x2),
                  for (final reason in ecgReasonLabels(l, r.unreadableMask))
                    Text('· $reason', style: F.body.copyWith(color: p.ink)),
                ],
                const SizedBox(height: S.x3),
                Text(
                  l?.ecgNotDiagnosis ??
                      'The category comes from the band. This is not a diagnosis.',
                  style: F.cap.copyWith(color: p.ink3),
                ),
              ],
            ),
          ),
          const SizedBox(height: S.x4),
          Section(
            l?.ecgWaveformLabel ??
                'Accepted waveform, microvolts as the band sent them. Gaps are '
                    'missing seconds.',
            packets.isEmpty
                ? StatusCard(
                    l?.ecgWaveformEmpty ??
                        'No waveform was saved with this reading.',
                    '',
                    icon: LucideIcons.activity,
                  )
                : Surface(
                    pad: const EdgeInsets.all(S.x3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '±${EcgWaveformPainter.rangeFor(packets)} µV',
                              style: F.cap.copyWith(color: p.ink3),
                            ),
                            const Spacer(),
                            Pressable(
                              semanticLabel: l?.ecgZoomOut ?? 'Zoom out',
                              onTap: _scale > 0
                                  ? () => setState(() => _scale--)
                                  : null,
                              child: Icon(
                                LucideIcons.zoomOut,
                                size: 20,
                                color: p.ink2,
                              ),
                            ),
                            const SizedBox(width: S.x3),
                            Pressable(
                              semanticLabel: l?.ecgZoomIn ?? 'Zoom in',
                              onTap: _scale < _scales.length - 1
                                  ? () => setState(() => _scale++)
                                  : null,
                              child: Icon(
                                LucideIcons.zoomIn,
                                size: 20,
                                color: p.ink2,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: S.x2),
                        SizedBox(
                          height: 180,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: RepaintBoundary(
                              child: CustomPaint(
                                size: Size(
                                  EcgWaveformPainter.widthFor(packets, px),
                                  180,
                                ),
                                painter: EcgWaveformPainter(
                                  packets: packets,
                                  pxPerSecond: px,
                                  color: C.domHealth,
                                  grid: p.line,
                                  gap: p.wash(C.orange),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: S.x2),
                        Text(
                          l?.ecgSampleNote(r.sampleCount, kEcgSampleRateHz) ??
                              '${r.sampleCount} samples at $kEcgSampleRateHz Hz, '
                                  'filtered, input-referred µV. No lead or '
                                  'polarity is claimed.',
                          style: F.cap.copyWith(color: p.ink3),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: S.x4),
          Surface(
            child: Column(
              children: [
                kv(
                  l?.ecgAvgHr ?? 'Average heart rate',
                  r.avgHr == null ? '—' : '${r.avgHr} bpm',
                ),
                kv(
                  l?.ecgQuality ?? 'Signal quality',
                  r.quality == null ? '—' : '${r.quality}',
                ),
                kv(l?.ecgDuration ?? 'Duration', '${r.durationS} s'),
                kv(
                  l?.ecgInterruptions ?? 'Interruptions',
                  '${r.interruptions}',
                ),
                kv(
                  l?.ecgMissingSegments ?? 'Missing segments',
                  '${r.missingSegments}',
                ),
                kv(l?.ecgWristLabel ?? 'Wrist', _wristLabel(l, r.wrist)),
              ],
            ),
          ),
          const SizedBox(height: S.x4),
          ActionCard(
            l?.ecgAnalyzeNow ?? 'Analyze now',
            l?.ecgBandReported ?? 'Band-reported result',
            l?.ecgAnalyzeNow ?? 'Analyze now',
            LucideIcons.sparkles,
            kCoachAccent,
            onTap: () => _analyze(c),
          ),
          const SizedBox(height: S.x4),
          Pressable(
            semanticLabel: l?.ecgDelete ?? 'Delete reading',
            onTap: () => _delete(c),
            child: Padding(
              padding: const EdgeInsets.all(S.x3),
              child: Text(
                l?.ecgDelete ?? 'Delete reading',
                textAlign: TextAlign.center,
                style: F.body.copyWith(color: C.red),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
