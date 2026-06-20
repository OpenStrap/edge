// Data models shared across the app.

/// The HEADER of a 1 Hz record (type-24 / R10): timestamp + counter + HR. The
/// sensor block is NOT decoded on-device — the band is a raw pipe, the full frame
/// is uploaded as hex and the cloud owns the sensor decode.
class Sample {
  final int tsEpoch;
  final int counter;
  final int hr; // 0 = off-wrist (never display as a heart rate)

  Sample({
    required this.tsEpoch,
    required this.counter,
    required this.hr,
  });

  bool get wristOn => hr > 0;

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
