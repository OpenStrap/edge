# Research

> **Start here before touching any code.**

This folder contains the output of reverse-engineering the WHOOP Gen4 BLE protocol through passive Bluetooth HCI snoop log analysis.

---

## Contents

| File | Description |
|------|-------------|
| `WHOOP_BLE_PROTOCOL.md` | Complete BLE protocol reference — UUIDs, frame format, CRCs, packet types, data record layouts |
| `whoop.py` | Python analysis script — connects to WHOOP over BLE, decodes frames live, useful for protocol exploration |

---

## How the Research Was Done

1. Enabled HCI snoop logging on an Android phone (`Developer Options → Enable Bluetooth HCI snoop log`)
2. Paired the phone with a personally-owned WHOOP 4.0 and used it normally
3. Pulled the `btsnoop_hci.log` file from the device and loaded it in Wireshark
4. Observed the BLE GATT traffic — characteristic UUIDs, notification payloads, write commands
5. Wrote Python scripts to validate understanding by talking to the real device and comparing output

No proprietary software was analyzed. Everything documented here was derived from observing wireless communications broadcast by a device I own, over a radio frequency, in my own home.

---

## Key Findings

- WHOOP 4.0 uses a custom BLE framing protocol over a proprietary GATT service (`61080001-*`)
- The frame format: `[0xAA][len_lo][len_hi][CRC8(len)][inner][CRC32(inner)]`
- CRC8 uses a custom 256-entry lookup table identified from snoop pattern analysis
- The init sequence is 5 hardcoded packets that must be sent in order to unlock data streaming
- Realtime HR, IMU (accelerometer + gyro), and PPG optical data stream continuously once enabled
- The PPG optical sensor (R21) only activates when the device detects skin contact

---

## Protocol Documentation

See `WHOOP_BLE_PROTOCOL.md` for the complete reference.

The documentation covers:
- BLE service and characteristic UUIDs
- Complete frame format and CRC specification
- All 5 initialization packets (hex-encoded)
- Batch ACK protocol for historical data sync
- R10 (IMU/HR), R11 (companion IMU), R21 (optical/PPG) data record layouts
- Event packet types (battery, temperature, wrist detection, double-tap)
- Command reference for haptic patterns, realtime toggles, optical modes

---

## Usage

The Python script (`whoop.py`) requires:
```bash
pip install bleak
python whoop.py
```

It will scan for nearby WHOOP devices, connect, run the init sequence, and print decoded packets to the terminal. Useful for validating your own understanding of the protocol against what the device actually sends.

---

## Limitations

- Tested exclusively on WHOOP 4.0 (hardware codename: Harvard)
- Battery percentage parsing from the HelloHarvard packet appears device-specific — raw value semantics may differ across firmware versions
- SpO2 (R21 optical) requires the device to detect wrist contact — it will not activate if the strap is loose or held in hand
- HRV is approximated from R-R intervals derived from HR — not the same method WHOOP uses internally

---

## Ethics Note

All research here was conducted on a personally-owned device by passively observing its own Bluetooth transmissions. If you are using this to understand your own device — great. If you are attempting to access someone else's WHOOP data — don't.
