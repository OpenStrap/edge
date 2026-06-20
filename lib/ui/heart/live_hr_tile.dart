// LiveHrTile — the ambient "right now" heart-rate tile. Sits as the first card on
// the Heart screen. The number is the live BLE stream (device.liveHr, decoded from
// 0x28/R10 at ~1 Hz); the heart icon beats in a realistic lub-dub at the live BPM,
// with an expanding pulse ring on each beat.
//
// HONESTY GATES (project rule — never fabricate, "—" when absent):
//   • liveHr == 0  → OFF-WRIST, never a heart rate → show "—", no beat.
//   • stale (no fresh sample within _staleMs) → show "—", no beat. A 1 s ticker
//     re-evaluates freshness even when the stream stops pushing (so a frozen value
//     decays to "—" honestly).
//   • not connected → show "—", no beat.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart';

const _staleMs = 10000; // a live sample older than this is no longer "live"
const _minBpm = 30, _maxBpm = 220;

class LiveHrTile extends StatefulWidget {
  const LiveHrTile({super.key});
  @override
  State<LiveHrTile> createState() => _LiveHrTileState();
}

class _LiveHrTileState extends State<LiveHrTile> with TickerProviderStateMixin {
  // One beat cycle (lub-dub). Its duration is retuned to match the live BPM.
  late final AnimationController _beat = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 800))
    ..addStatusListener((s) {
      // Re-arm only while we have a live beat to show.
      if (s == AnimationStatus.completed && _beating) _beat.forward(from: 0);
    });

  // Freshness ticker — fires every second so a stopped stream decays to "—"
  // even though AppState isn't pushing new HR ticks.
  late final AnimationController _fresh = AnimationController(
    vsync: this, duration: const Duration(seconds: 1))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        if (mounted) setState(() {});
        _fresh.forward(from: 0);
      }
    });

  bool _beating = false;
  int _lastBpm = 0;

  @override
  void initState() {
    super.initState();
    _fresh.forward();
  }

  @override
  void dispose() {
    _beat.dispose();
    _fresh.dispose();
    super.dispose();
  }

  // Retune the beat period to the live BPM and keep it running; stop cleanly
  // when there's no live signal.
  void _sync(int? bpm, bool live) {
    final shouldBeat = live && bpm != null && bpm > 0;
    if (shouldBeat) {
      final clamped = bpm.clamp(_minBpm, _maxBpm);
      if (clamped != _lastBpm) {
        _lastBpm = clamped;
        _beat.duration = Duration(milliseconds: (60000 / clamped).round());
      }
      if (!_beating) {
        _beating = true;
        _beat.forward(from: 0);
      }
    } else if (_beating) {
      _beating = false;
      _beat.stop();
      _beat.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild only when the live-HR snapshot actually changes (not on every
    // unrelated AppState notify). Record → structural equality.
    final snap = context.select<AppState, (int?, int?, String)>((s) {
      final d = s.device;
      return (d.liveHr, d.liveHrAt, d.connection);
    });
    final (hr, at, conn) = snap;

    final connected = conn == 'connected' || conn == 'syncing';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final fresh = at != null && (nowMs - at) < _staleMs;
    final offWrist = hr == 0; // 0 is OFF-WRIST, never a heart rate
    final live = connected && fresh && hr != null && hr > 0;

    // Drive the animation off the resolved state (post-frame so we don't
    // mutate controllers during build).
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync(hr, live));

    final accent = AppColors.coral;
    final subtitle = live
        ? 'beats per minute'
        : !connected
            ? 'strap not connected'
            : offWrist
                ? 'strap off wrist'
                : 'no live signal';

    return GlowCard(
      glow: accent,
      padding: const EdgeInsets.all(Sp.x6),
      child: Row(
        children: [
          _BeatingHeart(beat: _beat, accent: accent, live: live),
          const SizedBox(width: Sp.x5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _LiveDot(beat: _beat, accent: accent, live: live),
                  const SizedBox(width: Sp.x2),
                  Text('LIVE HEART RATE', style: AppText.overline),
                ]),
                const SizedBox(height: Sp.x3),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(live ? '$hr' : '—', style: AppText.display.copyWith(color: accent)),
                  if (live) ...[
                    const SizedBox(width: Sp.x2),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: Text('bpm', style: AppText.bodySoft),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(subtitle, style: AppText.captionMuted),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The icon that beats. A realistic lub-dub scale curve + an expanding ring that
/// blooms outward and fades on each cycle.
class _BeatingHeart extends StatelessWidget {
  final AnimationController beat;
  final Color accent;
  final bool live;
  const _BeatingHeart({required this.beat, required this.accent, required this.live});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: AnimatedBuilder(
        animation: beat,
        builder: (context, child) {
          final t = beat.value;
          // lub-dub: sharp first contraction, small relax, softer second beat,
          // then settle. Two raised-cosine pulses.
          double pulse(double center, double width, double amp) {
            final x = ((t - center) / width).clamp(-1.0, 1.0);
            return amp * 0.5 * (1 + (x.abs() >= 1 ? -1.0 : math.cos(math.pi * x)));
          }
          final s = live ? 1.0 + pulse(0.10, 0.14, 0.22) + pulse(0.30, 0.12, 0.11) : 1.0;
          // Ring blooms only on the first (loud) beat.
          final ringT = (t / 0.55).clamp(0.0, 1.0);
          final ringScale = 1.0 + ringT * 0.9;
          final ringAlpha = live ? (1 - ringT) * 0.35 : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (ringAlpha > 0.01)
                Transform.scale(
                  scale: ringScale,
                  child: Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: accent.withValues(alpha: ringAlpha), width: 2),
                    ),
                  ),
                ),
              Transform.scale(
                scale: s,
                child: AppIcon(Ic.heart, size: 38,
                    color: live ? accent : AppColors.inkMuted),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Small pulsing "live" dot next to the overline — fades in sync with each beat.
class _LiveDot extends StatelessWidget {
  final AnimationController beat;
  final Color accent;
  final bool live;
  const _LiveDot({required this.beat, required this.accent, required this.live});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: beat,
      builder: (context, _) {
        final a = live ? (0.45 + 0.55 * (1 - beat.value).clamp(0.0, 1.0)) : 0.25;
        return Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: (live ? accent : AppColors.inkMuted).withValues(alpha: a),
          ),
        );
      },
    );
  }
}
