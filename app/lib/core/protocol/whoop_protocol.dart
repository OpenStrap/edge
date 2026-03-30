// WHOOP Gen4 BLE Protocol — Dart implementation
// Source: reverse-engineered from WHOOP Android APK (see WHOOP_BLE_PROTOCOL.md)

import 'dart:typed_data';

// ── UUIDs ─────────────────────────────────────────────────────────────────────

const String kWhoopServiceUuid       = '61080001-8d6d-82b8-614a-1c8cb0f8dcc6';
const String kCmdToStrapUuid         = '61080002-8d6d-82b8-614a-1c8cb0f8dcc6';
const String kCmdFromStrapUuid       = '61080003-8d6d-82b8-614a-1c8cb0f8dcc6';
const String kEventsUuid             = '61080004-8d6d-82b8-614a-1c8cb0f8dcc6';
const String kDataUuid               = '61080005-8d6d-82b8-614a-1c8cb0f8dcc6';
const String kMemfaultUuid           = '61080007-8d6d-82b8-614a-1c8cb0f8dcc6';

// ── Packet type bytes ─────────────────────────────────────────────────────────

const int kTypeCommand        = 0x23;
const int kTypeCmdResponse    = 0x24;
const int kTypeRealtimeData   = 0x28;
const int kTypeRawRealtime    = 0x2B;
const int kTypeHistoricalData = 0x2F;
const int kTypeEvent          = 0x30;
const int kTypeMetadata       = 0x31;
const int kTypeFwLog          = 0x32;

// ── Command bytes (from im0/e.java, 3rd constructor arg) ───────────────────────

const int cmdToggleRealtimeHr       = 0x03;
const int cmdGetHelloHarvard        = 0x23;
const int cmdGetDataRange           = 0x22;
const int cmdGetAlarmTime           = 0x43;
const int cmdSendHistoricalData     = 0x16;
const int cmdGetAdvertisingName     = 0x4C;
const int cmdRunHapticsPatternHarvard   = 0x4F;
const int cmdRunHapticsPatternMaverick  = 0x13;
const int cmdSendR10R11Realtime     = 0x3F;
const int cmdTogglePersistentR21    = 0x9A;
const int cmdToggleOpticalMode      = 0x6C;const int cmdGetBodyLocationStatus  = 0x54;  // Query wrist/body locationconst int cmdStopHaptics            = 0x7A;
const int cmdRebootStrap            = 0x1D;

// ── Init sequence (HCI-snooped from official Android app) ─────────────────────

final List<Uint8List> kInitPackets = [
  Uint8List.fromList([0xaa,0x08,0x00,0xa8,0x23,0x00,0x23,0x00,0xad,0xa8,0x6a,0x2d]), // GET_HELLO_HARVARD
  Uint8List.fromList([0xaa,0x08,0x00,0xa8,0x23,0x01,0x4c,0x00,0xf2,0xb5,0xcd,0xce]), // GET_ADVERTISING_NAME
  Uint8List.fromList([0xaa,0x08,0x00,0xa8,0x23,0x02,0x22,0x00,0x82,0x4d,0xf5,0x37]), // GET_DATA_RANGE
  Uint8List.fromList([0xaa,0x08,0x00,0xa8,0x23,0x03,0x43,0x01,0xc5,0x4d,0xd6,0x3d]), // GET_ALARM_TIME
  Uint8List.fromList([0xaa,0x08,0x00,0xa8,0x23,0x04,0x16,0x00,0xc7,0xc2,0x52,0x88]), // SEND_HISTORICAL_DATA
];

// ── Batch marker prefix ───────────────────────────────────────────────────────

final Uint8List kBatchMarkerPrefix = Uint8List.fromList([0xaa, 0x1c, 0x00, 0xab, 0x31]);

// ── CRC8 lookup table (from qm0/c.java, table f147401c) ──────────────────────

