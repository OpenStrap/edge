"""Connect to Whoop 4.0, decode ALL incoming data in real-time."""
import struct
import time
import zlib
import datetime
import objc
import CoreBluetooth
from Foundation import NSObject, NSRunLoop, NSDate, NSData

CBCentralManager = CoreBluetooth.CBCentralManager
CBUUID = CoreBluetooth.CBUUID
CBCharacteristicWriteWithResponse    = 0
CBCharacteristicWriteWithoutResponse = 1

WHOOP_SERVICE_UUID = CBUUID.UUIDWithString_("61080001")

MAX_RETRIES = 9999

CMD_TO_STRAP   = "61080002"
CMD_FROM_STRAP = "61080003"
EVENTS         = "61080004"
DATA           = "61080005"
MEMFAULT       = "61080007"

# 5-packet init sequence (from HCI snoop of official Android app)
INIT_PACKETS = [
    bytes.fromhex("aa0800a823002300ada86a2d"),  # GET_HELLO_HARVARD
    bytes.fromhex("aa0800a823014c00f2b5cdce"),  # GET_ADVERTISING_NAME_HARVARD
    bytes.fromhex("aa0800a823022200824df537"),  # GET_DATA_RANGE
    bytes.fromhex("aa0800a823034301c54dd63d"),  # GET_ALARM_TIME
    bytes.fromhex("aa0800a823041600c7c25288"),  # SEND_HISTORICAL_DATA
]

# CRC8 lookup table identified from HCI snoop pattern analysis, converted to unsigned bytes.
# Used to compute the Gen4 frame header checksum over the 2-byte length field.
_CRC8_TABLE = bytes([
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
])


def _crc8(data: bytes) -> int:
    """CRC8 over the 2-byte length field in the Gen4 frame header."""
    crc = 0
    for b in data:
        crc = _CRC8_TABLE[(crc ^ b) & 0xFF]
    return crc


def whoop_crc(inner: bytes) -> bytes:
    """Standard CRC32 (Java/zlib) over the inner packet content only.
    Verified against all 5 hardcoded INIT packets from HCI snoop."""
    return struct.pack("<I", zlib.crc32(inner) & 0xFFFFFFFF)


def build_packet(seq: int, cmd: int, payload: bytes = b"") -> bytes:
    """
    Build a framed Whoop Gen4 BLE command packet.

    Frame layout (observed from HCI snoop):
      [0]    0xAA           start-of-frame
      [1-2]  uint16 LE      content_size + 4  (content = inner buf; +4 for CRC32)
      [3]    uint8          CRC8 of the 2 length bytes
      [4..]  bytes          inner content: type(0x23) | seq | cmd | payload (4-byte aligned)
      [-4:]  4 bytes        CRC32 (standard zlib) of inner content only (not the frame header)
    """
    inner = bytes([0x23, seq & 0xFF, cmd]) + payload
    pad = (4 - len(inner) % 4) % 4
    inner += bytes(pad)
    length = len(inner) + 4
    len_bytes = struct.pack("<H", length)
    body = bytes([0xAA]) + len_bytes + bytes([_crc8(len_bytes)]) + inner
    return body + whoop_crc(inner)  # CRC32 over inner content only, not the full body


def build_batch_ack(counter: int, batch_n: bytes) -> bytes:
    body = bytes.fromhex("aa10005723") + bytes([counter]) + bytes.fromhex("1701") + batch_n
    return body + whoop_crc(body[4:])  # CRC32 over inner content (skip 4-byte frame header)


def short_uuid(char) -> str:
    return str(char.UUID()).upper()[:8]


# ── Protocol tables ──────────────────────────────────────────────────────────

