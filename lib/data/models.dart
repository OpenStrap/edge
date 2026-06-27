// Data models shared across the app.

/// The HEADER of a 1 Hz record (type-24 / R10): timestamp + counter + HR. The
/// sensor block is NOT decoded on-device — the band is a raw pipe, the full frame
/// is uploaded as hex and the cloud owns the sensor decode.
class Sample {
  final int tsEpoch;
  final int counter;
  final int hr; // 0 = off-wrist (never display as a heart rate)
  final List<int> rrIntervalsMs;
  final double? ax;
  final double? ay;
  final double? az;
  final int? spo2RedRaw;
  final int? spo2IrRaw;
  final int? skinTempRaw;

  Sample({
    required this.tsEpoch,
    required this.counter,
    required this.hr,
    this.rrIntervalsMs = const [],
    this.ax,
    this.ay,
    this.az,
    this.spo2RedRaw,
    this.spo2IrRaw,
    this.skinTempRaw,
  });

  bool get wristOn => hr > 0;
  bool get hasDecodedOneHz =>
      ax != null &&
      ay != null &&
      az != null &&
      spo2RedRaw != null &&
      spo2IrRaw != null &&
      skinTempRaw != null;

  Map<String, dynamic> toDbMap() => {
    'ts': tsEpoch,
    'counter': counter,
    'hr': hr,
  };

  factory Sample.fromDbMap(Map<String, dynamic> m) => Sample(
    tsEpoch: m['ts'] as int,
    counter: m['counter'] as int,
    hr: m['hr'] as int,
  );
}

/// A raw historical record exactly as it came off the band — the source of truth.
/// We keep this even when decode succeeds so the cloud can re-decode opaque bytes.
class RawRecord {
  final int
  counter; // u32 @[3:7] for header records; 0 for counter-less live packets
  final int packetType; // inner[0]: 0x2F historical, 0x2B/0x28/0x33 live
  final String hex; // full inner bytes, hex — the idempotency key
  final int
  capturedAt; // epoch ms we received it (STORAGE age — used for pruning)
  final bool uploaded;
  // The record's REAL device timestamp, epoch SECONDS. This — not capturedAt —
  // is what the DerivationEngine buckets/windows days by, so a multi-day flash
  // backfill (all received in one sync, one capturedAt≈now) still splits into the
  // correct per-real-day buckets. Null here means "decode at insert / fall back to
  // capturedAt/1000"; the DB column is always non-null.
  final int? recTs;

  RawRecord({
    required this.counter,
    this.packetType = 0,
    required this.hex,
    required this.capturedAt,
    this.uploaded = false,
    this.recTs,
  });
}

/// Live, in-memory device state (not persisted; rebuilt each connection).
class DeviceState {
  String? address;
  String? serial;
  double? batteryPct;
  bool? charging;
  bool? wristOn;
  int? liveHr; // latest live HR from the foreground stream
  int? liveHrAt; // epoch ms
  int?
  alarmEpoch; // current strap alarm (unix sec) from GET_ALARM_TIME, if read
  String?
  strapName; // strap advertising name (editable via SET_ADVERTISING_NAME)
  String connection; // 'disconnected' | 'scanning' | 'connecting' | 'connected'

  DeviceState({this.connection = 'disconnected'});
}
