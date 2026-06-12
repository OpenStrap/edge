// Data models shared across the app.

/// A decoded 1 Hz telemetry sample (from a type-24 record). Mirrors the backend
/// `samples` columns and parse_r24 output.
class Sample {
  final int tsEpoch;
  final int counter;
  final int hr; // 0 = off-wrist (never display as a heart rate)
  final int spo2;
  final double skinTempC;
  final int restingHr;
  final double ax, ay, az;

  Sample({
    required this.tsEpoch,
    required this.counter,
    required this.hr,
    required this.spo2,
    required this.skinTempC,
    required this.restingHr,
    required this.ax,
    required this.ay,
    required this.az,
  });

  bool get wristOn => hr > 0;

  Map<String, dynamic> toDbMap() => {
        'ts': tsEpoch,
        'counter': counter,
        'hr': hr,
        'spo2': spo2,
        'skin_temp_c': skinTempC,
        'resting_hr': restingHr,
        'ax': ax,
        'ay': ay,
        'az': az,
      };

  factory Sample.fromDbMap(Map<String, dynamic> m) => Sample(
        tsEpoch: m['ts'] as int,
        counter: m['counter'] as int,
        hr: m['hr'] as int,
        spo2: m['spo2'] as int,
        skinTempC: (m['skin_temp_c'] as num).toDouble(),
        restingHr: m['resting_hr'] as int,
        ax: (m['ax'] as num).toDouble(),
        ay: (m['ay'] as num).toDouble(),
        az: (m['az'] as num).toDouble(),
      );

  factory Sample.fromBackendJson(Map<String, dynamic> m) => Sample(
        tsEpoch: m['ts'] as int,
        counter: m['counter'] as int,
        hr: (m['hr'] ?? 0) as int,
        spo2: (m['spo2'] ?? 0) as int,
        skinTempC: ((m['skin_temp_c'] ?? 0) as num).toDouble(),
        restingHr: (m['resting_hr'] ?? 0) as int,
        ax: ((m['ax'] ?? 0) as num).toDouble(),
        ay: ((m['ay'] ?? 0) as num).toDouble(),
        az: ((m['az'] ?? 0) as num).toDouble(),
      );
}

/// A raw historical record exactly as it came off the band — the source of truth.
/// We keep this even when decode succeeds so the cloud can re-decode opaque bytes.
class RawRecord {
  final int counter; // u32 @[3:7] for header records; 0 for counter-less live packets
  final int packetType; // inner[0]: 0x2F historical, 0x2B/0x28/0x33 live
  final String hex; // full inner bytes, hex — the idempotency key
  final int capturedAt; // epoch ms we received it
  final bool uploaded;

  RawRecord({
    required this.counter,
    this.packetType = 0,
    required this.hex,
    required this.capturedAt,
    this.uploaded = false,
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
  int? alarmEpoch; // current strap alarm (unix sec) from GET_ALARM_TIME, if read
  String? strapName; // strap advertising name (editable via SET_ADVERTISING_NAME)
  String connection; // 'disconnected' | 'scanning' | 'connecting' | 'connected' | 'syncing'

  DeviceState({this.connection = 'disconnected'});
}
