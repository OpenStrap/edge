// Metric — the canonical {value, unit, confidence, tier, label, inputs_used}
// shape every backend metric returns (see CONFIDENCE.md §6). Parsed defensively:
// the backend is finalized in parallel, so any field may be missing.

/// Confidence/honesty tier from CONFIDENCE.md.
enum MetricTier { authoritative, high, estimate, relative, unknown }

MetricTier _tierFrom(Object? raw) {
  switch (raw?.toString().toUpperCase()) {
    case 'AUTHORITATIVE':
      return MetricTier.authoritative;
    case 'HIGH':
      return MetricTier.high;
    case 'ESTIMATE':
      return MetricTier.estimate;
    case 'RELATIVE':
      return MetricTier.relative;
    default:
      return MetricTier.unknown;
  }
}

class Metric {
  final num? value;
  final String? unit;
  final double confidence; // 0..1
  final MetricTier tier;
  final String? label;
  final List<String> inputsUsed;
  final bool beta;

  /// Optional honesty / machine-readable note from the metric envelope. Carries
  /// the `need_baseline:have=H,need=N` convention for baseline-gated abstentions
  /// so the UI can render "Need N more nights" instead of a bare "—".
  final String? note;

  const Metric({
    this.value,
    this.unit,
    this.confidence = 0,
    this.tier = MetricTier.unknown,
    this.label,
    this.inputsUsed = const [],
    this.beta = false,
    this.note,
  });

  /// Parsed `need_baseline:have=H,need=N` → remaining nights (need − have, ≥1),
  /// or null when this metric is not a baseline-gated abstention. Drives the
  /// "Need N more nights" copy.
  int? get needMoreNights => needMoreNightsFromNote(note);

  /// A metric with no real data — renders as "—".
  static const empty = Metric();

  /// True when there's no number to show. CONFIDENCE rule #1.
  bool get isEmpty => value == null || confidence <= 0;

  bool get isEstimate => tier == MetricTier.estimate;
  bool get isRelative => tier == MetricTier.relative;

  /// Normalized 0..1 for ring color, given a max scale (e.g. 21 for strain,
  /// 100 for readiness). Clamped.
  double normalized(num max) {
    final v = value;
    if (v == null || max == 0) return double.nan;
    return (v / max).clamp(0.0, 1.0).toDouble();
  }

  /// Parse from a metric object OR from a bare scalar with an external `flags`
  /// entry ({c, tier, label}) — daily/sleep rows carry per-metric flags.
  factory Metric.parse(Object? raw, {Map<String, dynamic>? flag}) {
    // Case A: the metric is itself an object.
    if (raw is Map) {
      final m = raw.cast<String, dynamic>();
      return Metric(
        value: _num(m['value']),
        unit: m['unit']?.toString(),
        confidence: _dbl(m['confidence']),
        tier: _tierFrom(m['tier']),
        label: m['label']?.toString(),
        inputsUsed: _list(m['inputs_used']),
        beta: _bool(m['beta']) || _tierFrom(m['tier']) == MetricTier.estimate,
        note: m['note']?.toString(),
      );
    }
    // Case B: a scalar value + a separate flags entry {c, tier, label, beta}.
    final f = flag ?? const {};
    final tier = _tierFrom(f['tier']);
    return Metric(
      value: _num(raw),
      unit: f['unit']?.toString(),
      confidence: f.containsKey('c')
          ? _dbl(f['c'])
          : (raw == null ? 0.0 : 1.0), // bare value with no flag → assume known
      tier: tier,
      label: f['label']?.toString(),
      inputsUsed: _list(f['inputs_used']),
      beta: _bool(f['beta']) || _bool(f['x']) || tier == MetricTier.estimate,
    );
  }

  static num? _num(Object? v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  static double _dbl(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  static bool _bool(Object? v) => v == true || v == 1 || v == '1' || v == 'true';

  static List<String> _list(Object? v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }
}

/// Parse the analytics `need_baseline:have=H,need=N` note convention into the
/// number of additional nights still required (need − have, floored at 1), or
/// null if [note] isn't a need_baseline note. Lets any screen turn a baseline-
/// gated abstention into "Need N more nights" copy.
int? needMoreNightsFromNote(String? note) {
  if (note == null || !note.contains('need_baseline:')) return null;
  final m = RegExp(r'have=(\d+),need=(\d+)').firstMatch(note);
  if (m == null) return null;
  final have = int.tryParse(m.group(1)!);
  final need = int.tryParse(m.group(2)!);
  if (have == null || need == null) return null;
  final remaining = need - have;
  return remaining < 1 ? 1 : remaining;
}

/// A natural-language "need more data" message from a need_baseline note.
/// [unit] picks the wording: 'nights' (sleep/recovery/HRV-baseline metrics) →
/// "Need N more nights"; 'days' (activity/fitness) → "Wear N more days to
/// unlock". Returns null when [note] isn't a need_baseline note.
String? needMessageFromNote(String? note, {String unit = 'nights'}) {
  final n = needMoreNightsFromNote(note);
  if (n == null) return null;
  if (unit == 'days') {
    return 'Wear $n more day${n == 1 ? '' : 's'} to unlock';
  }
  return 'Need $n more night${n == 1 ? '' : 's'}';
}

/// Pull a per-metric flag map ({c, tier, label, beta}) out of a row's `flags`
/// blob, which may be a JSON string or an already-decoded map.
Map<String, dynamic>? flagFor(Object? flags, String key) {
  if (flags is Map) {
    final v = flags[key];
    if (v is Map) return v.cast<String, dynamic>();
  }
  return null;
}