const List<int> _crc8Table = [
    0,   7,  14,   9,  28,  27,  18,  21,  56,  63,  54,  49,  36,  35,  42,  45,
  112, 119, 126, 121, 108, 107,  98, 101,  72,  79,  70,  65,  84,  83,  90,  93,
  224, 231, 238, 233, 252, 251, 242, 245, 216, 223, 214, 209, 196, 195, 202, 205,
  144, 151, 158, 153, 140, 139, 130, 133, 168, 175, 166, 161, 180, 179, 186, 189,
  199, 192, 201, 206, 219, 220, 213, 210, 255, 248, 241, 246, 227, 228, 237, 234,
  183, 176, 185, 190, 171, 172, 165, 162, 143, 136, 129, 134, 147, 148, 157, 154,
   39,  32,  41,  46,  59,  60,  53,  50,  31,  24,  17,  22,   3,   4,  13,  10,
   87,  80,  89,  94,  75,  76,  69,  66, 111, 104,  97, 102, 115, 116, 125, 122,
  137, 142, 135, 128, 149, 146, 155, 156, 177, 182, 191, 184, 173, 170, 163, 164,
  249, 254, 247, 240, 229, 226, 235, 236, 193, 198, 207, 200, 221, 218, 211, 212,
  105, 110, 103,  96, 117, 114, 123, 124,  81,  86,  95,  88,  77,  74,  67,  68,
   25,  30,  23,  16,   5,   2,  11,  12,  33,  38,  47,  40,  61,  58,  51,  52,
   78,  73,  64,  71,  82,  85,  92,  91, 118, 113, 120, 127, 106, 109, 100,  99,
   62,  57,  48,  55,  34,  37,  44,  43,   6,   1,   8,  15,  26,  29,  20,  19,
  174, 169, 160, 167, 178, 181, 188, 187, 150, 145, 152, 159, 138, 141, 132, 131,
  222, 217, 208, 215, 194, 197, 204, 203, 230, 225, 232, 239, 250, 253, 244, 243,
];

int _crc8(List<int> data) {
  int crc = 0;
  for (final b in data) {
    crc = _crc8Table[(crc ^ b) & 0xFF];
  }
  return crc;
}

// ── CRC32 (standard IEEE 802.3 / Java CRC32 / zlib) ──────────────────────────

const int _crc32Poly = 0xEDB88320;
final List<int> _crc32Table = _buildCrc32Table();

List<int> _buildCrc32Table() {
  final table = List<int>.filled(256, 0);
  for (int i = 0; i < 256; i++) {
    int c = i;
    for (int j = 0; j < 8; j++) {
      c = (c & 1) != 0 ? (_crc32Poly ^ (c >> 1)) : (c >> 1);
    }
    table[i] = c;
  }
  return table;
}

int _crc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = _crc32Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// ── Packet builder ────────────────────────────────────────────────────────────

Uint8List buildPacket(int seq, int cmd, [List<int> payload = const []]) {
  final inner = <int>[0x23, seq & 0xFF, cmd, ...payload];
  final pad = (4 - inner.length % 4) % 4;
  inner.addAll(List.filled(pad, 0));
  final length = inner.length + 4; // +4 for CRC32
  final lenBytes = [length & 0xFF, (length >> 8) & 0xFF];
  final crc8byte = _crc8(lenBytes);
  final crc32 = _crc32(inner);
  return Uint8List.fromList([
    0xAA,
    ...lenBytes,
    crc8byte,
    ...inner,
    crc32 & 0xFF,
    (crc32 >> 8) & 0xFF,
    (crc32 >> 16) & 0xFF,
    (crc32 >> 24) & 0xFF,
  ]);
}

Uint8List buildBatchAck(int counter, Uint8List batchN) {
  final body = <int>[0xaa, 0x10, 0x00, 0x57, 0x23, counter, 0x17, 0x01, ...batchN];
  final inner = body.sublist(4);
  final crc32 = _crc32(inner);
  return Uint8List.fromList([
    ...body,
    crc32 & 0xFF,
    (crc32 >> 8) & 0xFF,
    (crc32 >> 16) & 0xFF,
    (crc32 >> 24) & 0xFF,
  ]);
}

// ── Frame reassembler ─────────────────────────────────────────────────────────

class FrameReassembler {
  final List<int> _buf = [];

  /// Feed incoming BLE notification bytes. Returns a complete frame when one
  /// is assembled, otherwise null.
  Uint8List? feed(List<int> data) {
    if (data.isEmpty) return null;

    if (data[0] == 0xAA) {
      _buf.clear();
    } else if (_buf.isEmpty) {
      return null; // orphan fragment
    }
    _buf.addAll(data);

    if (_buf.length < 4) return null;

    final expectedTotal = 4 + (_buf[1] | (_buf[2] << 8));
    if (_buf.length < expectedTotal) return null;

    final frame = Uint8List.fromList(_buf.sublist(0, expectedTotal));

    // Advance past frame and skip null-byte padding between consecutive records
    final tail = _buf.sublist(expectedTotal);
    _buf.clear();
    final nonZero = tail.indexWhere((b) => b != 0x00);
    if (nonZero > 0) {
      _buf.addAll(tail.sublist(nonZero));
    } else if (nonZero == 0) _buf.addAll(tail);

    return frame;
  }