# EVENT type int values → names (mapped from observed HCI traffic)
EVENT_TYPES = {
    0:   "UNDEFINED",
    1:   "ERROR",
    2:   "CONSOLE_OUTPUT",
    3:   "BATTERY_LEVEL",
    4:   "SYSTEM_CONTROL",
    7:   "CHARGING_ON",
    8:   "CHARGING_OFF",
    9:   "WRIST_ON",
    10:  "WRIST_OFF",
    11:  "BLE_CONNECTION_UP",
    12:  "BLE_CONNECTION_DOWN",
    13:  "RTC_LOST",
    14:  "DOUBLE_TAP",
    15:  "BOOT",
    16:  "SET_RTC",
    17:  "TEMPERATURE_LEVEL",
    18:  "PAIRING_MODE",
    19:  "SERIAL_HEAD_CONNECTED",
    20:  "SERIAL_HEAD_REMOVED",
    21:  "BATTERY_PACK_CONNECTED",
    22:  "BATTERY_PACK_REMOVED",
    23:  "BLE_BONDED",
    24:  "BLE_HR_PROFILE_ENABLED",
    25:  "BLE_HR_PROFILE_DISABLED",
    26:  "TRIM_ALL_DATA",
    27:  "TRIM_ALL_DATA_ENDED",
    28:  "FLASH_INIT_COMPLETE",
    29:  "STRAP_CONDITION_REPORT",
    30:  "BOOT_REPORT",
    31:  "EXIT_VIRGIN_MODE",
    32:  "CAPTOUCH_AUTOTHRESHOLD_ACTION",
    33:  "BLE_REALTIME_HR_ON",
    34:  "BLE_REALTIME_HR_OFF",
    35:  "ACCELEROMETER_RESET",
    36:  "AFE_RESET",
    37:  "SHIP_MODE_ENABLED",
    38:  "SHIP_MODE_DISABLED",
    39:  "SHIP_MODE_BOOT",
    40:  "CH1_SATURATION_DETECTED",
    41:  "CH2_SATURATION_DETECTED",
    42:  "ACCELEROMETER_SATURATION_DETECTED",
    43:  "BLE_SYSTEM_RESET",
    44:  "BLE_SYSTEM_ON",
    45:  "BLE_SYSTEM_INITIALIZED",
    46:  "RAW_DATA_COLLECTION_ON",
    47:  "RAW_DATA_COLLECTION_OFF",
    56:  "STRAP_DRIVEN_ALARM_SET",
    57:  "STRAP_DRIVEN_ALARM_EXECUTED",
    58:  "APP_DRIVEN_ALARM_EXECUTED",
    59:  "STRAP_DRIVEN_ALARM_DISABLED",
    60:  "HAPTICS_FIRED",
    63:  "EXTENDED_BATTERY_INFORMATION",
    96:  "HIGH_FREQ_SYNC_PROMPT",
    97:  "HIGH_FREQ_SYNC_ENABLED",
    98:  "HIGH_FREQ_SYNC_DISABLED",
    100: "HAPTICS_TERMINATED",
    109: "BATTERY_PACK_INFO",
}

# DATA record type byte → name (mapped from observed HCI traffic)
DATA_RECORD_TYPES = {
    7:  "R7",
    9:  "R9",
    10: "R10_IMU",
    11: "R11",
    12: "R12",
    18: "R18",
    20: "R20",
    21: "R21_OPTICAL",
    24: "R24",
}

# Packet type byte → label
PKT_TYPE_NAMES = {
    0x23: "COMMAND",
    0x24: "CMD_RESPONSE",
    0x28: "REALTIME_DATA",
    0x2B: "RAW_REALTIME",
    0x2F: "HISTORICAL_DATA",
    0x30: "EVENT",
    0x31: "METADATA",
    0x32: "FW_LOG",
}


def _ts(sec: int) -> str:
    if sec <= 0:
        return "--:--:--"
    try:
        return datetime.datetime.utcfromtimestamp(sec).strftime("%H:%M:%S UTC")
    except Exception:
        return f"t={sec}"


