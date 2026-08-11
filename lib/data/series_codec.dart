// series_codec.dart — the compact wire format for the intra-day curves inside
// `day_result.payload_json`.
//
// WHY. A curve used to be stored as one JSON object per sample:
//
//   [{"t":1783572180,"v":77},{"t":1783572240,"v":80}]
//
// That is 27 bytes to carry two numbers, repeating the full 10-digit epoch in
// every element, for a curve that samples on a fixed 60-second grid. `series`
// was 74.5 KB of an 88 KB bundle and `day_result` is the ONE store that grows
// without bound (raw/decoded are capped at `rawRetentionDays`).
//
// WHY NOT gzip. `payload_json` is read by SQL, not just by Dart — the coach's
// `v_series` / `v_hypnogram` views run `json_each(json_extract(payload_json,
// '$.series.…'))` over it (db.dart `_ensureCoachViews`). A compressed BLOB is
// opaque to json1, and sqflite exposes no way to register a decompress
// function, so compressing the column would silently strip every intra-day
// curve from the coach (invariant 13). Everything here therefore stays PLAIN
// JSON that json1 can still walk.
//
// THREE SHAPES, all readable forever:
//
//   legacy  [{"t":N,"v":X}, …]                 never written again
//   grid    {"t0":N,"dt":N,"v":[X, …]}         regular sampling
//   offset  {"t0":N,"to":[N, …],"v":[X, …]}    irregular sampling
//
// `grid` reconstructs in pure SQL because json_each exposes an array's index as
// `key`: t = t0 + key*dt. `offset` pairs `to` and `v` on that same `key`.
//
// Legacy staying readable is what makes this migration-free: no rewrite pass
// runs inside `openDatabase` under iOS's CPU watchdog (invariant 11). Old rows
// are re-encoded later by a bounded background pass, off the durable-commit
// path.
//
// PURE. No I/O, no plugins, no Flutter — safe on any isolate.

import 'dart:convert';

/// Encoder/decoder for the curve shapes stored in `day_result.payload_json`.
///
/// The invariant every method here upholds: **encode → decode is lossless, or
/// the curve is left alone.** There is no shape this file can write that it
/// cannot read back exactly, and anything it cannot encode losslessly passes
/// through untouched. The fallback is always "stay legacy", never "lose data".
class SeriesCodec {
  SeriesCodec._();

  /// Curves under `payload['series']`, mapped to the key their samples use for
  /// the value. `zone_timeline` is the odd one out — it carries `z`, not `v`
  /// (matching the `v_series` view, which reads `$.z` for that branch alone).
  static const Map<String, String> seriesCurves = {
    'hr_curve': 'v',
    'strain_curve': 'v',
    'hrv_timeline': 'v',
    'hrv_day': 'v',
    'resp_day': 'v',
    'skin_temp_day': 'v',
    'zone_timeline': 'z',
  };

  /// Curves living at the bundle ROOT rather than under `series`.
  /// `activity_curve` is surfaced by `v_series` like the rest, so it gets the
  /// same treatment.
  static const Map<String, String> rootCurves = {'activity_curve': 'v'};

  /// Below this, the envelope (`t0`/`dt`/`to` keys) costs more than the
  /// per-sample repetition it removes, so encoding is not worth it.
  static const int minPoints = 3;

  // ── encode ─────────────────────────────────────────────────────────────────

