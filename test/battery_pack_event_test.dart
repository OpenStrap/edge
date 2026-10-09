// The WHOOP 5.0 battery pack's own charge, which the strap relays in
// BATTERY_PACK_INFO(109) and which we stored as an empty `EVENT_109` row and
// never read.
//
// The 109 frame below is off a real strap with a pack attached. Only the pack's
// identity is replaced — its BT address (body 1..6) by 11:22:33:44:55:66 and the
// digits of its serial (body 7..22) by zeros; every other byte, the level at
// body 23..24 included, is verbatim. That evening the pack's 109s fell
// 946 → 15 (tenths of a percent) over three hours while the strap's own
// BATTERY_LEVEL rose 0.4% → 96.3% beside them, then BATTERY_PACK_REMOVED(22).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ts 1788811885, pack at 94.6%.
const _packInfo = '30076d006d1a9f6a0a371c0001112233445566574242354150303030'
    '30303030000000b203010c00';
// ts 1788828240.
const _packRemoved = '3012160050559f6ae11a0000';

/// [hex] restamped to [ts], so the engine's live-reading gate sees it as live.
Uint8List _at(String hex, int ts) {
  final b = Uint8List.fromList(hexToBytes(hex));
  b.buffer.asByteData().setUint32(4, ts, Endian.little);
  return b;
}

/// What `decodeFrame` hands the engine for an event, for a gen5 link.
Decoded _decoded(Uint8List inner) {
  final e = parseEvent(inner, profile: BandProfile.gen5)!;
  return Decoded('event', {
    ...e.decoded,
    'event': e.name,
    'event_id': e.eventId,
    'ts_epoch': e.tsEpoch,
  });
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the engine carries the pack level to DeviceState', () {
    BleEngine newEngine() =>
        BleEngine(onRecord: (sample, raw) async {}, onState: (_) {});

    test('a live 109 sets the pack charge in percent', () {
      final engine = newEngine();
      engine.debugAbsorbDecoded(_decoded(_at(_packInfo, _now())));
      expect(engine.state.batteryPackPct, 94.6);
    });

    test('a replayed 109 is the charge hours ago and is not shown', () {
      final engine = newEngine();
      engine.debugAbsorbDecoded(_decoded(hexToBytes(_packInfo)));
      expect(engine.state.batteryPackPct, isNull);
    });

    test('a removal newer than the reading clears it', () {
      final engine = newEngine();
      final t = _now();
      engine.debugAbsorbDecoded(_decoded(_at(_packInfo, t - 60)));
      engine.debugAbsorbDecoded(_decoded(_at(_packRemoved, t)));
      expect(engine.state.batteryPackPct, isNull);
    });

    test('a removal older than the reading is the past and is ignored', () {
      // Replayed from before the pack went back on: clearing on it would hide
      // a pack that is sitting on the band right now.
      final engine = newEngine();
      final t = _now();
      engine.debugAbsorbDecoded(_decoded(_at(_packInfo, t)));
      engine.debugAbsorbDecoded(_decoded(_at(_packRemoved, t - 60)));
      expect(engine.state.batteryPackPct, 94.6);
    });

    test('a reading older than a removal does not bring the pack back', () {
      final engine = newEngine();
      final t = _now();
      engine.debugAbsorbDecoded(_decoded(_at(_packRemoved, t)));
      engine.debugAbsorbDecoded(_decoded(_at(_packInfo, t - 60)));
      expect(engine.state.batteryPackPct, isNull);
    });

    test('DeviceState.reset forgets it', () {
      final engine = newEngine();
      engine.debugAbsorbDecoded(_decoded(_at(_packInfo, _now())));
      engine.state.reset();
      expect(engine.state.batteryPackPct, isNull);
    });

    test('the link leaving listening forgets it', () {
      final engine = newEngine();
      engine.debugAbsorbDecoded(_decoded(_at(_packInfo, _now())));
      expect(engine.state.batteryPackPct, 94.6);
      engine.markReconnecting();
      expect(engine.state.batteryPackPct, isNull);
    });

    test('a raw level past 100% is dropped, not clamped', () {
      final engine = newEngine();
      final b = _at(_packInfo, _now());
      // body 23..24 sits at inner 35..36.
      b.buffer.asByteData().setUint16(35, 1001, Endian.little);
      engine.debugAbsorbDecoded(_decoded(b));
      expect(engine.state.batteryPackPct, isNull);
    });
  });

  group('a stored event is decoded for the band it came off', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    tearDown(() async {
      await LocalDb.close();
    });

    Future<Map<String, Object?>> stored(BandProfile profile) async {
      final db = await LocalDb.instance;
      await db.delete('band_events');
      await LocalDb.insertEvent(109, 1788811885, _packInfo,
          deviceId: LocalDb.kPrimaryDeviceId, profile: profile);
      return (await db.query('band_events')).single;
    }

    test('gen5: BATTERY_PACK_INFO with its level', () async {
      LocalDb.dbName = 'battery_pack_event_test.db';
      await LocalDb.close();
      final row = await stored(BandProfile.gen5);
      expect(row['name'], 'BATTERY_PACK_INFO');
      final payload = jsonDecode(row['payload_json'] as String) as Map;
      expect(payload['pack_battery_raw'], 946);
      expect(payload['pack_address'], '11:22:33:44:55:66');
    });

    test('gen4: the id is not decoded under a meaning gen4 never had',
        () async {
      LocalDb.dbName = 'battery_pack_event_test.db';
      await LocalDb.close();
      final row = await stored(BandProfile.gen4);
      expect(row['name'], 'EVENT_109');
      expect(row['payload_json'], '{}');
    });

    test('a re-sent gen5 frame repairs the row stored undecoded', () async {
      LocalDb.dbName = 'battery_pack_event_test.db';
      await LocalDb.close();
      await stored(BandProfile.gen4); // the row as written before the fix
      await LocalDb.insertEvent(109, 1788811885, _packInfo,
          deviceId: LocalDb.kPrimaryDeviceId, profile: BandProfile.gen5);
      final db = await LocalDb.instance;
      final row = (await db.query('band_events')).single;
      expect(row['name'], 'BATTERY_PACK_INFO');
      final payload = jsonDecode(row['payload_json'] as String) as Map;
      expect(payload['pack_battery_raw'], 946);
    });
  });
}