class Delegate(NSObject):
    @objc.python_method
    def init_manager(self):
        self.peripheral         = None
        self.retries            = 0
        self.connected          = False
        self.cmd_char           = None
        self.pending_services   = 0
        self.notif_confirmed    = 0
        self.notif_expected     = 0
        self.batch_counter      = 5
        self.init_sent          = False
        self._next_init_idx     = 0
        self.haptic_sent        = False
        self._realtime_started  = False
        self.connect_count      = 0
        self.cmd_seq            = 0xA0    # high range to avoid colliding with batch_counter
        self._frag_buf          = bytearray()
        self.manager = CBCentralManager.alloc().initWithDelegate_queue_options_(
            self, None, None
        )
        return self

    def centralManagerDidUpdateState_(self, manager):
        if manager.state() == 5:
            print("Bluetooth on. Checking for already-connected Whoop...")
            connected = manager.retrieveConnectedPeripheralsWithServices_([WHOOP_SERVICE_UUID])
            for p in connected:
                name = p.name() or ""
                if "whoop" in name.lower():
                    print(f"Found already-connected {name}")
                    self.peripheral = p
                    self.peripheral.setDelegate_(self)
                    manager.connectPeripheral_options_(p, None)
                    return
            print("Not already connected — scanning...")
            manager.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(
        self, manager, peripheral, adv_data, rssi
    ):
        name = peripheral.name() or ""
        if "whoop" not in name.lower():
            return
        if self.peripheral is not None:
            return
        print(f"Found {name} @ {rssi} dBm")
        self.peripheral = peripheral
        self.peripheral.setDelegate_(self)
        manager.connectPeripheral_options_(peripheral, None)

    def centralManager_didConnectPeripheral_(self, manager, peripheral):
        self.connected          = True
        self.init_sent          = False
        self.notif_confirmed    = 0
        self.notif_expected     = 0
        self.retries            = 0
        self.connect_count     += 1
        print(f"CONNECTED (#{self.connect_count}). Discovering services...")
        manager.stopScan()
        peripheral.discoverServices_(None)

    def centralManager_didFailToConnectPeripheral_error_(self, manager, peripheral, error):
        self.retries += 1
        if self.retries < MAX_RETRIES:
            print(f"Connect failed ({self.retries}): {error} — retrying...")
            manager.connectPeripheral_options_(peripheral, None)

    def centralManager_didDisconnectPeripheral_error_(self, manager, peripheral, error):
        code = error.code() if error else 0
        print(f"DISCONNECTED (code={code})")
        if self.retries < MAX_RETRIES:
            self.retries           += 1
            self.connected          = False
            self.cmd_char           = None
            self.pending_services   = 0
            self.notif_confirmed    = 0
            self.notif_expected     = 0
            self.init_sent          = False
            self.batch_counter      = 5
            self._next_init_idx     = 0
            self.haptic_sent        = False
            self._realtime_started  = False
            self.cmd_seq            = 0xA0
            self._frag_buf          = bytearray()
            time.sleep(0.3)
            manager.connectPeripheral_options_(peripheral, None)

    def peripheral_didDiscoverServices_(self, peripheral, error):
        if error:
            print(f"Service error: {error}")
            return
        services = peripheral.services()
        self.pending_services = len(services)
        for svc in services:
            peripheral.discoverCharacteristics_forService_(None, svc)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, svc, error):
        if not error:
            for char in svc.characteristics():
                uuid  = short_uuid(char)
                props = char.properties()
                if uuid == CMD_TO_STRAP:
                    self.cmd_char = char
                if props & 0x10:
                    self.notif_expected += 1
                    peripheral.setNotifyValue_forCharacteristic_(True, char)
        self.pending_services -= 1

    @objc.python_method
    def _init_step(self, peripheral, idx: int):
        if idx >= len(INIT_PACKETS):
            print("All init packets acked. Waiting for sync boundary to send haptic...")
            self._next_init_idx = None
            return
        pkt = INIT_PACKETS[idx]
        print(f"  [{idx+1}/5] init 0x{pkt[6]:02x}")
        self._next_init_idx = idx + 1
        self._write(peripheral, pkt)

    @objc.python_method
    def _send_haptic(self, peripheral):
        # Harvard: RUN_HAPTICS_PATTERN=0x4F, patternId=2, loops=0
        pkt_4f = build_packet(self.cmd_seq, 0x4F, bytes([0x02, 0x00, 0x00, 0x00, 0x00]))
        self.cmd_seq += 1
        print(f">> haptic 0x4F  {pkt_4f.hex()}")
        self._write(peripheral, pkt_4f)
        # Maverick: RUN_HAPTIC_PATTERN_MAVERICK=0x13
        pattern = bytes([0x01, 0x2F, 0x98, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        pkt_13 = build_packet(self.cmd_seq, 0x13, pattern)
        self.cmd_seq += 1
        print(f">> haptic 0x13  {pkt_13.hex()}")
        self._write(peripheral, pkt_13)

    @objc.python_method
    def _send_realtime_hr(self, peripheral):
        # TOGGLE_REALTIME_HR = cmd 0x03, payload [0x01] = enable (observed in HCI snoop)
        pkt_hr = build_packet(self.cmd_seq, 0x03, bytes([0x01]))
        self.cmd_seq += 1
        print(f">> TOGGLE_REALTIME_HR on  {pkt_hr.hex()}")
        self._write(peripheral, pkt_hr)
        # SEND_R10_R11_REALTIME = cmd 0x3F, payload [0x01] = enable (observed in HCI snoop)
        pkt_r10 = build_packet(self.cmd_seq, 0x3F, bytes([0x01]))
        self.cmd_seq += 1
        print(f">> SEND_R10_R11_REALTIME on  {pkt_r10.hex()}")
        self._write(peripheral, pkt_r10)
        # TOGGLE_PERSISTENT_R21 = cmd 0x9A, payload [0x01] = enable optical/PPG streaming
        # TOGGLE_PERSISTENT_R21 = cmd 0x9A, payload [0x01] (observed in HCI snoop)
        pkt_r21 = build_packet(self.cmd_seq, 0x9A, bytes([0x01]))
        self.cmd_seq += 1
        print(f">> TOGGLE_PERSISTENT_R21 on  {pkt_r21.hex()}")
        self._write(peripheral, pkt_r21)
        # TOGGLE_OPTICAL_MODE = cmd 0x6C, payload [0x01] = enable optical sensor
        # TOGGLE_OPTICAL_MODE = cmd 0x6C, payload [0x01] (observed in HCI snoop)
        pkt_opt = build_packet(self.cmd_seq, 0x6C, bytes([0x01]))
        self.cmd_seq += 1
        print(f">> TOGGLE_OPTICAL_MODE on  {pkt_opt.hex()}")
        self._write(peripheral, pkt_opt)

    @objc.python_method
    def _write(self, peripheral, data: bytes, with_response: bool = True):
        nsdata = NSData.dataWithBytes_length_(data, len(data))
        wtype = CBCharacteristicWriteWithResponse if with_response else CBCharacteristicWriteWithoutResponse
        peripheral.writeValue_forCharacteristic_type_(nsdata, self.cmd_char, wtype)

    def peripheral_didWriteValueForCharacteristic_error_(self, peripheral, char, error):
        if error:
            print(f"!! WRITE FAILED: {error}")
            return
        idx = getattr(self, "_next_init_idx", None)
        if idx is not None and idx <= len(INIT_PACKETS):
            self._init_step(peripheral, idx)
        else:
            print(f"   write OK (post-init)")

    @objc.python_method
    def _send_init(self, peripheral):
        if self.init_sent or self.cmd_char is None:
            return
        self.init_sent = True
        print(f"All {self.notif_confirmed} notifications ready. Sending init...")
        self._init_step(peripheral, 0)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(
        self, peripheral, char, error
    ):
        if error:
            print(f"Notif error on {short_uuid(char)}: {error}")
            return
        self.notif_confirmed += 1
        if self.notif_confirmed >= self.notif_expected and self.notif_expected > 0:
            self._send_init(peripheral)

    # ── Incoming data ─────────────────────────────────────────────────────────

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, char, error):
        if error or not char.value():
            return
        raw = bytes(char.value())

        # Fragment reassembly: large packets (e.g. R10 = ~1936 bytes) arrive in chunks.
        # Each new frame begins with 0xAA; continuation fragments do not.
        if raw and raw[0] == 0xAA:
            if self._frag_buf:
                print(f"!! dropped incomplete frame ({len(self._frag_buf)} bytes): "
                      f"{bytes(self._frag_buf[:8]).hex()}…")
            self._frag_buf = bytearray(raw)
        else:
            if not self._frag_buf:
                print(f"!! orphan fragment (no active frame): {raw[:8].hex()}…")
                return
            self._frag_buf += raw

        if len(self._frag_buf) < 4:
            return

        expected_total = 4 + struct.unpack_from("<H", self._frag_buf, 1)[0]
        if len(self._frag_buf) < expected_total:
            return  # still accumulating

        frame = bytes(self._frag_buf[:expected_total])
        # Skip any zero-byte padding the device inserts between records
        # (e.g. 4–8 null bytes between consecutive R10 and R11 frames)
        tail = self._frag_buf[expected_total:]
        i = 0
        while i < len(tail) and tail[i] == 0x00:
            i += 1
        self._frag_buf = bytearray(tail[i:])

        self._decode_frame(peripheral, frame)

    @objc.python_method
    def _decode_frame(self, peripheral, frame: bytes):
        if len(frame) < 5:
            print(f"<< [TINY] {frame.hex()}")
            return

        pkt_type = frame[4]

        # Batch sync marker: METADATA packet with specific 5-byte prefix.
        # Device sends these during historical data dump; we must ACK each one.
        if frame[:5] == bytes.fromhex("aa1c00ab31") and len(frame) >= 25:
            batch_n = frame[17:25]
            ack = build_batch_ack(self.batch_counter, batch_n)
            print(f">> batch ack #{self.batch_counter}  (batch_id={batch_n.hex()})")
            self._write(peripheral, ack)
            self.batch_counter += 1
            return

        if pkt_type == 0x30:   # EVENT
            self._decode_event(frame)

        elif pkt_type == 0x31:  # METADATA — end-of-sync, device entering real-time mode
            print(f"<< [METADATA] end-of-sync  {frame.hex()}")
            if not self.haptic_sent:
                self.haptic_sent = True
                self._send_haptic(peripheral)
            if not self._realtime_started:
                self._realtime_started = True
                self._send_realtime_hr(peripheral)

        elif pkt_type == 0x24:  # COMMAND_RESPONSE
            self._decode_cmd_response(frame)

        elif pkt_type in (0x28, 0x2F, 0x2B):  # REALTIME / HISTORICAL / RAW data
            self._decode_data(frame)

        elif pkt_type == 0x32:  # DEBUG / firmware console log
            self._decode_debug(frame)

        else:
            name = PKT_TYPE_NAMES.get(pkt_type, f"0x{pkt_type:02X}")
            print(f"<< [{name}] {frame.hex()}")

    # ── Decoders ──────────────────────────────────────────────────────────────

    @objc.python_method
    def _decode_debug(self, frame: bytes):
        """
        0x32 DEBUG/console packet — firmware log line from the device.
        Observed layout:
          frame[4]    = 0x32  (type)
          frame[5]    = severity / source byte
          frame[6..7] = uint16 LE  (flags?)
          frame[8..11]= Unix timestamp seconds (uint32 LE)
          frame[12..15]= sub-seconds (uint32 LE)
          frame[16]   = flags byte
          frame[17..] = null-terminated ASCII log string
        Example: "7323790: CAPSENSE: Strap returned to prior state"
        """
        if len(frame) < 18:
            print(f"<< [DEBUG] {frame.hex()}")
            return
        ts_sec  = struct.unpack_from("<I", frame, 8)[0]
        ts      = _ts(ts_sec)
        text    = frame[17:].split(b"\x00")[0].decode("ascii", errors="replace")
        print(f"<< [FW LOG] {ts}  {text}")

    @objc.python_method
    def _decode_event(self, frame: bytes):
        """
        EVENT inner content layout (from HCI snoop observation):
          B()[0]    = type byte (0x30)
          B()[1]    = sequence
          B()[2..3] = event type uint16 LE  → frame[6..7]
          B()[4..7] = timestamp seconds     → frame[8..11]
          B()[8..9] = timestamp sub-secs    → frame[12..13]
          B()[12+]  = event-specific payload → frame[16+]
        """
        if len(frame) < 14:
            print(f"<< [EVENT] short: {frame.hex()}")
            return

        ev_type  = struct.unpack_from("<H", frame, 6)[0]
        ts_sec   = struct.unpack_from("<I", frame, 8)[0]
        payload  = frame[16:]

        name = EVENT_TYPES.get(ev_type, f"UNKNOWN_{ev_type}")
        ts   = _ts(ts_sec)
        extra = ""

        if ev_type == 3 and len(payload) >= 4:          # BATTERY_LEVEL
            val = struct.unpack_from("<I", payload)[0]
            extra = f"  battery={val/10.0:.1f}%"
        elif ev_type == 17 and len(payload) >= 2:       # TEMPERATURE_LEVEL
            # Stored as signed short in 0.1°C units (app rounds to 1 decimal place)
            raw_t = struct.unpack_from("<h", payload)[0]
            extra = f"  temp={raw_t/10.0:.1f}°C"
        elif ev_type == 63 and len(payload) >= 4:       # EXTENDED_BATTERY_INFORMATION
            val = struct.unpack_from("<I", payload)[0]
            extra = f"  batt_raw={val}  ({val/10.0:.1f}%)"
        elif ev_type == 109 and len(payload) >= 2:      # BATTERY_PACK_INFO
            extra = f"  pack_info={payload[:4].hex()}"
        elif payload:
            extra = f"  payload={payload.hex()}"

        print(f"<< [EVENT] {name:<35} @ {ts}{extra}")

    @objc.python_method
    def _decode_cmd_response(self, frame: bytes):
        """
        COMMAND_RESPONSE inner content layout:
          frame[4] = 0x24  (type)
          frame[5] = seq
          frame[6] = cmd echo
          frame[7+] = response payload
        """
        if len(frame) < 7:
            print(f"<< [CMD_RESP] short: {frame.hex()}")
            return
        cmd     = frame[6]
        payload = frame[7:]

        if cmd == 0x23:   # GET_HELLO_HARVARD
            self._decode_hello_harvard(payload)
        elif cmd == 0x03: # TOGGLE_REALTIME_HR ack
            print(f"<< [CMD_RESP] TOGGLE_REALTIME_HR ack  data={payload.hex()}")
        elif cmd == 0x3F: # SEND_R10_R11_REALTIME ack
            print(f"<< [CMD_RESP] SEND_R10_R11_REALTIME ack  data={payload.hex()}")
        elif cmd == 0x4C: # GET_ADVERTISING_NAME
            name = payload.rstrip(b"\x00").decode("ascii", errors="replace")
            print(f"<< [CMD_RESP] advertising name = '{name}'")
        elif cmd == 0x16: # SEND_HISTORICAL_DATA ack
            print(f"<< [CMD_RESP] SEND_HISTORICAL_DATA ack  data={payload.hex()}")
        elif cmd == 0x22: # GET_DATA_RANGE
            print(f"<< [CMD_RESP] DATA_RANGE  {payload.hex()}")
        elif cmd == 0x43: # GET_ALARM_TIME
            print(f"<< [CMD_RESP] ALARM_TIME  {payload.hex()}")
        else:
            print(f"<< [CMD_RESP cmd=0x{cmd:02X}]  {payload.hex()}")

    @objc.python_method
    def _decode_hello_harvard(self, payload: bytes):
        """
        HelloHarvard response payload layout (from HCI snoop observation, offsets 0-based):
          [0]       hw_hint byte  (4 = charging-cable revision → adds T=1 offset to some fields)
          [1..4]    battery   int32 LE  / 10 = percent-×10  (e.g. 850 → 85.0%)
          [5]       charging  byte     (non-zero = charging)
          [6..9]    RTC seconds  uint32 LE
          [10..13]  RTC sub-seconds  uint32 LE
          [14..22]  serial number  9 bytes
          [23..46]  device version hash  24 bytes
          [47..76]  strap signature  30 bytes
          [77+T..80+T]  hw_version  4 bytes  (T = hw_hint==4 ? 1 : 0)
          [89+T..]  firmware version region
          [108+T]   HR broadcast enabled  byte
          [109+T]   error code  byte
          [113+T]   wrist status  byte  (1=on wrist, 2=off wrist)
        """
        if len(payload) < 115:
            print(f"<< [HELLO_HARVARD] payload too short ({len(payload)} bytes): {payload.hex()}")
            return

        hw_hint  = payload[0]
        T        = 1 if hw_hint == 4 else 0
        batt_raw = struct.unpack_from("<i", payload, 1)[0]
        batt_pct = batt_raw / 10.0
        charging = payload[5]
        ts_sec   = struct.unpack_from("<I", payload, 6)[0]
        ts_sub   = struct.unpack_from("<I", payload, 10)[0]
        serial   = payload[14:23].hex()
        hw_bytes = payload[77+T:81+T].hex()
        fw_bytes = payload[89+T:97+T].hex()

        hr_bcast    = payload[108+T] if len(payload) > 108+T else None
        error_code  = payload[109+T] if len(payload) > 109+T else None
        wrist_raw   = payload[113+T] if len(payload) > 113+T else None
        wrist_str   = {0: "unknown", 1: "ON_WRIST", 2: "OFF_WRIST"}.get(wrist_raw, f"0x{wrist_raw:02x}") \
                      if wrist_raw is not None else "?"

        ts = _ts(ts_sec)

        print(f"<< [HELLO_HARVARD]")
        print(f"     battery:      {batt_pct:.1f}%")
        print(f"     charging:     {'YES' if charging else 'no'}")
        print(f"     device time:  {ts}")
        print(f"     serial:       {serial}")
        print(f"     hw_hint:      {hw_hint}  (T={T})")
        print(f"     hw_version:   {hw_bytes}")
        print(f"     fw_region:    {fw_bytes}")
        if hr_bcast is not None:
            print(f"     HR broadcast: {'enabled' if hr_bcast else 'disabled'}")
        if error_code is not None:
            print(f"     error_code:   {error_code}")
        if wrist_raw is not None:
            print(f"     wrist:        {wrist_str} (raw={wrist_raw})")

    @objc.python_method
    def _decode_data(self, frame: bytes):
        """
        DATA packet inner content layout (from HCI snoop observation):
          B()[0]    = packet type (0x28 RT / 0x2F HIST / 0x2B RAW)  → frame[4]
          B()[1]    = record type (7/10/11/20/21)                    → frame[5]
          B()[2]    = sequence                                        → frame[6]
          B()[3..6] = j_field uint32                                 → frame[7..10]
          B()[7..10]= timestamp seconds uint32                       → frame[11..14]
          B()[11..12]=timestamp sub-secs uint16                      → frame[15..16]
          B()[13+]  = record data                                    → frame[17+]

        R10 (IMU) offsets (from HCI snoop observation):
          B()[17]        = heart rate  (uint8 bpm)
          B()[85..284]   = accel X     100 × int16 LE
          B()[285..484]  = accel Y     100 × int16 LE
          B()[485..684]  = accel Z     100 × int16 LE
          B()[688..887]  = gyro X      100 × int16 LE
          B()[888..1087] = gyro Y      100 × int16 LE
          B()[1088..1287]= gyro Z      100 × int16 LE

        R21 (optical/PPG) offsets (from HCI snoop observation):
          B()[14..15]    = LED drive level  uint16
          B()[16]        = sample count (channels A/B/C)
          B()[20..219]   = channel A        100 × uint16
          B()[220..419]  = channel B        100 × uint16
          B()[420..619]  = channel C        100 × uint16
          B()[622]       = sample count (channels D/E/F)
          B()[632..831]  = channel D        100 × uint16
          B()[832..1031] = channel E        100 × uint16
          B()[1032..1231]= channel F        100 × uint16
        """
        if len(frame) < 17:
            print(f"<< [DATA] short ({len(frame)} bytes): {frame.hex()}")
            return

        pkt_type = frame[4]
        rec_type = frame[5]
        ts_sec   = struct.unpack_from("<I", frame, 11)[0]
        ts_sub   = struct.unpack_from("<H", frame, 15)[0]

        mode     = "RT"   if pkt_type == 0x28 else ("RAW" if pkt_type == 0x2B else "HIST")
        rec_name = DATA_RECORD_TYPES.get(rec_type, f"R{rec_type}")
        ts       = _ts(ts_sec)

        if rec_type == 10:   # R10 — IMU (accel + gyro + HR)
            hr = frame[21] & 0xFF if len(frame) > 21 else 0   # B()[17] = frame[4+17]
            print(f"<< [{mode}/{rec_name}] {ts}  HR={hr:3d} bpm  ({len(frame)} bytes)")
            # Accel/gyro — only print when full packet is present
            if len(frame) >= 4 + 688:
                ax = struct.unpack_from("<100h", frame, 4 + 85)
                ay = struct.unpack_from("<100h", frame, 4 + 285)
                az = struct.unpack_from("<100h", frame, 4 + 485)
                gx = struct.unpack_from("<100h", frame, 4 + 688)
                gy = struct.unpack_from("<100h", frame, 4 + 888) if len(frame) >= 4 + 1088 else ()
                gz = struct.unpack_from("<100h", frame, 4 + 1088) if len(frame) >= 4 + 1288 else ()
                def _stat(s):
                    if not s:
                        return "n/a"
                    return f"min={min(s):6d}  max={max(s):6d}  avg={sum(s)//len(s):6d}"
                print(f"     accel X (100):  {_stat(ax)}")
                print(f"     accel Y (100):  {_stat(ay)}")
                print(f"     accel Z (100):  {_stat(az)}")
                print(f"     gyro  X (100):  {_stat(gx)}")
                if gy: print(f"     gyro  Y (100):  {_stat(gy)}")
                if gz: print(f"     gyro  Z (100):  {_stat(gz)}")

        elif rec_type == 21:  # R21 — optical / PPG
            if len(frame) >= 4 + 22:
                led_drive  = struct.unpack_from("<H", frame, 4 + 14)[0]
                sample_cnt = frame[4 + 16] & 0xFF
                print(f"<< [{mode}/{rec_name}] {ts}  LED_drive={led_drive}  samples={sample_cnt}  ({len(frame)} bytes)")
                if len(frame) >= 4 + 420 + 200:
                    ch_a = struct.unpack_from("<100H", frame, 4 + 20)
                    ch_b = struct.unpack_from("<100H", frame, 4 + 220)
                    ch_c = struct.unpack_from("<100H", frame, 4 + 420)
                    def _opstat(s):
                        return f"min={min(s):7d}  max={max(s):7d}  avg={sum(s)//len(s):7d}"
                    print(f"     ch_A (green1):  {_opstat(ch_a)}")
                    print(f"     ch_B (green2):  {_opstat(ch_b)}")
                    print(f"     ch_C (IR):      {_opstat(ch_c)}")
                    if len(frame) >= 4 + 1032 + 200:
                        ch_d = struct.unpack_from("<100H", frame, 4 + 632)
                        ch_e = struct.unpack_from("<100H", frame, 4 + 832)
                        ch_f = struct.unpack_from("<100H", frame, 4 + 1032)
                        print(f"     ch_D:           {_opstat(ch_d)}")
                        print(f"     ch_E:           {_opstat(ch_e)}")
                        print(f"     ch_F:           {_opstat(ch_f)}")
            else:
                print(f"<< [{mode}/{rec_name}] {ts}  {len(frame)} bytes")

        else:
            print(f"<< [{mode}/{rec_name}] {ts}  {len(frame)} bytes  raw={frame[17:25].hex()}…")


print("Starting Whoop connection...\n")
delegate = Delegate.alloc().init_manager()

try:
    while True:
        NSRunLoop.currentRunLoop().runMode_beforeDate_(
            "kCFRunLoopDefaultMode",
            NSDate.dateWithTimeIntervalSinceNow_(1.0)
        )
except KeyboardInterrupt:
    print("\nStopped.")