  void reset() => _buf.clear();
}

// ── Frame decoder ─────────────────────────────────────────────────────────────

WhoopPacket? decodeFrame(Uint8List frame) {
  if (frame.length < 5) return null;
  final view = ByteData.sublistView(frame);
  final pktType = frame[4];

  switch (pktType) {
    case kTypeEvent:
      return _decodeEvent(frame, view);
    case kTypeMetadata:
      return _decodeMetadata(frame);
    case kTypeCmdResponse:
      return _decodeCmdResponse(frame, view);
    case kTypeRealtimeData:
    case kTypeHistoricalData:
    case kTypeRawRealtime:
      return _decodeData(frame, view);
    case kTypeFwLog:
      return _decodeFwLog(frame, view);
    default:
      return UnknownPacket(pktType, frame);
  }
}

WhoopPacket _decodeEvent(Uint8List frame, ByteData view) {
  if (frame.length < 14) return UnknownPacket(kTypeEvent, frame);
  final eventType = view.getUint16(6, Endian.little);
  final tsSec = view.getUint32(8, Endian.little);
  final payload = frame.length > 16 ? frame.sublist(16) : Uint8List(0);

  double? batteryPct;
  double? tempC;
  if (eventType == 3 && payload.length >= 4) {
    final battRaw = ByteData.sublistView(payload).getUint32(0, Endian.little);
    // Protocol: Divide by 10 → percentage (e.g. 850 → 85.0%)
    batteryPct = (battRaw / 10.0).clamp(0.0, 100.0);
    print('[WhoopProtocol] Event BATTERY: battRaw=$battRaw, battPct=$batteryPct%');
  }
  if (eventType == 17 && payload.length >= 2) {
    tempC = ByteData.sublistView(payload).getInt16(0, Endian.little) / 10.0;
    print('[WhoopProtocol] Event TEMPERATURE: tempC=$tempC°C');
  }
  
  // Log all events for debugging
  if (eventType != 3 && eventType != 17) {
    print('[WhoopProtocol] Event received: type=$eventType (${kEventNames[eventType] ?? 'UNKNOWN'})');
  }

  return EventPacket(
    eventType: eventType,
    eventName: kEventNames[eventType] ?? 'UNKNOWN_$eventType',
    timestampSeconds: tsSec,
    payload: payload,
    batteryPct: batteryPct,
    tempC: tempC,
  );
}

WhoopPacket _decodeMetadata(Uint8List frame) {
  final isBatchMarker = frame.length >= kBatchMarkerPrefix.length &&
      _listStartsWith(frame, kBatchMarkerPrefix) &&
      frame.length >= 25;
  if (isBatchMarker) {
    return BatchMarkerPacket(batchN: frame.sublist(17, 25));
  }
  return EndOfSyncPacket();
}

WhoopPacket _decodeCmdResponse(Uint8List frame, ByteData view) {
  if (frame.length < 7) return UnknownPacket(kTypeCmdResponse, frame);
  final cmd = frame[6];
  final payload = frame.sublist(7);

  if (cmd == cmdGetHelloHarvard && payload.length >= 114) {
    return _decodeHelloHarvard(payload);
  }
  if (cmd == cmdGetAdvertisingName) {
    final nameEnd = payload.indexOf(0);
    final name = String.fromCharCodes(nameEnd >= 0 ? payload.sublist(0, nameEnd) : payload);
    return CmdResponsePacket(cmd: cmd, cmdName: 'GET_ADVERTISING_NAME', data: payload, extra: name);
  }
  return CmdResponsePacket(cmd: cmd, cmdName: _cmdName(cmd), data: payload);
}

