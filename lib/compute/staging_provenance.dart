/// Typed read boundary for the optional provenance in a stored sleep section.
/// Unknown method/reason strings survive newer exports; malformed values stay
/// absent. Durations are observed seconds that retained the original labels.
Map<String, Object> stagingProvenanceOf(Map<String, dynamic>? sleep) {
  if (sleep == null) return const {};
  final method = sleep['staging_method'];
  final effective = sleep['staging_effective_method'];
  final fallback = sleep['staging_fallback'];
  final sec = sleep['staging_fallback_sec'];
  return {
    if (method is String) 'staging_method': method,
    if (effective is String) 'staging_effective_method': effective,
    if (fallback is String) 'staging_fallback': fallback,
    if (fallback is String && sec is num && sec.isFinite && sec >= 0)
      'staging_fallback_sec': sec.round(),
  };
}
