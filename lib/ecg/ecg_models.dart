// WHOOP MG ECG — domain models shared by the reducer, the controller, the
// store and the UI. Pure Dart.
//
// Everything here is the BAND'S result. The category comes from the band's
// HeartKey result code plus a heart rate through the official app's fixed
// mapping; nothing on the phone classifies the waveform, and no anatomical
// lead or polarity is claimed for the samples.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Which wrist the band is worn on — the official opcode-123 selector.
enum EcgWrist {
  left,
  right;

  WristSelection get selection =>
      this == EcgWrist.left ? WristSelection.left : WristSelection.right;

  static EcgWrist? parse(String? s) => switch (s) {
    'left' => EcgWrist.left,
    'right' => EcgWrist.right,
    _ => null,
  };
}

/// The official app's user-facing categories, from HeartKey result code plus
/// a heart rate (docs/mg/05 §5). Always presented as "band-reported".
enum EcgCategory {
  unreadable,
  sinusRhythm,
  lowHeartRate,
  possibleAfib,
  afibHighHeartRate,
  highHeartRate,
  highHeartRateNoAfib,
  inconclusive;

  static EcgCategory? parse(String? s) {
    for (final c in values) {
      if (c.name == s) return c;
    }
    return null;
  }
}

/// The exact result-plus-HR table. Unknown codes and known codes outside
/// their accepted HR range fall back to unreadable, like the official app.
EcgCategory categoryFor(int result, int hr) {
  switch (result) {
    case 0:
    case 2:
      return EcgCategory.unreadable;
    case 1:
      return (hr >= 51 && hr <= 99)
          ? EcgCategory.sinusRhythm
          : EcgCategory.unreadable;
    case 3:
      return hr <= 50 ? EcgCategory.lowHeartRate : EcgCategory.unreadable;
    case 4:
      if (hr >= 51 && hr <= 99) return EcgCategory.possibleAfib;
      if (hr >= 100 && hr <= 150) return EcgCategory.afibHighHeartRate;
      if (hr >= 151 && hr <= 200) return EcgCategory.highHeartRate;
      return EcgCategory.unreadable;
    case 5:
      if (hr >= 100 && hr <= 150) return EcgCategory.highHeartRateNoAfib;
      if (hr >= 151 && hr <= 200) return EcgCategory.highHeartRate;
      return EcgCategory.unreadable;
    case 6:
      return EcgCategory.inconclusive;
    default:
      return EcgCategory.unreadable;
  }
}

/// One entry of the accepted window: an accepted R17 packet, or the ONE
/// empty placeholder the official accumulator inserts at a sequence jump.
class EcgAcceptedPacket {
  final int sequence;
  final int strapSeconds;
  final int strapSubsec;
  final Int16List samples;
  final Uint8List inner;
  final bool placeholder;

  const EcgAcceptedPacket({
    required this.sequence,
    required this.strapSeconds,
    required this.strapSubsec,
    required this.samples,
    required this.inner,
    this.placeholder = false,
  });

  factory EcgAcceptedPacket.of(LabradorR17 r) => EcgAcceptedPacket(
    sequence: r.sequence,
    strapSeconds: r.strapSeconds,
    strapSubsec: r.subseconds,
    samples: r.samples,
    inner: r.inner,
  );

  factory EcgAcceptedPacket.placeholder(int sequence) => EcgAcceptedPacket(
    sequence: sequence,
    strapSeconds: 0,
    strapSubsec: 0,
    samples: Int16List(0),
    inner: Uint8List(0),
    placeholder: true,
  );
}

/// Persisted status of a reading. Unreadable and first-attempt-inconclusive
/// terminals are not persisted (official behaviour); a retried inconclusive
/// is.
enum EcgReadingStatus {
  completed,
  inconclusive;

  static EcgReadingStatus? parse(String? s) {
    for (final v in values) {
      if (v.name == s) return v;
    }
    return null;
  }
}

/// Sample statistics over the accepted window (placeholders contribute
/// nothing but a missing-segment count).
class EcgWindowStats {
  final int sampleCount;
  final int? minUv;
  final int? maxUv;
  final double? rmsUv;
  final int missingSegments;

  const EcgWindowStats({
    required this.sampleCount,
    required this.minUv,
    required this.maxUv,
    required this.rmsUv,
    required this.missingSegments,
  });

  static EcgWindowStats of(List<EcgAcceptedPacket> packets) {
    var n = 0;
    var missing = 0;
    int? lo;
    int? hi;
    var sumSq = 0.0;
    for (final p in packets) {
      if (p.placeholder) {
        missing++;
        continue;
      }
      for (final s in p.samples) {
        n++;
        lo = lo == null ? s : math.min(lo, s);
        hi = hi == null ? s : math.max(hi, s);
        sumSq += s * s;
      }
    }
    return EcgWindowStats(
      sampleCount: n,
      minUv: lo,
      maxUv: hi,
      rmsUv: n == 0 ? null : math.sqrt(sumSq / n),
      missingSegments: missing,
    );
  }
}

/// The unit every stored sample carries: 100 Hz filtered/decimated
/// input-referred integer microvolts, exactly as the band sends them.
const String kEcgSampleUnit = 'filtered_input_referred_uv';
const int kEcgSampleRateHz = 100;
const String kEcgSource = 'mg_labrador';

