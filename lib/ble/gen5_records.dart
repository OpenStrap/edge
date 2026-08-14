// Gen5 historical records — the fields a WHOOP 5.0 / MG history packet carries
// that we can actually justify reading.
//
// WHAT IS SHARED WITH GEN4, AND WHAT IS NOT
//
// The record HEADER is common to both generations, independently established:
// this package's own gen4 captures and goose's gen5 reverse-engineering agree
// byte-for-byte on the layout AND on the per-version HR offset —
//
//     inner[1]      layout version / k-domain
//     inner[3:7]    record counter        (u32 LE)
//     inner[7:11]   unix seconds          (u32 LE)
//     inner[11:13]  sub-seconds           (u16 LE)
//     HR byte       k7→27, k9/k12/k24→17, k18→14
//
// (compare `_hrOffsetByVersion` in package:openstrap_protocol's records.dart
// with `history_hr_marker_offset` in goose's Rust/core/src/protocol.rs — same
// table, derived from different hardware by different people.)
//
// The rest of the gen4 v24 field map does NOT carry over to gen5's k18. That is
// a measured result, not a guess: running gen4's `parseR24` over a real k18
// capture reads its gravity vector as 0.27 g, far outside the 0.5–1.8 g
// plausibility gate, so the decode is correctly refused. Accelerometer, RR
// intervals and SpO₂ live somewhere else in a k18 record — or not in it at all.
//
// WHY THIS FILE DOES NOT GUESS THEM
//
// Scanning the one k18 capture we have for a plausible gravity triple yields 16
// candidate offsets, several of which overlap the timestamp field. One frame
// cannot distinguish them, and shipping a guessed offset is exactly the mistake
// that made gen5 undiscoverable in the first place (a service UUID assumed
// rather than confirmed). So this decoder reads ONLY fields with an independent
// cross-reference, and leaves the rest null — an absent field is honest and
// recoverable; a wrong one silently poisons every downstream metric.
//
// Fields below are cross-referenced against geniemax-core's k18 decode
// (Sources/GenieMax/WhoopDecode.swift) and its recorded golden values.

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

/// HR byte offset within a history record inner, keyed by the k-domain at
/// inner[1]. Deliberately duplicated from the gen4 table rather than imported:
/// this is the gen5 evidence (goose's `history_hr_marker_offset`), and if the
/// two ever diverge, that divergence must be visible, not silently resolved.
const Map<int, int> kGen5HrOffsetByKDomain = {
  7: 27,
  9: 17,
  12: 17,
  18: 14,
  24: 17,
};

/// The k-domain gen5 straps use for their 1 Hz history record.
const int kGen5HistoryKDomain = 18;

/// Byte offset of the respiratory-rate value inside a k18 record.
const int _k18RespOffset = 35;

/// Byte offset of the skin temperature (int16 LE, centi-degrees C) in a k18.
const int _k18SkinTempOffset = 65;

/// Minimum length of a k18 record that carries the temperature field.
const int _k18MinLength = 67;

/// The verified subset of a gen5 history record.
///
/// Every field here has a recorded golden value from a real strap. Anything not
/// listed is not "zero" — it is unknown, and is represented as null so a
/// consumer can tell the difference.
class Gen5HistoryRecord {
  /// Unix seconds from the record itself (inner[7:11]).
  final int tsEpoch;

  /// Sub-second counter (inner[11:13]).
  final int tsSubsec;

  /// Monotonic record counter (inner[3:7]) — drives band-reboot detection.
  final int counter;

  /// Beats per minute. 0 legitimately means off-wrist, as it does for gen4.
  final int hr;

  /// The k-domain this record was decoded as (inner[1]).
  final int kDomain;

  /// Breaths per minute, k18 only. Null when the record is another k-domain.
  final int? respRate;

  /// Skin temperature in hundredths of a degree Celsius, k18 only.
  ///
  /// UNITS DIFFER FROM GEN4, DELIBERATELY: gen4 stores a raw ADC count here.
  /// That is harmless because the metric is only ever consumed as a z-score
  /// against the same band's own rolling baseline (`skin_temp_adc` in the
  /// derivation engine), and a band never changes generation mid-history. Any
  /// consumer that starts treating it as an absolute value must branch on the
  /// generation first.
  final int? skinTempCentiC;

  const Gen5HistoryRecord({
    required this.tsEpoch,
    required this.tsSubsec,
    required this.counter,
    required this.hr,
    required this.kDomain,
    this.respRate,
    this.skinTempCentiC,
  });

  /// Skin temperature in degrees Celsius, or null if this record has none.
  double? get skinTempC =>
      skinTempCentiC == null ? null : skinTempCentiC! / 100.0;

  @override
  String toString() =>
      'Gen5HistoryRecord(k$kDomain ts=$tsEpoch counter=$counter hr=$hr '
      'resp=$respRate tempC=$skinTempC)';
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _i16(Uint8List b, int o) {
  final v = _u16(b, o);
  return v >= 0x8000 ? v - 0x10000 : v;
}

/// Decode the verified subset of a gen5 history record from a frame's inner.
///
/// Returns null when [inner] is not a history packet, is in a k-domain we have
/// no HR offset for, is too short, or carries an implausible heart rate. A null
/// return is the caller's signal to ARCHIVE the record rather than drop it —
/// undecodable bytes from real hardware are the raw material for the next fix.
Gen5HistoryRecord? decodeGen5History(Uint8List inner) {
  if (inner.length < 13) return null;
  if (inner[0] != PacketType.historicalData) return null;

  final k = inner[1];
  final hrOffset = kGen5HrOffsetByKDomain[k];
  if (hrOffset == null) return null; // unknown layout — archive it instead
  if (inner.length <= hrOffset) return null;

  final hr = inner[hrOffset];
  // 0 is a real reading (off-wrist), exactly as on gen4. Anything between 0 and
  // a live human range is a decode that landed on the wrong byte.
  if (hr != 0 && (hr < 25 || hr > 230)) return null;

  int? resp;
  int? skinTemp;
  if (k == kGen5HistoryKDomain && inner.length >= _k18MinLength) {
    final r = inner[_k18RespOffset];
    // Respiration is 4–60 brpm in anything alive; outside that the byte is not
    // what we think it is, so report nothing rather than something wrong.
    if (r >= 4 && r <= 60) resp = r;
    skinTemp = _i16(inner, _k18SkinTempOffset);
    // 10–50 °C brackets "on a human wrist" generously in either direction.
    if (skinTemp < 1000 || skinTemp > 5000) skinTemp = null;
  }

  return Gen5HistoryRecord(
    tsEpoch: _u32(inner, 7),
    tsSubsec: _u16(inner, 11),
    counter: _u32(inner, 3),
    hr: hr,
    kDomain: k,
    respRate: resp,
    skinTempCentiC: skinTemp,
  );
}