  /// Encode one curve to `grid` or `offset`, or return [raw] UNCHANGED when it
  /// cannot be encoded losslessly.
  ///
  /// Refuses (and so leaves legacy) when any of these hold, because each one
  /// would make the round-trip lossy or change what SQL sees:
  ///   • fewer than [minPoints] samples
  ///   • an element that is not a Map, or whose keys are not exactly
  ///     `{t, valueKey}` — an extra key would be dropped by the columnar form
  ///   • a `t` that is not an `int` — a double `t` would come back out of the
  ///     SQL branch as `t0 + key*dt` in a different numeric type than
  ///     `json_extract($.t)` produced before
  static Object? encodeCurve(Object? raw, {String valueKey = 'v'}) {
    if (raw is! List || raw.length < minPoints) return raw;

    final ts = <int>[];
    final vs = <Object?>[];
    for (final e in raw) {
      if (e is! Map) return raw;
      // Exactly {t, valueKey} — nothing else survives the columnar form.
      if (e.length != 2 || !e.containsKey('t') || !e.containsKey(valueKey)) {
        return raw;
      }
      final t = e['t'];
      if (t is! int) return raw;
      ts.add(t);
      vs.add(e[valueKey]);
    }

    // A single positive delta across the whole curve ⇒ a true grid.
    final dt = ts[1] - ts[0];
    if (dt > 0) {
      var regular = true;
      for (var i = 2; i < ts.length; i++) {
        if (ts[i] - ts[i - 1] != dt) {
          regular = false;
          break;
        }
      }
      if (regular) return {'t0': ts[0], 'dt': dt, 'v': vs};
    }

    final t0 = ts[0];
    return {
      't0': t0,
      'to': [for (final t in ts) t - t0],
      'v': vs,
    };
  }

  /// Encode every known curve in a decoded bundle and return the result.
  ///
  /// PURE — the argument is not modified. Rebuilding rather than writing
  /// through matters: `Map<String, dynamic>` accepts a caller's more narrowly
  /// inferred map (a literal of nothing but curves infers as
  /// `Map<String, List<…>>`), and storing an encoded object into that throws at
  /// runtime. The shallow copies are a few dozen entries against an ~88 KB
  /// bundle.
  ///
  /// Idempotent: an already-encoded curve is not a `List`, so [encodeCurve]
  /// hands it straight back.
  static Map<String, dynamic> encodePayload(Map<String, dynamic> payload) {
    final out = Map<String, dynamic>.from(payload);
    final series = out['series'];
    if (series is Map) {
      final encodedSeries = Map<String, dynamic>.from(series);
      for (final entry in seriesCurves.entries) {
        if (!encodedSeries.containsKey(entry.key)) continue;
        encodedSeries[entry.key] = encodeCurve(
          encodedSeries[entry.key],
          valueKey: entry.value,
        );
      }
      out['series'] = encodedSeries;
    }
    for (final entry in rootCurves.entries) {
      if (!out.containsKey(entry.key)) continue;
      out[entry.key] = encodeCurve(out[entry.key], valueKey: entry.value);
    }
    return out;
  }