/// One saved reading — `ecg_reading` as a typed row.
class EcgReading {
  final String id;
  final String deviceId;
  final EcgWrist wrist;
  final int startTs; // epoch seconds
  final int endTs; // epoch seconds
  final int? strapTerminalTs; // strap seconds
  final int? strapTerminalSubsec;
  final int resultCode;
  final EcgCategory category;
  final int? avgHr;
  final int? quality;
  final int unreadableMask;
  final int interruptions;
  final int sampleCount;
  final int? minUv;
  final int? maxUv;
  final double? rmsUv;
  final int missingSegments;
  final EcgReadingStatus status;
  final String? notes;
  final int createdAt; // epoch ms

  const EcgReading({
    required this.id,
    required this.deviceId,
    required this.wrist,
    required this.startTs,
    required this.endTs,
    required this.strapTerminalTs,
    required this.strapTerminalSubsec,
    required this.resultCode,
    required this.category,
    required this.avgHr,
    required this.quality,
    required this.unreadableMask,
    required this.interruptions,
    required this.sampleCount,
    required this.minUv,
    required this.maxUv,
    required this.rmsUv,
    required this.missingSegments,
    required this.status,
    required this.notes,
    required this.createdAt,
  });

  int get durationS => endTs - startTs;

  List<String> get unreadableReasons =>
      LabradorUnreadableMask(unreadableMask).reasons;

  Map<String, Object?> toRow() => {
    'id': id,
    'device_id': deviceId,
    'source': kEcgSource,
    'wrist': wrist.name,
    'start_ts': startTs,
    'end_ts': endTs,
    'strap_terminal_ts': strapTerminalTs,
    'strap_terminal_subsec': strapTerminalSubsec,
    'result_code': resultCode,
    'category': category.name,
    'avg_hr': avgHr,
    'quality': quality,
    'unreadable_mask': unreadableMask,
    'interruptions': interruptions,
    'sample_rate_hz': kEcgSampleRateHz,
    'sample_unit': kEcgSampleUnit,
    'sample_count': sampleCount,
    'min_uv': minUv,
    'max_uv': maxUv,
    'rms_uv': rmsUv,
    'missing_segments': missingSegments,
    'status': status.name,
    'notes': notes,
    'created_at': createdAt,
  };

  static EcgReading? fromRow(Map<String, Object?> r) {
    final wrist = EcgWrist.parse(r['wrist'] as String?);
    final category = EcgCategory.parse(r['category'] as String?);
    final status = EcgReadingStatus.parse(r['status'] as String?);
    final id = r['id'] as String?;
    if (id == null || wrist == null || category == null || status == null) {
      return null;
    }
    int? i(String k) => (r[k] as num?)?.toInt();
    return EcgReading(
      id: id,
      deviceId: (r['device_id'] as String?) ?? '',
      wrist: wrist,
      startTs: i('start_ts') ?? 0,
      endTs: i('end_ts') ?? 0,
      strapTerminalTs: i('strap_terminal_ts'),
      strapTerminalSubsec: i('strap_terminal_subsec'),
      resultCode: i('result_code') ?? 0,
      category: category,
      avgHr: i('avg_hr'),
      quality: i('quality'),
      unreadableMask: i('unreadable_mask') ?? 0,
      interruptions: i('interruptions') ?? 0,
      sampleCount: i('sample_count') ?? 0,
      minUv: i('min_uv'),
      maxUv: i('max_uv'),
      rmsUv: (r['rms_uv'] as num?)?.toDouble(),
      missingSegments: i('missing_segments') ?? 0,
      status: status,
      notes: r['notes'] as String?,
      createdAt: i('created_at') ?? 0,
    );
  }
}

/// `ecg_reading_packet` row codec. Samples are the exact signed-i16-LE bytes.
class EcgPacketCodec {
  static Uint8List encodeSamples(Int16List samples) {
    final out = Uint8List(samples.length * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < samples.length; i++) {
      bd.setInt16(2 * i, samples[i], Endian.little);
    }
    return out;
  }

  static Int16List decodeSamples(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final out = Int16List(n);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(2 * i, Endian.little);
    }
    return out;
  }

  static String hex(Uint8List b) {
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Map<String, Object?> toRow(EcgAcceptedPacket p) => {
    'sequence': p.sequence,
    'strap_seconds': p.placeholder ? null : p.strapSeconds,
    'strap_subsec': p.placeholder ? null : p.strapSubsec,
    'sample_count': p.samples.length,
    'samples': encodeSamples(p.samples),
    'inner_hex': hex(p.inner),
    'is_placeholder': p.placeholder ? 1 : 0,
  };

  static EcgAcceptedPacket fromRow(Map<String, Object?> r) {
    final placeholder = ((r['is_placeholder'] as num?)?.toInt() ?? 0) != 0;
    final raw = r['samples'];
    final bytes = raw is Uint8List
        ? raw
        : raw is List<int>
        ? Uint8List.fromList(raw)
        : Uint8List(0);
    return EcgAcceptedPacket(
      sequence: (r['sequence'] as num?)?.toInt() ?? 0,
      strapSeconds: (r['strap_seconds'] as num?)?.toInt() ?? 0,
      strapSubsec: (r['strap_subsec'] as num?)?.toInt() ?? 0,
      samples: decodeSamples(bytes),
      inner: hexToBytes((r['inner_hex'] as String?) ?? ''),
      placeholder: placeholder,
    );
  }
}

/// The reading id: text, derived from when the accepted window opened and
/// the terminal strap second, so two devices' exports cannot collide on an
/// autoincrement.
String ecgReadingId({required int startEpochMs, required int terminalStrapS}) =>
    'ecg_${startEpochMs}_$terminalStrapS';
