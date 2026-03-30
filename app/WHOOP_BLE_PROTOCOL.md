# WHOOP Gen4 BLE Protocol — Complete Technical Reference

> Reverse-engineered from live HCI snoop.
> Covers WHOOP 4.0 (hardware codename "Harvard"), Maverick, Goose, and Puffin generations.


---

## Table of Contents

1. [BLE Service & Characteristics](#1-ble-service--characteristics)
2. [Connection & Pairing Flow](#2-connection--pairing-flow)
3. [Frame Format (Gen4 BLE Frame)](#3-frame-format-gen4-ble-frame)
4. [CRC Algorithms](#4-crc-algorithms)
5. [Packet Types](#5-packet-types)
6. [Outgoing Command Packet Construction](#6-outgoing-command-packet-construction)
7. [Complete Command Reference](#7-complete-command-reference)
8. [Connection Init Sequence (5-packet handshake)](#8-connection-init-sequence-5-packet-handshake)
9. [Historical Data Sync & Batch ACK](#9-historical-data-sync--batch-ack)
10. [Incoming Packet Decoders](#10-incoming-packet-decoders)
    - [10.1 EVENT (0x30)](#101-event-packet-0x30)
    - [10.2 METADATA (0x31)](#102-metadata-packet-0x31)
    - [10.3 COMMAND_RESPONSE (0x24)](#103-command_response-packet-0x24)
    - [10.4 DATA packets (0x28 / 0x2F / 0x2B)](#104-data-packets-0x28--0x2f--0x2b)
    - [10.5 FW_LOG / Debug (0x32)](#105-fw_log--debug-packet-0x32)
11. [Data Record Layouts](#11-data-record-layouts)
    - [11.1 R10 — IMU (HR + Accel + Gyro)](#111-r10--imu-hr--accel--gyro)
    - [11.2 R11 — Companion IMU](#112-r11--companion-imu)
    - [11.3 R21 — Optical / PPG](#113-r21--optical--ppg)
    - [11.4 R20 — Extended Optical](#114-r20--extended-optical)
    - [11.5 R7 — Legacy Sensor](#115-r7--legacy-sensor)
12. [HelloHarvard Response Layout](#12-helloharvard-response-layout)
13. [Realtime Streaming Setup](#13-realtime-streaming-setup)
14. [Haptic Commands](#14-haptic-commands)
15. [Fragment Reassembly](#15-fragment-reassembly)
16. [Event Type Reference (All 57 Events)](#16-event-type-reference-all-57-events)
17. [Android Implementation Guide](#17-android-implementation-guide)

---

## 1. BLE Service & Characteristics

### Primary WHOOP Service

| UUID | Description |
|------|-------------|
| `61080001-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | WHOOP primary service |

The device advertises with the short UUID `61080001`. Use this to scan and filter.

### Characteristics

| Short UUID | Full UUID suffix | Direction | Properties | Purpose |
|------------|-----------------|-----------|------------|---------|
| `61080002` | — | **Write** | WRITE, WRITE_NO_RESPONSE | Send commands to strap (**CMD_TO_STRAP**) |
| `61080003` | — | **Read/Notify** | READ, NOTIFY | Command responses from strap (**CMD_FROM_STRAP**) |
| `61080004` | — | **Notify** | NOTIFY | Device events (wrist, battery, temp…) (**EVENTS**) |
| `61080005` | — | **Notify** | NOTIFY | Sensor data records (**DATA**) |
| `61080007` | — | **Notify** | NOTIFY | Memfault crash/diagnostics (**MEMFAULT**) |

> **Subscribe to notifications on all four NOTIFY characteristics before sending any commands.**

---

## 2. Connection & Pairing Flow

The WHOOP uses standard BLE bonding. No custom pairing PIN is needed — the device bonds automatically after the Android system completes BLE pairing.

### State Machine

```
[SCAN for "whoop" in device name]
        │
        ▼
[Connect to peripheral]
        │
        ▼
[Discover Services → Discover Characteristics on each service]
        │
        ▼
[Enable NOTIFY on ALL characteristics with NOTIFY property]
        │   (track expected vs confirmed notifications)
        ▼
[All notifications confirmed?]
        │  YES
        ▼
[Send 5-packet Init Sequence] ← ACK-driven (one at a time)
        │
        ▼
[Receive EVENT 0x30 and METADATA 0x31 packets (historical sync)]
        │   ACK each batch marker with build_batch_ack()
        ▼
[Receive end-of-sync METADATA (0x31, non-batch prefix)]
        │
        ▼
[Send realtime enable commands]
        │  TOGGLE_REALTIME_HR, SEND_R10_R11_REALTIME,
        │  TOGGLE_PERSISTENT_R21, TOGGLE_OPTICAL_MODE
        ▼
[LIVE DATA STREAMING — R10/R21 per second, EVENTs on demand]
```

### Reconnection

On disconnect, reset all state (sequence counter, notification flags, batch counter) and re-connect immediately. The device reconnects within seconds.

---

## 3. Frame Format (Gen4 BLE Frame)

Every packet — both outgoing (app→device) and incoming (device→app) — uses this framing:

```
Byte  0     : 0xAA           Start-of-Frame marker
Bytes 1–2   : uint16 LE      frame_length  =  len(inner_content) + 4
Byte  3     : uint8          CRC8( bytes[1..2] )   — checksum of the 2 length bytes only
Bytes 4..N  : bytes          inner_content          — command/data/event payload
Bytes N+1..N+4 : uint32 LE  CRC32( inner_content ) — standard zlib/Java CRC32
```

`total_frame_bytes = 4 + frame_length`

### Inner Content Layout by Packet Type

**COMMAND (app → device):**
```
inner[0]   = 0x23             packet type = COMMAND
inner[1]   = seq & 0xFF       sequence number (increment per command)
inner[2]   = cmd_byte         command identifier (see §7)
inner[3..] = payload          command-specific data (zero-padded to 4-byte alignment)
```

**CMD_RESPONSE (device → app):**
```
inner[0]   = 0x24             packet type = CMD_RESPONSE
inner[1]   = seq              echoes the seq from the originating command
inner[2]   = cmd_byte         echoes the command byte
inner[3..] = response_data    command-specific response payload
```

**DATA (device → app):**
```
inner[0]   = pkt_type         0x28=REALTIME, 0x2F=HISTORICAL, 0x2B=RAW_REALTIME
inner[1]   = record_type      7/10/11/20/21 (see §11)
inner[2]   = seq              packet sequence
inner[3..6]= j_field          uint32 LE  (internal field)
inner[7..10]= ts_seconds      uint32 LE  Unix epoch seconds
inner[11..12]= ts_subseconds  uint16 LE
inner[13..] = record_bytes    raw sensor record (record-type-specific layout)
```

**EVENT (device → app):**
```
inner[0]   = 0x30             packet type = EVENT
inner[1]   = seq
inner[2..3]= event_type       uint16 LE  (see §16 for all 57 types)
inner[4..7]= ts_seconds       uint32 LE  Unix epoch seconds
inner[8..9]= ts_subseconds    uint16 LE
inner[10..11]= padding
inner[12..] = event_payload   event-specific data (may be empty)
```

**FW_LOG (device → app):**
```
inner[0]   = 0x32             packet type = FW_LOG
inner[1]   = severity/source byte
inner[2..3]= flags            uint16 LE
inner[4..7]= ts_seconds       uint32 LE  Unix epoch seconds
inner[8..11]= ts_subseconds   uint32 LE
inner[12]  = flags byte
inner[13..] = null-terminated ASCII log string
             Format: "{ticks}: {MODULE}: {message}\0"
```

---

## 4. CRC Algorithms

### CRC8 — Frame Header Checksum

Applied to **only the 2 length bytes** (frame[1..2]).
Custom lookup table (extracted from `qm0/c.java`, table id `f147401c`):

```python
CRC8_TABLE = bytes([
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

def crc8(data: bytes) -> int:
    crc = 0
    for b in data:
        crc = CRC8_TABLE[(crc ^ b) & 0xFF]
    return crc
```

### CRC32 — Packet Content Checksum

Standard **Java `java.util.zip.CRC32`** = standard zlib/PKZIP CRC32 (polynomial 0xEDB88320, init=0xFFFFFFFF, xor-out=0xFFFFFFFF).

Applied to **inner_content only** — NOT the frame header (AA + length + CRC8).

```kotlin
// Android / Kotlin
val crc = java.util.zip.CRC32()
crc.update(innerContent)
val crc32Bytes = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
    .putInt(crc.value.toInt()).array()
```

```java
// Java
CRC32 crc = new CRC32();
crc.update(innerContent);
ByteBuffer buf = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN);
buf.putInt((int) crc.getValue());
byte[] crc32Bytes = buf.array();
```

> **Verified against all 5 hardcoded init packets from HCI snoop.**

---

## 5. Packet Types

| Type Byte | Name | Direction | Description |
|-----------|------|-----------|-------------|
| `0x23` | COMMAND | App → Device | Send a command to the strap |
| `0x24` | CMD_RESPONSE | Device → App | Response to a command |
| `0x28` | REALTIME_DATA | Device → App | Live sensor record |
| `0x2B` | RAW_REALTIME | Device → App | Raw unprocessed sensor record |
| `0x2F` | HISTORICAL_DATA | Device → App | Stored/historical sensor record |
| `0x30` | EVENT | Device → App | Device state change event |
| `0x31` | METADATA | Device → App | Sync boundary / batch marker |
| `0x32` | FW_LOG | Device → App | Firmware debug console output |

---

## 6. Outgoing Command Packet Construction

```
function buildPacket(seq, cmdByte, payload):
    inner  = [0x23, seq & 0xFF, cmdByte] + payload
    pad    = (4 - len(inner) % 4) % 4        // 4-byte align
    inner += [0x00] * pad
    length = len(inner) + 4                   // +4 for CRC32
    lenBytes = uint16_LE(length)
    frame  = [0xAA] + lenBytes + [crc8(lenBytes)] + inner + crc32_LE(inner)
    return frame
```

**Sequence number:** Start at any value; increment by 1 per command. The official app uses a high-range starting value (0xA0+) to avoid colliding with the device's own sequence space (which starts near 0x05 for batch ACKs).

**Write type:** Use `WRITE_WITH_RESPONSE` (`BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT`) for all commands to ensure delivery acknowledgment.

---

## 7. Complete Command Reference

Source: `im0/e.java`. The 3rd constructor argument is the **cmd byte** used on the wire.

| Cmd Byte | Hex | Command Name | Payload | Notes |
|----------|-----|--------------|---------|-------|
| 1 | `0x01` | LINK_VALID | — | Link keepalive check |
| 2 | `0x02` | GET_MAX_PROTOCOL_VERSION | — | Query max BLE protocol version |
| 3 | `0x03` | TOGGLE_REALTIME_HR | `[0x01]`=enable, `[0x00]`=disable | Enable live HR streaming |
| 7 | `0x07` | REPORT_VERSION_INFO | — | Request version info |
| 10 | `0x0A` | SET_CLOCK | `[sec_lo, sec_hi, sec_2, sec_3]` uint32 LE | Set RTC time |
| 11 | `0x0B` | GET_CLOCK | — | Query current RTC |
| 14 | `0x0E` | TOGGLE_GENERIC_HR_PROFILE | `[0x01]`/`[0x00]` | BLE Generic HR profile |
| 16 | `0x10` | TOGGLE_R7_DATA_COLLECTION | `[0x01]`/`[0x00]` | Enable R7 data |
| 19 | `0x13` | RUN_HAPTIC_PATTERN_MAVERICK | 12-byte payload (see §14) | Maverick/Gen4 haptic |
| 20 | `0x14` | ABORT_HISTORICAL_TRANSMITS | — | Stop historical dump |
| 22 | `0x16` | SEND_HISTORICAL_DATA | `[0x00]` | Start historical sync |
| 23 | `0x17` | HISTORICAL_DATA_RESULT | — | Historical data complete |
| 25 | `0x19` | FORCE_TRIM | — | Force data trim |
| 26 | `0x1A` | GET_BATTERY_LEVEL | — | Poll battery level |
| 29 | `0x1D` | REBOOT_STRAP | — | **⚠ Reboots device** |
| 32 | `0x20` | POWER_CYCLE_STRAP | — | **⚠ Power cycles device** |
| 33 | `0x21` | SET_READ_POINTER | 4-byte uint32 LE | Seek historical data |
| 34 | `0x22` | GET_DATA_RANGE | — | Query stored data time range |
| 35 | `0x23` | GET_HELLO_HARVARD | `[0x00]` | **Device info (battery, serial, firmware, wrist)** |
| 36 | `0x24` | START_FIRMWARE_LOAD | — | OTA start |
| 37 | `0x25` | LOAD_FIRMWARE_DATA | OTA chunk | OTA data |
| 38 | `0x26` | PROCESS_FIRMWARE_IMAGE | — | OTA apply |
| 39 | `0x27` | SET_LED_DRIVE | 2-byte value | Set optical LED brightness |
| 40 | `0x28` | GET_LED_DRIVE | — | Query LED drive |
| 41 | `0x29` | SET_TIA_GAIN | value | Set optical TIA gain |
| 42 | `0x2A` | GET_TIA_GAIN | — | |
| 43 | `0x2B` | SET_BIAS_OFFSET | value | |
| 44 | `0x2C` | GET_BIAS_OFFSET | — | |
| 45 | `0x2D` | ENTER_BLE_DFU | — | **⚠ Enters DFU mode** |
| 52 | `0x34` | SET_DP_TYPE | value | Data processing type |
| 53 | `0x35` | FORCE_DP_TYPE | value | |
| 63 | `0x3F` | SEND_R10_R11_REALTIME | `[0x01]`/`[0x00]` | **Start/stop IMU realtime** |
| 45 | `0x2D` | ENTER_BLE_DFU | — | |
| 66 | `0x42` | SET_ALARM_TIME | 8-byte timestamp | Set strap-driven alarm |
| 67 | `0x43` | GET_ALARM_TIME | — | Query alarm |
| 68 | `0x44` | RUN_ALARM | — | Fire alarm immediately |
| 69 | `0x45` | DISABLE_ALARM | — | Cancel alarm |
| 76 | `0x4C` | GET_ADVERTISING_NAME_HARVARD | — | Query BT device name |
| 77 | `0x4D` | SET_ADVERTISING_NAME_HARVARD | null-terminated string | Set BT device name |
| 79 | `0x4F` | RUN_HAPTICS_PATTERN | 5-byte payload (see §14) | **Harvard haptic** |
| 80 | `0x50` | GET_ALL_HAPTICS_PATTERN | — | List haptic patterns |
| 81 | `0x51` | START_RAW_DATA | — | Start raw data mode |
| 82 | `0x52` | STOP_RAW_DATA | — | Stop raw data mode |
| 83 | `0x53` | VERIFY_FIRMWARE_IMAGE | — | OTA verify |
| 84 | `0x54` | GET_BODY_LOCATION_AND_STATUS | — | |
| 96 | `0x60` | ENTER_HIGH_FREQ_SYNC | — | High-frequency sync |
| 97 | `0x61` | EXIT_HIGH_FREQ_SYNC | — | |
| 98 | `0x62` | GET_EXTENDED_BATTERY_INFO | — | Extended battery stats |
| 105 | `0x69` | TOGGLE_IMU_MODE_HISTORICAL | `[0x01]`/`[0x00]` | IMU historical mode |
| 106 | `0x6A` | TOGGLE_IMU_MODE | `[0x01]`/`[0x00]` | IMU realtime mode |
| 107 | `0x6B` | ENABLE_OPTICAL_DATA | `[0x01]`/`[0x00]` | |
| 108 | `0x6C` | TOGGLE_OPTICAL_MODE | `[0x01]`/`[0x00]` | **Enable optical sensor** |
| 115 | `0x73` | START_DEVICE_CONFIG_KEY_EXCHANGE | — | |
| 116 | `0x74` | SEND_NEXT_DEVICE_CONFIG | data | |
| 117 | `0x75` | START_FF_KEY_EXCHANGE | — | |
| 118 | `0x76` | SEND_NEXT_FF | data | |
| 119 | `0x77` | SET_FF_VALUE | value | |
| 120 | `0x78` | SET_FF_VALUE (alt) | value | |
| 121 | `0x79` | GET_DEVICE_CONFIG_VALUE | key | |
| 122 | `0x7A` | STOP_HAPTICS | — | Cancel ongoing haptic |
| 123 | `0x7B` | SELECT_WRIST | `[0x00]`=left, `[0x01]`=right | |
| 124 | `0x7C` | TOGGLE_LABRADOR_DATA_GENERATION | `[0x01]`/`[0x00]` | |
| 125 | `0x7D` | TOGGLE_LABRADOR_RAW_SAVE | `[0x01]`/`[0x00]` | |
| 128 | `0x80` | GET_FF_VALUE | key | |
| 131 | `0x83` | SET_RESEARCH_PACKET | data | |
| 132 | `0x84` | GET_RESEARCH_PACKET | — | |
| 139 | `0x8B` | TOGGLE_LABRADOR_FILTERED | `[0x01]`/`[0x00]` | |
| 140 | `0x8C` | SET_ADVERTISING_NAME | string | |
| 141 | `0x8D` | GET_ADVERTISING_NAME | — | |
| 142 | `0x8E` | START_FIRMWARE_LOAD_NEW | — | |
| 143 | `0x8F` | LOAD_FIRMWARE_DATA_NEW | chunk | |
| 144 | `0x90` | PROCESS_FIRMWARE_IMAGE_NEW | — | |
| 145 | `0x91` | GET_HELLO | — | Newer hello variant |
| 151 | `0x97` | GET_BATTERY_PACK_INFO | — | |
| 153 | `0x99` | TOGGLE_PERSISTENT_R20 | `[0x01]`/`[0x00]` | Enable R20 optical stream |
| 154 | `0x9A` | TOGGLE_PERSISTENT_R21 | `[0x01]`/`[0x00]` | **Enable R21 optical/PPG stream** |

---

## 8. Connection Init Sequence (5-packet handshake)

After all BLE notifications are confirmed, send these 5 packets **in order**, one at a time. Wait for the `peripheral_didWriteValueForCharacteristic` callback (write acknowledged) before sending the next.

```
Packet 1: GET_HELLO_HARVARD        aa0800a823002300ada86a2d
Packet 2: GET_ADVERTISING_NAME     aa0800a823014c00f2b5cdce
Packet 3: GET_DATA_RANGE           aa0800a823022200824df537
Packet 4: GET_ALARM_TIME           aa0800a823034301c54dd63d
Packet 5: SEND_HISTORICAL_DATA     aa0800a823041600c7c25288
```

> **Note:** These are hardcoded with seq bytes 0x00–0x04 and the payload for GET_HELLO_HARVARD is `[0x00]`. Confirmed via HCI snoop of the official app.

After packet 5 is sent, the device begins streaming historical data. Do not send any additional commands until the end-of-sync METADATA arrives.

### Response to Packet 1 (GET_HELLO_HARVARD)
The device immediately responds with a CMD_RESPONSE (0x24) containing device info (battery, serial, firmware, wrist status). See §12 for the full layout.

---

## 9. Historical Data Sync & Batch ACK

During the historical dump, the device sends **batch marker** packets. These are METADATA packets (0x31) with a specific 5-byte prefix. Each one **must be ACKed** or the sync stalls.

### Detecting a Batch Marker

A batch marker has this exact 5-byte prefix AND total length ≥ 25 bytes:
```
frame[0..4] == AA 1C 00 AB 31
```

### Extracting batch_n
```
batch_n = frame[17:25]   // 8 bytes
```

### Building the Batch ACK

```python
def build_batch_ack(counter: int, batch_n: bytes) -> bytes:
    # counter starts at 5, increments by 1 per batch
    body = bytes.fromhex("aa10005723") + bytes([counter]) + bytes.fromhex("1701") + batch_n
    inner = body[4:]                    # inner content = everything after the 4-byte frame header
    return body + crc32_LE(inner)
```

### End-of-Sync Signal

When the historical dump is complete, the device sends a METADATA packet (0x31) that does **not** match the batch marker prefix. This signals the device is now in real-time mode. At this point:
1. Optionally fire a haptic (user feedback that sync is done)
2. Send the realtime enable commands (see §13)

---

## 10. Incoming Packet Decoders

All byte offsets below are relative to `frame[0]` (start of the full BLE notification). The 4-byte frame header occupies `frame[0..3]`; inner content starts at `frame[4]`.

### 10.1 EVENT Packet (0x30)

```
frame[4]    = 0x30           packet type
frame[5]    = seq
frame[6..7] = uint16 LE      event_type  (see §16 for all 57 values)
frame[8..11]= uint32 LE      timestamp_seconds  (Unix epoch)
frame[12..13]= uint16 LE     timestamp_subseconds
frame[14..15]= padding
frame[16..]  = event_payload (event-specific, may be 0 bytes)
```

**Parsing event_type:**
```kotlin
val eventType = ByteBuffer.wrap(frame, 6, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF
val tsSeconds = ByteBuffer.wrap(frame, 8, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFFFFFFL
```

**Event-specific payload decoding:**

| Event Type | Int Value | Payload |
|------------|-----------|---------|
| BATTERY_LEVEL | 3 | `uint32 LE / 10` = battery percent (e.g. 850 → 85.0%) |
| TEMPERATURE_LEVEL | 17 | `int16 LE / 10` = skin temperature °C (e.g. 367 → 36.7°C) |
| EXTENDED_BATTERY_INFORMATION | 63 | `uint32 LE` raw battery register |
| BATTERY_PACK_INFO | 109 | 4+ bytes pack state |
| HAPTICS_FIRED | 60 | 4 bytes (pattern id) |
| HAPTICS_TERMINATED | 100 | 4 bytes (reason code) |
| STRAP_CONDITION_REPORT | 29 | multi-byte health report |
| CAPTOUCH_AUTOTHRESHOLD_ACTION | 32 | capacitive touch calibration data |
| All others | — | Empty or unspecified |

### 10.2 METADATA Packet (0x31)

Two kinds:

**Batch sync marker** (must ACK — see §9):
```
frame[0..4] == AA 1C 00 AB 31   (exact match)
frame[17..24]= batch_n           (8 bytes for ACK payload)
```

**End-of-sync marker** (all other 0x31 packets):
- Device is now in real-time mode.
- Send haptic + enable realtime commands.

### 10.3 COMMAND_RESPONSE Packet (0x24)

```
frame[4]   = 0x24      type
frame[5]   = seq       echo
frame[6]   = cmd_byte  echo of the command that triggered this response
frame[7..] = payload   command-specific response data
```

**Specific responses:**

| cmd_byte | Command | Response payload |
|----------|---------|-----------------|
| `0x23` | GET_HELLO_HARVARD | Device info (see §12) |
| `0x4C` | GET_ADVERTISING_NAME_HARVARD | null-terminated ASCII name |
| `0x22` | GET_DATA_RANGE | timestamps of stored data range |
| `0x43` | GET_ALARM_TIME | 8-byte alarm timestamp |
| `0x0B` | GET_CLOCK | 8-byte current time |
| `0x03` | TOGGLE_REALTIME_HR | 5-byte ack status |
| `0x3F` | SEND_R10_R11_REALTIME | 5-byte ack status |
| `0x9A` | TOGGLE_PERSISTENT_R21 | 5-byte ack status |
| `0x6C` | TOGGLE_OPTICAL_MODE | 5-byte ack status |
| `0x4F` | RUN_HAPTICS_PATTERN | 5-byte haptic result status |

### 10.4 DATA Packets (0x28 / 0x2F / 0x2B)

Common header (all data packet types):
```
frame[4]    = packet_type     0x28=REALTIME, 0x2F=HISTORICAL, 0x2B=RAW_REALTIME
frame[5]    = record_type     10/11/20/21/7 (see §11)
frame[6]    = seq
frame[7..10]= j_field         uint32 LE (internal)
frame[11..14]= ts_seconds     uint32 LE Unix epoch
frame[15..16]= ts_subseconds  uint16 LE
frame[17..] = record_data     see §11 for each record type's layout
```

**Record type values:**

| Byte | Name | Size (Gen4) | Contents |
|------|------|-------------|----------|
| 7 | R7 | 1936 bytes | Legacy sensor record |
| 10 | R10 | 1928 bytes | **IMU: HR + Accel + Gyro** |
| 11 | R11 | 1932 bytes | Companion IMU record |
| 20 | R20 | 2140 bytes | Extended optical |
| 21 | R21 | 1244 bytes | **Optical / PPG (6 channels)** |

> **Fragment Reassembly Required:** R10 (1928 bytes inner) and R21 both exceed typical BLE MTU (~244 bytes). Each arrives as multiple consecutive BLE notifications. See §15.

### 10.5 FW_LOG / Debug Packet (0x32)

```
frame[4]    = 0x32
frame[5]    = source/severity byte
frame[6..7] = flags  uint16 LE
frame[8..11]= ts_seconds uint32 LE Unix epoch
frame[12..15]= ts_subseconds uint32 LE
frame[16]   = flags
frame[17..] = null-terminated ASCII:  "{ticks}: {MODULE}: {message}\0"
```

Example: `"7323790: CAPSENSE: Strap returned to prior state"`

These are raw firmware `printf`/log statements. Useful for debugging. They fire during normal operation (CAPSENSE calibration, state changes, etc.).

---

## 11. Data Record Layouts

Record data starts at `frame[17]`. All offsets below are **within the `frame[4..]` buffer** (i.e., add 4 to get absolute frame offset, or equivalently `frame[4 + offset]`).

### 11.1 R10 — IMU (HR + Accel + Gyro)

> Source: `km0/a.java`. Total inner content = 1928 bytes (Gen4).

| Offset in B() | frame[] offset | Type | Field |
|--------------|---------------|------|-------|
| 0 | frame[4] | uint8 | packet_type (0x28/0x2F) |
| 1 | frame[5] | uint8 | record_type = 10 |
| 7..10 | frame[11..14] | uint32 LE | timestamp_seconds (Unix) |
| 11..12 | frame[15..16] | uint16 LE | timestamp_subseconds |
| **17** | **frame[21]** | **uint8** | **Heart Rate (bpm, 0–255)** |
| 85..284 | frame[89..288] | 100 × int16 LE | **Accelerometer X** (100 Hz, 10-bit LSB) |
| 285..484 | frame[289..488] | 100 × int16 LE | **Accelerometer Y** |
| 485..684 | frame[489..688] | 100 × int16 LE | **Accelerometer Z** |
| 688..887 | frame[692..891] | 100 × int16 LE | **Gyroscope X** |
| 888..1087 | frame[892..1091] | 100 × int16 LE | **Gyroscope Y** |
| 1088..1287 | frame[1092..1291] | 100 × int16 LE | **Gyroscope Z** |

Notes:
- **100 samples per packet = 100 Hz effective sample rate**
- Each data packet is sent **once per second** (aligned to UTC second boundaries)
- Accel and Gyro values are raw ADC units; scale factors depend on hardware revision
- Heart rate byte is 0 during the first few seconds after wrist-on until the optical lock is achieved

```kotlin
// Android parsing example
fun parseR10(frame: ByteArray): R10Record {
    val buf = ByteBuffer.wrap(frame).order(ByteOrder.LITTLE_ENDIAN)
    val hr = frame[21].toInt() and 0xFF
    val accelX = ShortArray(100) { buf.getShort(89 + it * 2) }
    val accelY = ShortArray(100) { buf.getShort(289 + it * 2) }
    val accelZ = ShortArray(100) { buf.getShort(489 + it * 2) }
    val gyroX  = ShortArray(100) { buf.getShort(692 + it * 2) }
    val gyroY  = ShortArray(100) { buf.getShort(892 + it * 2) }
    val gyroZ  = ShortArray(100) { buf.getShort(1092 + it * 2) }
    val tsSec  = buf.getInt(11).toLong() and 0xFFFFFFFFL
    return R10Record(hr, tsSec, accelX, accelY, accelZ, gyroX, gyroY, gyroZ)
}
```

### 11.2 R11 — Companion IMU

> Source: `km0/b.java`. Total inner content = 1932 bytes (Gen4).
> R11 does not expose additional field decoders beyond the common data header. It arrives paired with every R10 and contains additional computed or backup sensor data. Layout mirrors R10 but with 4 extra bytes (likely additional computed fields).

Parse the same as R10 (same offsets apply through HR and IMU arrays); the 4 extra bytes appear at the tail.

### 11.3 R21 — Optical / PPG

> Source: `km0/e.java`. Total inner content = 1244 bytes.
> **Requires:** `TOGGLE_PERSISTENT_R21` (0x9A, `[0x01]`) + `TOGGLE_OPTICAL_MODE` (0x6C, `[0x01]`).

All offsets are within the `B()` buffer = `frame[4..]`.

| B() Offset | frame[] offset | Type | Field |
|-----------|---------------|------|-------|
| 14..15 | frame[18..19] | uint16 LE | LED drive level |
| 16 | frame[20] | uint8 | Sample count for channels A/B/C |
| 20..219 | frame[24..223] | 100 × uint16 LE | **Channel A** (Green 1) |
| 220..419 | frame[224..423] | 100 × uint16 LE | **Channel B** (Green 2) |
| 420..619 | frame[424..623] | 100 × uint16 LE | **Channel C** (Infrared) |
| 622 | frame[626] | uint8 | Sample count for channels D/E/F |
| 632..831 | frame[636..835] | 100 × uint16 LE | **Channel D** |
| 832..1031 | frame[836..1035] | 100 × uint16 LE | **Channel E** |
| 1032..1231 | frame[1036..1235] | 100 × uint16 LE | **Channel F** (Red, for SpO2) |

**Channel usage:**
- Channels A/B: Green LEDs — primary PPG for heart rate and HRV computation
- Channel C: Infrared — used for motion artifact rejection and SpO2
- Channel F: Red — used for SpO2 (blood oxygen saturation) in combination with IR
- SpO2 is **computed by the app** from the ratio of Red/IR AC and DC components (standard pulse oximetry math)

```kotlin
fun parseR21(frame: ByteArray): R21Record {
    val buf = ByteBuffer.wrap(frame).order(ByteOrder.LITTLE_ENDIAN)
    val ledDrive  = buf.getShort(18).toInt() and 0xFFFF
    val chA = IntArray(100) { buf.getShort(24 + it * 2).toInt() and 0xFFFF }
    val chB = IntArray(100) { buf.getShort(224 + it * 2).toInt() and 0xFFFF }
    val chC = IntArray(100) { buf.getShort(424 + it * 2).toInt() and 0xFFFF }  // IR
    val chF = IntArray(100) { buf.getShort(1036 + it * 2).toInt() and 0xFFFF } // Red
    return R21Record(ledDrive, chA, chB, chC, chF)
}
```

### 11.4 R20 — Extended Optical

> Source: `km0/d.java`. Total inner content = 2140 bytes.
> **Requires:** `TOGGLE_PERSISTENT_R20` (0x99, `[0x01]`).
> No additional field decoders beyond the common header in the decompiled app version analyzed. Treat as raw optical data buffer.

### 11.5 R7 — Legacy Sensor

> Source: `km0/g.java`. Total inner content = 1936 bytes.
> **Requires:** `TOGGLE_R7_DATA_COLLECTION` (0x10, `[0x01]`).
> Legacy record type. No field decoders exposed in analyzed app version.

---

## 12. HelloHarvard Response Layout

Sent as a CMD_RESPONSE (0x24) with `cmd_echo = 0x23`. The response payload starts at `frame[7]`.

> Source: `ef0/s.java`. All offsets below are from `payload[0]` = `frame[7]`.

| Payload Offset | Type | Field | Notes |
|----------------|------|-------|-------|
| 0 | uint8 | hw_hint | `4` = charging-cable revision (sets T=1 below) |
| 1..4 | int32 LE | battery_raw | Divide by 10 → percentage (e.g. 850 = 85.0%) |
| 5 | uint8 | charging | Non-zero = charging |
| 6..9 | uint32 LE | rtc_seconds | Unix epoch (same as event timestamps) |
| 10..13 | uint32 LE | rtc_subseconds | |
| 14..22 | 9 bytes | serial_number | Raw bytes; display as hex or ASCII |
| 23..46 | 24 bytes | version_hash | Device firmware identifier |
| 47..76 | 30 bytes | strap_signature | |
| 77+T..80+T | 4 bytes | hw_version | Hardware version region |
| 89+T..96+T | 8 bytes | fw_version | Firmware version region |
| 105+T | uint8 | sigproc_major | Signal processing version |
| 106+T | uint8 | sigproc_minor | |
| 107+T | uint8 | sigproc_patch | |
| 108+T | uint8 | hr_broadcast_enabled | Non-zero = generic HR BLE profile enabled |
| 109+T | uint8 | error_code | Device error code (0 = no error) |
| 113+T | uint8 | wrist_status | `1` = ON_WRIST, `2` = OFF_WRIST, `0` = unknown |

> **T = 1** if `payload[0] == 4` (charging-cable hardware), else **T = 0**.

```kotlin
fun parseHelloHarvard(payload: ByteArray): HelloHarvardInfo {
    val buf = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
    val hwHint  = payload[0].toInt() and 0xFF
    val T       = if (hwHint == 4) 1 else 0
    val battPct = buf.getInt(1) / 10.0
    val charging = payload[5].toInt() != 0
    val rtcSec  = buf.getInt(6).toLong() and 0xFFFFFFFFL
    val serial  = payload.slice(14..22).toByteArray()
    val wrist   = when (payload[113 + T].toInt() and 0xFF) {
                      1 -> WristStatus.ON_WRIST
                      2 -> WristStatus.OFF_WRIST
                      else -> WristStatus.UNKNOWN
                  }
    return HelloHarvardInfo(battPct, charging, rtcSec, serial, wrist)
}
```

---

## 13. Realtime Streaming Setup

Send these commands **immediately after** receiving the end-of-sync METADATA packet. All use `WRITE_WITH_RESPONSE`.

```
// 1. Enable live heart rate (1 Hz HR in R10 packets)
buildPacket(seq++, 0x03, byteArrayOf(0x01))   // TOGGLE_REALTIME_HR

// 2. Start R10 + R11 realtime streaming (IMU at 100 Hz, 1 packet/sec)
buildPacket(seq++, 0x3F, byteArrayOf(0x01))   // SEND_R10_R11_REALTIME

// 3. Enable persistent R21 optical/PPG streaming
buildPacket(seq++, 0x9A, byteArrayOf(0x01))   // TOGGLE_PERSISTENT_R21

// 4. Enable optical sensor
buildPacket(seq++, 0x6C, byteArrayOf(0x01))   // TOGGLE_OPTICAL_MODE
```

After these are sent you will receive:
- `EVENT: BLE_REALTIME_HR_ON` confirming HR is live
- `RAW/R10_IMU` packets once per second with HR + 100 accel + 100 gyro samples
- `RAW/R11` packets once per second
- `RAW/R21_OPTICAL` packets with 6 PPG channels (once optical locks)

**To disable streaming on disconnect:**
```
buildPacket(seq++, 0x03, byteArrayOf(0x00))   // HR off
buildPacket(seq++, 0x3F, byteArrayOf(0x00))   // R10/R11 off
buildPacket(seq++, 0x9A, byteArrayOf(0x00))   // R21 off
buildPacket(seq++, 0x6C, byteArrayOf(0x00))   // Optical off
```

---

## 14. Haptic Commands

### Harvard (WHOOP 4.0) — cmd `0x4F`

```
Payload (5 bytes):
  [0] patternId      (2 = notification pattern; range 1–N)
  [1] numberOfLoops  (0 = play once)
  [2] 0x00
  [3] 0x00
  [4] 0x00
```

```kotlin
val hapticHarvard = buildPacket(seq++, 0x4F, byteArrayOf(2, 0, 0, 0, 0))
```

### Maverick / Gen4 — cmd `0x13`

```
Payload (12 bytes):
  [0]     revision    = 0x01
  [1]     effect1     = 0x2F  (47 — notification feel)
  [2]     effect2     = 0x98  (152)
  [3..8]  0x00 × 6   (unused effect slots)
  [9..10] loopCtrl    = 0x0000 uint16 LE
  [11]    overallLoop = 0x01
```

```kotlin
val hapticMaverick = buildPacket(seq++, 0x13,
    byteArrayOf(0x01, 0x2F, 0x98, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))
```

**Best practice:** Send both commands back-to-back. The device picks whichever format it supports.

**Available patterns (cmd 0x4F, patternId):**

| patternId | Use |
|-----------|-----|
| 1 | Short buzz |
| 2 | Notification |
| 3+ | Other patterns (query via `GET_ALL_HAPTICS_PATTERN` 0x50) |

---

## 15. Fragment Reassembly

Large packets (R10 ≈ 1936 bytes total, R21 ≈ 1252 bytes) arrive as multiple BLE `onCharacteristicChanged` callbacks. The device streams them as a continuous byte sequence with null-byte padding between records.

### Reassembly Algorithm

```kotlin
private val fragBuf = ByteArrayOutputStream()

fun onCharacteristicChanged(data: ByteArray) {
    // New frame starts with 0xAA
    if (data.isNotEmpty() && data[0] == 0xAA.toByte()) {
        fragBuf.reset()
    } else if (fragBuf.size() == 0) {
        return  // orphan fragment, no active frame — discard
    }
    fragBuf.write(data)

    val buf = fragBuf.toByteArray()
    if (buf.size < 4) return

    val expectedTotal = 4 + ByteBuffer.wrap(buf, 1, 2)
                               .order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF
    if (buf.size < expectedTotal) return  // still accumulating

    val frame = buf.copyOf(expectedTotal)

    // Skip null-byte padding (device inserts 4–8 zero bytes between consecutive records)
    val tail = buf.copyOfRange(expectedTotal, buf.size)
    val nonZeroIdx = tail.indexOfFirst { it != 0x00.toByte() }
    fragBuf.reset()
    if (nonZeroIdx > 0) fragBuf.write(tail, nonZeroIdx, tail.size - nonZeroIdx)
    else if (nonZeroIdx == 0) fragBuf.write(tail)
    // else all zeros — discard tail

    decodeFrame(frame)
}
```

### BLE MTU

Request a large MTU at connection time to reduce the number of fragments:
```kotlin
gatt.requestMtu(512)   // 512 is the BLE maximum; typically negotiates to 244–517
```
With MTU 244: R10 (1936 bytes) = ~8 fragments. With MTU 512: ~4 fragments.

---

## 16. Event Type Reference (All 57 Events)

Source: `lm0/a.java`. The **Int Value** is what appears in `frame[6..7]` (uint16 LE).

| Int Value | Name | When it fires | Payload |
|-----------|------|--------------|---------|
| 0 | UNDEFINED | — | — |
| 1 | ERROR | Device error condition | error code bytes |
| 2 | CONSOLE_OUTPUT | Debug log | ASCII string |
| 3 | BATTERY_LEVEL | Battery state changes | `uint32 / 10` = percent |
| 4 | SYSTEM_CONTROL | System state change | — |
| 7 | CHARGING_ON | Charger plugged in | — |
| 8 | CHARGING_OFF | Charger unplugged | — |
| 9 | WRIST_ON | Device detected on wrist | — |
| 10 | WRIST_OFF | Device removed from wrist | — |
| 11 | BLE_CONNECTION_UP | BLE link established | — |
| 12 | BLE_CONNECTION_DOWN | BLE link dropped | — |
| 13 | RTC_LOST | Real-time clock lost power | — |
| 14 | DOUBLE_TAP | User double-tapped device | — |
| 15 | BOOT | Device booted | — |
| 16 | SET_RTC | Clock was set | new timestamp |
| 17 | TEMPERATURE_LEVEL | Skin temp reading | `int16 / 10` = °C |
| 18 | PAIRING_MODE | Device entered pairing mode | — |
| 19 | SERIAL_HEAD_CONNECTED | Charging head connected | — |
| 20 | SERIAL_HEAD_REMOVED | Charging head removed | — |
| 21 | BATTERY_PACK_CONNECTED | Battery pack attached | — |
| 22 | BATTERY_PACK_REMOVED | Battery pack removed | — |
| 23 | BLE_BONDED | New BLE bond created | — |
| 24 | BLE_HR_PROFILE_ENABLED | Generic HR BLE profile on | — |
| 25 | BLE_HR_PROFILE_DISABLED | Generic HR BLE profile off | — |
| 26 | TRIM_ALL_DATA | Data erase started | — |
| 27 | TRIM_ALL_DATA_ENDED | Data erase completed | — |
| 28 | FLASH_INIT_COMPLETE | Flash storage initialized | — |
| 29 | STRAP_CONDITION_REPORT | Periodic health report | multi-byte report |
| 30 | BOOT_REPORT | Boot diagnostics | boot flags |
| 31 | EXIT_VIRGIN_MODE | First-use setup completed | — |
| 32 | CAPTOUCH_AUTOTHRESHOLD_ACTION | Capacitive touch calibration | calibration data |
| 33 | BLE_REALTIME_HR_ON | Realtime HR streaming enabled | — |
| 34 | BLE_REALTIME_HR_OFF | Realtime HR streaming disabled | — |
| 35 | ACCELEROMETER_RESET | Accelerometer hardware reset | — |
| 36 | AFE_RESET | Analog front-end reset | — |
| 37 | SHIP_MODE_ENABLED | Low-power ship mode on | — |
| 38 | SHIP_MODE_DISABLED | Ship mode exited | — |
| 39 | SHIP_MODE_BOOT | Booted from ship mode | — |
| 40 | CH1_SATURATION_DETECTED | Optical channel 1 saturated | — |
| 41 | CH2_SATURATION_DETECTED | Optical channel 2 saturated | — |
| 42 | ACCELEROMETER_SATURATION_DETECTED | Accel ADC clipped | — |
| 43 | BLE_SYSTEM_RESET | BLE subsystem reset | — |
| 44 | BLE_SYSTEM_ON | BLE system powered | — |
| 45 | BLE_SYSTEM_INITIALIZED | BLE stack ready | — |
| 46 | RAW_DATA_COLLECTION_ON | Raw data mode started | — |
| 47 | RAW_DATA_COLLECTION_OFF | Raw data mode stopped | — |
| 56 | STRAP_DRIVEN_ALARM_SET | Alarm programmed | alarm data |
| 57 | STRAP_DRIVEN_ALARM_EXECUTED | Alarm fired | — |
| 58 | APP_DRIVEN_ALARM_EXECUTED | App alarm fired | — |
| 59 | STRAP_DRIVEN_ALARM_DISABLED | Alarm cancelled | — |
| 60 | HAPTICS_FIRED | Haptic pattern started | 4 bytes (pattern id) |
| 63 | EXTENDED_BATTERY_INFORMATION | Extended battery data | `uint32` raw register |
| 96 | HIGH_FREQ_SYNC_PROMPT | Device requesting high-freq sync | — |
| 97 | HIGH_FREQ_SYNC_ENABLED | High-freq sync started | — |
| 98 | HIGH_FREQ_SYNC_DISABLED | High-freq sync ended | — |
| 100 | HAPTICS_TERMINATED | Haptic pattern completed/stopped | reason byte |
| 109 | BATTERY_PACK_INFO | Battery pack status | pack state bytes |

> Values 5, 6, 48–55, 61–62, 64–95, 99, 101–108 are unassigned in this firmware version.

---

## 17. Android Implementation Guide

### Minimum Required Permissions

```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<!-- For API < 31 -->
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

### Recommended Architecture

```
WhoopBleService (foreground Service)
  └── WhoopGattCallback (BluetoothGattCallback)
        ├── onConnectionStateChange → trigger service discovery
        ├── onServicesDiscovered    → find characteristics, enable notifications
        ├── onDescriptorWrite       → count confirmed subscriptions, trigger init
        ├── onCharacteristicWrite   → ack-driven: send next init packet
        └── onCharacteristicChanged → reassemble + decode → emit to ViewModel

WhoopDecoder (pure Kotlin/Java, no Android deps)
  ├── buildPacket(seq, cmd, payload) → ByteArray
  ├── buildBatchAck(counter, batchN) → ByteArray
  ├── reassemble(data: ByteArray) → Frame?
  ├── decodeFrame(frame: ByteArray) → WhoopPacket (sealed class)
  │     ├── EventPacket(type, timestamp, payload)
  │     ├── DataPacket(recordType, timestamp, data)
  │     │     ├── R10Record(hr, accelX, accelY, accelZ, gyroX, gyroY, gyroZ)
  │     │     └── R21Record(ledDrive, chA, chB, chC, chF)
  │     ├── HelloHarvardResponse(battery, charging, serial, wristStatus, ...)
  │     └── FirmwareLog(timestamp, message)
  └── ...

WhoopViewModel
  └── StateFlow<WhoopState>  ← consumed by UI
        ├── heartRate: Int
        ├── wristOn: Boolean
        ├── batteryPct: Double
        ├── charging: Boolean
        ├── skinTempC: Double
        ├── accel: Triple<ShortArray, ShortArray, ShortArray>
        ├── gyro: Triple<ShortArray, ShortArray, ShortArray>
        └── ppg: R21Record?
```

### Connection Code Skeleton

```kotlin
class WhoopGattCallback(private val decoder: WhoopDecoder) : BluetoothGattCallback() {
    private val CMD_TO_STRAP   = UUID.fromString("00061080-0002-0000-0000-000000000000") // short: 61080002
    private val CMD_FROM_STRAP = UUID.fromString("00061080-0003-0000-0000-000000000000")
    private val EVENTS_UUID    = UUID.fromString("00061080-0004-0000-0000-000000000000")
    private val DATA_UUID      = UUID.fromString("00061080-0005-0000-0000-000000000000")
    private val CCCD_UUID      = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private var cmdChar: BluetoothGattCharacteristic? = null
    private var notifsExpected = 0
    private var notifsConfirmed = 0
    private var initIdx = 0
    private var seq = 0xA0
    private var batchCounter = 5
    private var realtimeStarted = false

    override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
        val service = gatt.services.find { it.uuid.toString().startsWith("00061080-0001") }
            ?: return
        cmdChar = service.getCharacteristic(CMD_TO_STRAP)
        service.characteristics.forEach { char ->
            if (char.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                notifsExpected++
                val descriptor = char.getDescriptor(CCCD_UUID)
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.setCharacteristicNotification(char, true)
                gatt.writeDescriptor(descriptor)
            }
        }
    }

    override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
        notifsConfirmed++
        if (notifsConfirmed >= notifsExpected) sendInitPacket(gatt, 0)
    }

    private fun sendInitPacket(gatt: BluetoothGatt, idx: Int) {
        if (idx >= INIT_PACKETS.size) return
        val char = cmdChar ?: return
        char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        char.value = INIT_PACKETS[idx]
        gatt.writeCharacteristic(char)
        initIdx = idx + 1
    }

    override fun onCharacteristicWrite(gatt: BluetoothGatt, char: BluetoothGattCharacteristic, status: Int) {
        if (initIdx < INIT_PACKETS.size) sendInitPacket(gatt, initIdx)
    }

    override fun onCharacteristicChanged(gatt: BluetoothGatt, char: BluetoothGattCharacteristic) {
        val frame = decoder.reassemble(char.value) ?: return
        val packet = decoder.decodeFrame(frame)

        when (packet) {
            is WhoopPacket.BatchMarker -> sendBatchAck(gatt, packet.batchN)
            is WhoopPacket.EndOfSync   -> if (!realtimeStarted) { realtimeStarted = true; enableRealtime(gatt) }
            else -> viewModel.onPacket(packet)
        }
    }

    private fun sendBatchAck(gatt: BluetoothGatt, batchN: ByteArray) {
        write(gatt, decoder.buildBatchAck(batchCounter++, batchN))
    }

    private fun enableRealtime(gatt: BluetoothGatt) {
        write(gatt, decoder.buildPacket(seq++, 0x03, byteArrayOf(1)))  // HR on
        write(gatt, decoder.buildPacket(seq++, 0x3F, byteArrayOf(1)))  // R10/R11 on
        write(gatt, decoder.buildPacket(seq++, 0x9A, byteArrayOf(1)))  // R21 on
        write(gatt, decoder.buildPacket(seq++, 0x6C, byteArrayOf(1)))  // optical on
    }

    private fun write(gatt: BluetoothGatt, data: ByteArray) {
        val char = cmdChar ?: return
        char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        char.value = data
        gatt.writeCharacteristic(char)
    }
}
```

### UUID Note

WHOOP uses **16-bit short UUIDs** (`61080001` etc.) embedded in the standard 128-bit BLE base UUID format. The correct full UUID pattern is:

```
0000XXXX-0000-1000-8000-00805f9b34fb
```
where XXXX = `6108000Y`. However, the device advertises with the 16-bit form. Use the short UUID string `"61080001"` for scanning, and construct the full UUID for characteristic access per your BLE stack's requirements.

---

## Summary: What WHOOP Streams (Complete List)

| Sensor | Raw Data | Rate | Enable Command |
|--------|----------|------|----------------|
| Heart Rate | 1 byte, 0–255 bpm | 1 Hz | `0x03 [01]` |
| Accelerometer X/Y/Z | 100 int16 samples per axis | 100 Hz | `0x3F [01]` |
| Gyroscope X/Y/Z | 100 int16 samples per axis | 100 Hz | `0x3F [01]` |
| PPG Green 1 (ch A) | 100 uint16 samples | 100 Hz | `0x9A + 0x6C [01]` |
| PPG Green 2 (ch B) | 100 uint16 samples | 100 Hz | `0x9A + 0x6C [01]` |
| PPG Infrared (ch C) | 100 uint16 samples | 100 Hz | `0x9A + 0x6C [01]` |
| PPG Red/SpO2 (ch F) | 100 uint16 samples | 100 Hz | `0x9A + 0x6C [01]` |
| Skin Temperature | int16 event / 10 = °C | On-change | automatic |
| Battery % | uint32 event / 10 = % | On-change | automatic |
| Charging state | EVENT CHARGING_ON/OFF | On-change | automatic |
| Wrist detection | EVENT WRIST_ON/OFF | On-change | automatic |
| Double tap | EVENT DOUBLE_TAP | On gesture | automatic |
| Firmware debug log | ASCII string | Continuous | automatic |

**Not raw sensor data (computed by app):**
- HRV (rMSSD) — computed from R-R intervals in PPG/R10
- SpO2 — computed from Red/IR ratio in R21 channels C+F
- Respiration rate — computed from accelerometer + optical
- Strain score — computed from HR, HRV, motion over time
- Recovery score — computed from overnight HRV, resting HR, sleep
- Sleep stages — computed from accel + HR + HRV patterns
- Blood pressure — **NOT measured by WHOOP (no BP sensor)**