  /// Encode a serialized bundle. Returns [payloadJson] unchanged when it is not
  /// a JSON object — a caller must never lose a payload to this optimization.
  static String encodePayloadJson(String payloadJson) {
    if (payloadJson.isEmpty) return payloadJson;
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return payloadJson;
      return jsonEncode(encodePayload(decoded.cast<String, dynamic>()));
    } catch (_) {
      return payloadJson;
    }
  }

  // ── decode ─────────────────────────────────────────────────────────────────

  /// Normalize one curve back to the legacy `[{t, valueKey}, …]` shape.
  ///
  /// A `List` (legacy) is returned as-is, and so is a Map that is not one of
  /// the envelope shapes this file writes.
  ///
  /// PASS THROUGH rather than empty. This used to return `const []` for
  /// anything it did not recognise, which is a silent TOTAL LOSS: [decodePayload]
  /// is the read seam for every stored payload, not just day bundles — baselines,
  /// `compute_freshness` and wake features share it — so a foreign map that
  /// happened to sit under a curve key would be replaced by nothing on the way
  /// out. Handing the value back unchanged costs the same and cannot destroy
  /// anything; a caller that wanted a curve still sees a non-List and ignores it.
  static Object? decodeCurve(Object? raw, {String valueKey = 'v'}) {
    if (raw is! Map) return raw;

    final t0 = raw['t0'];
    final vs = raw['v'];
    if (t0 is! int || vs is! List) return raw;

    final dt = raw['dt'];
    if (dt is int) {
      return [
        for (var i = 0; i < vs.length; i++) {'t': t0 + i * dt, valueKey: vs[i]},
      ];
    }

    final to = raw['to'];
    if (to is! List || to.length != vs.length) return raw;
    // ALL the offsets or none of them. Skipping just the entries that are not
    // ints emitted a SHORT curve — a plausible-looking curve quietly missing
    // samples, which is worse than one the reader can see is unusable, and
    // `verifyLossless` could not tell because it compares decode against
    // decode, not against the original. [encodeCurve] cannot produce this (it
    // only writes int offsets); a foreign or corrupted payload can, and for
    // those the file's rule applies — leave it alone rather than half-read it.
    //
    // SQL DIVERGES HERE and cannot be made to agree cheaply: `v_series` adds
    // `to[key]` to `t0` per row, so a fractional offset comes out as a
    // fractional `t` rather than being suppressed. Checking every offset's type
    // in the view would cost a json_type call per sample on the coach's hottest
    // path, to defend a shape nothing in this app writes.
    for (final o in to) {
      if (o is! int) return raw;
    }
    return [
      for (var i = 0; i < vs.length; i++)
        {'t': t0 + (to[i] as int), valueKey: vs[i]},
    ];
  }

  /// Normalize every known curve in a decoded bundle and return the result.
  ///
  /// PURE, for the same reason as [encodePayload].
  ///
  /// THE single read-side entry point. Every site that turns a stored
  /// `payload_json` string into a Map calls this, so no downstream reader has
  /// to know the wire format exists (§4.7: one concern, all call sites).
  ///
  /// Safe on payloads that are not day bundles (baselines, freshness, wake
  /// features all share `local_repository_impl._decode`): it only rewrites keys
  /// already in grid/offset shape, which nothing but the write seam produces.
  /// Idempotent — a legacy `List` is handed straight back.
  static Map<String, dynamic>? decodePayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final out = Map<String, dynamic>.from(payload);
    final series = out['series'];
    if (series is Map) {
      final decodedSeries = Map<String, dynamic>.from(series);
      for (final entry in seriesCurves.entries) {
        final cur = decodedSeries[entry.key];
        if (cur is! Map) continue; // legacy or absent — nothing to do
        decodedSeries[entry.key] = decodeCurve(cur, valueKey: entry.value);
      }
      out['series'] = decodedSeries;
    }
    for (final entry in rootCurves.entries) {
      final cur = out[entry.key];
      if (cur is! Map) continue;
      out[entry.key] = decodeCurve(cur, valueKey: entry.value);
    }
    return out;
  }

  /// Decode a serialized bundle straight to a normalized Map, or null when it
  /// is absent/unparseable. Mirrors the `try/catch → null` contract of the
  /// existing `_decode` helpers.
  static Map<String, dynamic>? decodePayloadJson(Object? payloadJson) {
    if (payloadJson is! String || payloadJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return null;
      return decodePayload(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// True when re-encoding [payloadJson] provably loses nothing: the encoded
  /// form decodes back to exactly what the original decodes to.
  ///
  /// The round-trip is unit-tested, but the backfill uses this as a per-row
  /// gate before OVERWRITING durable user data. A day older than
  /// `rawRetentionDays` has no substrate left to re-derive from, so a lossy
  /// rewrite there would be unrecoverable — cheap insurance against a future
  /// bundle shape this codec has never seen.
  static bool verifyLossless(String payloadJson) {
    try {
      final original = jsonDecode(payloadJson);
      if (original is! Map) return false;
      final reencoded = decodePayloadJson(
        encodePayloadJson(jsonEncode(original)),
      );
      return _deepEquals(
        decodePayload(original.cast<String, dynamic>()),
        reencoded,
      );
    } catch (_) {
      return false;
    }
  }

  static bool _deepEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_deepEquals(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// True when [payloadJson] still holds at least one legacy-shaped curve, i.e.
  /// re-encoding it would shrink the row. Used by the background backfill to
  /// skip rows already converted without paying a full encode.
  static bool needsReencode(String payloadJson) {
    if (payloadJson.isEmpty) return false;
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) return false;
      final series = decoded['series'];
      if (series is Map) {
        for (final key in seriesCurves.keys) {
          final cur = series[key];
          if (cur is List && cur.length >= minPoints) return true;
        }
      }
      for (final key in rootCurves.keys) {
        final cur = decoded[key];
        if (cur is List && cur.length >= minPoints) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
