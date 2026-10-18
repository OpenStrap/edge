// The layout shift scorer. See docs/LAYOUT_SHIFT.md "Scoring".

import 'dart:math';

import 'shift_model.dart';
import 'shift_policy.dart';

enum ShiftSeverity { none, warning, error }

class ShiftFinding {
  final String rule;
  final String elementId;
  final int atMs;
  final double score;
  final ShiftSeverity severity;
  const ShiftFinding({
    required this.rule,
    required this.elementId,
    required this.atMs,
    required this.score,
    required this.severity,
  });
}

class ShiftReport {
  final List<ShiftFinding> findings;
  const ShiftReport(this.findings);

  double get total => findings.fold(0.0, (a, f) => a + f.score);
  List<ShiftFinding> get errors =>
      findings.where((f) => f.severity == ShiftSeverity.error).toList();
  List<ShiftFinding> get warnings =>
      findings.where((f) => f.severity == ShiftSeverity.warning).toList();
}

/// True when every span of [chain] lasts within [minMs]..[maxMs].
bool chainCyclesWithin(List<AnimationSpan> chain, int minMs, int maxMs) =>
    chain.every((n) => n.endMs - n.startMs >= minMs && n.endMs - n.startMs <= maxMs);

/// Gap between two rects (0 when they touch or overlap).
double _gap(ShiftRect a, ShiftRect b) {
  final dx = max(0.0, max(a.left, b.left) - min(a.left + a.width, b.left + b.width));
  final dy = max(0.0, max(a.top, b.top) - min(a.top + a.height, b.top + b.height));
  return sqrt(dx * dx + dy * dy);
}

int _channelDelta(int a, int b, int shift) =>
    (((a >> shift) & 0xFF) - ((b >> shift) & 0xFF)).abs();

/// Scores every consecutive frame pair of [s] under [p]. Pure and
/// deterministic: same input, same report.
ShiftReport score(Scenario s, ShiftPolicy p) {
  final vpArea = s.viewport.area;
  final vpSide = max(s.viewport.width, s.viewport.height);
  final chains = <String, List<AnimationSpan>>{};
  for (final n in s.animations) {
    if (n.chainId != null) (chains[n.chainId!] ??= []).add(n);
  }
  final out = <ShiftFinding>[];

  ShiftFinding finding(String rule, String id, int at, double v) =>
      ShiftFinding(
        rule: rule,
        elementId: id,
        atMs: at,
        score: v,
        severity: v >= p.errorAt
            ? ShiftSeverity.error
            : v >= p.warnAt
                ? ShiftSeverity.warning
                : ShiftSeverity.none,
      );

  // A disabled span runs from the first disabled frame to the next enabled one.
  bool shielded(String id, int t) {
    int? from;
    for (final f in s.frames) {
      final e = f.elements.where((e) => e.id == id).firstOrNull;
      if (e == null) continue;
      if (!e.enabled) {
        from ??= f.atMs;
      } else if (from != null) {
        final len = f.atMs - from;
        if (len >= p.disabledShieldMinMs &&
            len <= p.disabledShieldMaxMs &&
            t >= from &&
            t <= f.atMs) {
          return true;
        }
        from = null;
      }
    }
    return false;
  }

  for (var i = 1; i < s.frames.length; i++) {
    final before = {for (final e in s.frames[i - 1].elements) e.id: e};
    final frame = s.frames[i];
    final now = {for (final e in frame.elements) e.id: e};
    final t = frame.atMs;
    final ix = s.interactions
        .where((x) => x.atMs <= t)
        .fold<Interaction?>(null, (m, x) => m == null || x.atMs >= m.atMs ? x : m);

    bool touches(AnimationSpan n, String id) =>
        n.elementId == null || n.elementId == id;

    double latency(String id) {
      if (ix == null) return p.outOfWindowCost;
      final dt = t - ix.atMs;
      if (dt > p.interactionWindowMs) return p.outOfWindowCost;
      final graced = s.animations.any((n) =>
          touches(n, id) &&
          n.startMs >= ix.atMs &&
          n.startMs - ix.atMs <= p.animationGraceWindowMs);
      return p.latencyAt(graced ? dt - p.animationGraceMs : dt);
    }

    double chain(String id) {
      if (ix == null) return 1;
      for (final c in chains.values) {
        final start = c.map((n) => n.startMs).reduce(min);
        final end = c.map((n) => n.endMs).reduce(max);
        if (c.any((n) => touches(n, id)) &&
            t >= start &&
            t <= end &&
            start - ix.atMs >= p.chainStartMinMs &&
            end - ix.atMs <= p.chainEndMaxMs &&
            chainCyclesWithin(c, p.chainCycleMinMs, p.chainCycleMaxMs)) {
          return p.chainDiscount;
        }
      }
      return 1;
    }

    for (final e in frame.elements) {
      final o = before[e.id];
      if (o == null) continue;
      final colorDelta = [0, 8, 16]
              .map((sh) => _channelDelta(e.colorArgb, o.colorArgb, sh))
              .reduce(max) /
          255;
      final base = o.rect.union(e.rect).area / vpArea *
              (o.rect.distanceTo(e.rect) / vpSide) +
          e.rect.area / vpArea * colorDelta * p.colorWeight;
      if (base <= 0) continue;

      var v = base * (p.roleWeight[e.role] ?? 1) * latency(e.id) * chain(e.id);
      if (ix?.intentTargetId == e.id) {
        final src = now[ix!.sourceId] ?? before[ix.sourceId];
        v *= p.pairedDiscount;
        if (src != null) {
          v *= 1 + p.pairDistanceWeight * src.rect.distanceTo(e.rect) / vpSide;
        }
      } else {
        var dFocus = 0.0;
        for (final fe in s.focus.where((f) => f.atMs <= t)) {
          final target = now[fe.elementId];
          if (target == null) continue;
          dFocus += pow(0.5, (t - fe.atMs) / p.focusHalfLifeMs) *
              target.rect.distanceTo(e.rect) /
              vpSide;
        }
        v *= 1 + p.focusDistanceWeight * dFocus;
      }
      if (e.focused) v *= p.focusedMultiplier;
      if (e.role == ElementRole.control &&
          now.values.any((q) {
            final qo = before[q.id];
            return q.id != e.id &&
                qo != null &&
                q.role == ElementRole.control &&
                _gap(o.rect, qo.rect) < p.denseGapPx &&
                (q.rect.left - e.rect.left != qo.rect.left - o.rect.left ||
                    q.rect.top - e.rect.top != qo.rect.top - o.rect.top);
          })) {
        v *= p.denseMultiplier;
      }
      if (e.focused && shielded(e.id, t)) v *= p.disabledDiscount;
      out.add(finding('shift', e.id, t, v));
    }

    // Appearing or growing elements cover focusable ones. Growth only counts
    // when the cover was not already there, so it is charged once.
    for (final e in frame.elements) {
      final o = before[e.id];
      if (o != null && e.rect.area <= o.rect.area) continue;
      for (final f in frame.elements) {
        if (!f.focusable || f.id == e.id || f.rect.area <= 0) continue;
        double frac(ShiftRect r) => (r.intersect(f.rect)?.area ?? 0) / f.rect.area;
        final fraction = frac(e.rect);
        if (fraction < p.coverMinFraction ||
            (o != null && frac(o.rect) >= p.coverMinFraction)) {
          continue;
        }
        out.add(finding(
            'cover',
            e.id,
            t,
            p.coverCost *
                fraction *
                latency(e.id) *
                (f.focused ? p.focusedMultiplier : 1)));
      }
    }
  }
  return ShiftReport(out);
}