HelloHarvardPacket _decodeHelloHarvard(Uint8List p) {
  final view = ByteData.sublistView(p);
  final hwHint = p[0];
  final T = hwHint == 4 ? 1 : 0;
  final battRaw = view.getInt32(1, Endian.little);
  // Protocol says: Divide by 10 → percentage (e.g. 850 → 85.0%)
  // But if we're getting huge numbers, try /100 or keep raw if <100
  final battPct = (battRaw / 10.0).clamp(0.0, 100.0);
  final charging = p[5] != 0;
  final rtcSec = view.getUint32(6, Endian.little);
  final serial = p.sublist(14, 23).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  
  // Wrist status at offset 113+T per protocol section 12
  final wristOffset = 113 + T;
  final wristRaw = p.length > wristOffset ? p[wristOffset] : 0;
  final wrist = wristRaw == 1 ? WristStatus.onWrist : wristRaw == 2 ? WristStatus.offWrist : WristStatus.unknown;
  
  print('[WhoopProtocol] HelloHarvard:');
  print('  battery: battRaw=$battRaw (0x${battRaw.toRadixString(16)}) → $battPct%');
  print('  wrist: offset=$wristOffset, raw=$wristRaw → $wrist');
  print('  charging=$charging, hwHint=$hwHint, T=$T, payloadLen=${p.length}');
  print('  payload hex: ${p.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
  
  return HelloHarvardPacket(
    batteryPct: battPct,
    charging: charging,
    rtcSeconds: rtcSec,
    serial: serial,
    wristStatus: wrist,
    errorCode: p.length > 109 + T ? p[109 + T] : 0,
    hrBroadcastEnabled: p.length > 108 + T ? p[108 + T] != 0 : false,
  );
}

WhoopPacket _decodeData(Uint8List frame, ByteData view) {
  if (frame.length < 17) return UnknownPacket(frame[4], frame);
  final pktType  = frame[4];
  final recType  = frame[5];
  final tsSec    = view.getUint32(11, Endian.little);
  final isRealtime = pktType == kTypeRealtimeData || pktType == kTypeRawRealtime;

  print('[WhoopProtocol] Data packet: pktType=0x${pktType.toRadixString(16)}, recType=$recType, frameLen=${frame.length}, isRealtime=$isRealtime');

  if (recType == 10 && frame.length >= 22) {
    // R10 — IMU: HR + accel + gyro
    final hr = frame[21];
    Int16List? ax, ay, az, gx, gy, gz;
    if (frame.length >= 4 + 289) {
      ax = _extractShorts(frame, 4 + 85,  100);
      ay = _extractShorts(frame, 4 + 285, 100);
      az = _extractShorts(frame, 4 + 485, 100);
    }
    if (frame.length >= 4 + 889) {
      gx = _extractShorts(frame, 4 + 688, 100);
      gy = _extractShorts(frame, 4 + 888, 100);
    }
    if (frame.length >= 4 + 1289) {
      gz = _extractShorts(frame, 4 + 1088, 100);
    }
    return R10Packet(
      timestampSeconds: tsSec,
      isRealtime: isRealtime,
      heartRate: hr,
      accelX: ax, accelY: ay, accelZ: az,
      gyroX: gx, gyroY: gy, gyroZ: gz,
    );
  }

  if (recType == 21 && frame.length >= 4 + 22) {
    // R21 — Optical / PPG
    final ledDrive = view.getUint16(4 + 14, Endian.little);
    final sampleCnt = frame[4 + 16];
    Int32List? chA, chB, chC, chF;
    if (frame.length >= 4 + 621) {
      chA = _extractUshorts(frame, 4 + 20,  100);
      chB = _extractUshorts(frame, 4 + 220, 100);
      chC = _extractUshorts(frame, 4 + 420, 100);
    }
    if (frame.length >= 4 + 1233) {
      chF = _extractUshorts(frame, 4 + 1032, 100);
    }
    final opticalDataAvailable = chA != null && chB != null && chC != null;
    if (opticalDataAvailable) {
      print('[WhoopProtocol] R21 OPTICAL LOCKED: ledDrive=$ledDrive, sampleCnt=$sampleCnt, channels=${chF != null ? 4 : 3}');
    } else {
      print('[WhoopProtocol] R21 received but waiting for optical lock (ledDrive=$ledDrive)...');
    }
    return R21Packet(
      timestampSeconds: tsSec,
      isRealtime: isRealtime,
      ledDrive: ledDrive,
      sampleCount: sampleCnt,
      channelA: chA, channelB: chB, channelC: chC, channelF: chF,
    );
  }

  return DataPacket(
    pktType: pktType,
    recordType: recType,
    timestampSeconds: tsSec,
    isRealtime: isRealtime,
    raw: frame,
  );
}

WhoopPacket _decodeFwLog(Uint8List frame, ByteData view) {
  if (frame.length < 18) return UnknownPacket(kTypeFwLog, frame);
  final tsSec = view.getUint32(8, Endian.little);
  final raw = frame.sublist(17);
  final end = raw.indexOf(0);
  final msg = String.fromCharCodes(end >= 0 ? raw.sublist(0, end) : raw);
  return FwLogPacket(timestampSeconds: tsSec, message: msg);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Int16List _extractShorts(Uint8List frame, int offset, int count) {
  final result = Int16List(count);
  final view = ByteData.sublistView(frame, offset, offset + count * 2);
  for (int i = 0; i < count; i++) {
    result[i] = view.getInt16(i * 2, Endian.little);
  }
  return result;
}

Int32List _extractUshorts(Uint8List frame, int offset, int count) {
  final result = Int32List(count);
  final view = ByteData.sublistView(frame, offset, offset + count * 2);
  for (int i = 0; i < count; i++) {
    result[i] = view.getUint16(i * 2, Endian.little);
  }
  return result;
}

bool _listStartsWith(List<int> list, List<int> prefix) {
  if (list.length < prefix.length) return false;
  for (int i = 0; i < prefix.length; i++) {
    if (list[i] != prefix[i]) return false;
  }
  return true;
}

String _cmdName(int cmd) {
  const map = {
    0x03: 'TOGGLE_REALTIME_HR',
    0x0B: 'GET_CLOCK',
    0x16: 'SEND_HISTORICAL_DATA',
    0x22: 'GET_DATA_RANGE',
    0x23: 'GET_HELLO_HARVARD',
    0x3F: 'SEND_R10_R11_REALTIME',
    0x43: 'GET_ALARM_TIME',
    0x4C: 'GET_ADVERTISING_NAME',
    0x4F: 'RUN_HAPTICS_PATTERN',
    0x6C: 'TOGGLE_OPTICAL_MODE',
    0x9A: 'TOGGLE_PERSISTENT_R21',
  };
  return map[cmd] ?? '0x${cmd.toRadixString(16).padLeft(2, '0')}';
}

// ── Event names (from lm0/a.java) ─────────────────────────────────────────────

const Map<int, String> kEventNames = {
  0:   'UNDEFINED',
  1:   'ERROR',
  2:   'CONSOLE_OUTPUT',
  3:   'BATTERY_LEVEL',
  4:   'SYSTEM_CONTROL',
  7:   'CHARGING_ON',
  8:   'CHARGING_OFF',
  9:   'WRIST_ON',
  10:  'WRIST_OFF',
  11:  'BLE_CONNECTION_UP',
  12:  'BLE_CONNECTION_DOWN',
  13:  'RTC_LOST',
  14:  'DOUBLE_TAP',
  15:  'BOOT',
  16:  'SET_RTC',
  17:  'TEMPERATURE_LEVEL',
  18:  'PAIRING_MODE',
  19:  'SERIAL_HEAD_CONNECTED',
  20:  'SERIAL_HEAD_REMOVED',
  21:  'BATTERY_PACK_CONNECTED',
  22:  'BATTERY_PACK_REMOVED',
  23:  'BLE_BONDED',
  24:  'BLE_HR_PROFILE_ENABLED',
  25:  'BLE_HR_PROFILE_DISABLED',
  26:  'TRIM_ALL_DATA',
  27:  'TRIM_ALL_DATA_ENDED',
  28:  'FLASH_INIT_COMPLETE',
  29:  'STRAP_CONDITION_REPORT',
  30:  'BOOT_REPORT',
  31:  'EXIT_VIRGIN_MODE',
  32:  'CAPTOUCH_AUTOTHRESHOLD_ACTION',
  33:  'BLE_REALTIME_HR_ON',
  34:  'BLE_REALTIME_HR_OFF',
  35:  'ACCELEROMETER_RESET',
  36:  'AFE_RESET',
  37:  'SHIP_MODE_ENABLED',
  38:  'SHIP_MODE_DISABLED',
  39:  'SHIP_MODE_BOOT',
  40:  'CH1_SATURATION_DETECTED',
  41:  'CH2_SATURATION_DETECTED',
  42:  'ACCELEROMETER_SATURATION_DETECTED',
  43:  'BLE_SYSTEM_RESET',
  44:  'BLE_SYSTEM_ON',
  45:  'BLE_SYSTEM_INITIALIZED',
  46:  'RAW_DATA_COLLECTION_ON',
  47:  'RAW_DATA_COLLECTION_OFF',
  56:  'STRAP_DRIVEN_ALARM_SET',
  57:  'STRAP_DRIVEN_ALARM_EXECUTED',
  58:  'APP_DRIVEN_ALARM_EXECUTED',
  59:  'STRAP_DRIVEN_ALARM_DISABLED',
  60:  'HAPTICS_FIRED',
  63:  'EXTENDED_BATTERY_INFORMATION',
  96:  'HIGH_FREQ_SYNC_PROMPT',
  97:  'HIGH_FREQ_SYNC_ENABLED',
  98:  'HIGH_FREQ_SYNC_DISABLED',
  100: 'HAPTICS_TERMINATED',
  109: 'BATTERY_PACK_INFO',
};

// ── Packet models (sealed class hierarchy) ────────────────────────────────────

enum WristStatus { onWrist, offWrist, unknown }

sealed class WhoopPacket {
  const WhoopPacket();
}

class EventPacket extends WhoopPacket {
  final int eventType;
  final String eventName;
  final int timestampSeconds;
  final Uint8List payload;
  final double? batteryPct;
  final double? tempC;
  const EventPacket({
    required this.eventType,
    required this.eventName,
    required this.timestampSeconds,
    required this.payload,
    this.batteryPct,
    this.tempC,
  });
}

class BatchMarkerPacket extends WhoopPacket {
  final Uint8List batchN;
  const BatchMarkerPacket({required this.batchN});
}

class EndOfSyncPacket extends WhoopPacket {
  const EndOfSyncPacket();
}

class HelloHarvardPacket extends WhoopPacket {
  final double batteryPct;
  final bool charging;
  final int rtcSeconds;
  final String serial;
  final WristStatus wristStatus;
  final int errorCode;
  final bool hrBroadcastEnabled;
  const HelloHarvardPacket({
    required this.batteryPct,
    required this.charging,
    required this.rtcSeconds,
    required this.serial,
    required this.wristStatus,
    required this.errorCode,
    required this.hrBroadcastEnabled,
  });
}

class CmdResponsePacket extends WhoopPacket {
  final int cmd;
  final String cmdName;
  final Uint8List data;
  final String? extra;
  const CmdResponsePacket({required this.cmd, required this.cmdName, required this.data, this.extra});
}

class R10Packet extends WhoopPacket {
  final int timestampSeconds;
  final bool isRealtime;
  final int heartRate;
  final Int16List? accelX, accelY, accelZ;
  final Int16List? gyroX, gyroY, gyroZ;
  const R10Packet({
    required this.timestampSeconds,
    required this.isRealtime,
    required this.heartRate,
    this.accelX, this.accelY, this.accelZ,
    this.gyroX, this.gyroY, this.gyroZ,
  });
  bool get hasImu => accelX != null;
}

class R21Packet extends WhoopPacket {
  final int timestampSeconds;
  final bool isRealtime;
  final int ledDrive;
  final int sampleCount;
  final Int32List? channelA; // Green 1
  final Int32List? channelB; // Green 2
  final Int32List? channelC; // Infrared
  final Int32List? channelF; // Red (SpO2)
  const R21Packet({
    required this.timestampSeconds,
    required this.isRealtime,
    required this.ledDrive,
    required this.sampleCount,
    this.channelA, this.channelB, this.channelC, this.channelF,
  });
}

class DataPacket extends WhoopPacket {
  final int pktType, recordType, timestampSeconds;
  final bool isRealtime;
  final Uint8List raw;
  const DataPacket({
    required this.pktType, required this.recordType,
    required this.timestampSeconds, required this.isRealtime,
    required this.raw,
  });
}

class FwLogPacket extends WhoopPacket {
  final int timestampSeconds;
  final String message;
  const FwLogPacket({required this.timestampSeconds, required this.message});
}

class UnknownPacket extends WhoopPacket {
  final int typeId;
  final Uint8List raw;
  const UnknownPacket(this.typeId, this.raw);
}
