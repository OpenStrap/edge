// The band's battery voltage, which we received 230x a day and threw away.
//
// Every frame below is a VERBATIM EVENT off a real strap, copied out of
// `band_events.hex` in the real exports, with the value the strap's own
// BATTERY_LEVEL carried in the SAME SECOND as the expectation. That pairing is
// how the charge counter was identified: across the MG export's full discharge,
// counter/percent is 19.208, 19.203, 19.198, 19.194 — constant to 0.07% from
// 99.7% down to 50.9%, which is a straight line through the origin rather than
// a correlation that happens to be high.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

proto.EventInfo _event(String hex) => proto.parseEvent(proto.hexToBytes(hex))!;

Uint8List _body(String hex) => Uint8List.fromList(proto.hexToBytes(hex));

// whoop-mg.db, ts 1786502089. Its paired BATTERY_LEVEL read 99.7% / 4375 mV.
const _mgExt = '30703f00c9db7b6ac2350c000376ff3aff57014c017b0700';
const _mgLevel =
    '306f0300c9db7b6ac235140002e50300001711000000002d1103000700000000';
// Same strap, later, ON the charger: 82.7% / 4335 mV.
const _mgLevelCharging =
    '30680300aebc7c6a5c6f1400023b030000ef10000001001b0203001e00000000';
const _mgChargingOn = '30b707003c8c7b6acc6c0000';

// A gen4 export, ts 1786728427. Paired BATTERY_LEVEL read 54.3% / 3881 mV.
const _gen4Ext = '30893f00eb4f7f6a680d1c0001fefe39fd290f300130002b049a03'
    '2f0602000f0100001a00000000';
const _gen4Level =
    '30880300eb4f7f6a600d1400021f020000290f000000002f0602000f01000000';

void main() {
  group('extendedChargeUnits', () {
    test('rev 3 (gen5/MG) reads the counter at [9]', () {
      // 0x077b = 1915, against the 99.7% the strap reported in the same second.
      expect(LocalDb.extendedChargeUnits(_event(_mgExt).body), 1915);
    });

    test('rev 3 stays linear in state of charge across a full discharge', () {
      // Four real MG bodies and the percentages their paired BATTERY_LEVEL
      // events carried.
      const observed = {
        '0376ff3aff57014c017b0700': 99.7,
        '0348ff0cff3b012901960600': 87.8,
        '03b2ffbaff57014e019c0500': 74.8,
        '03b2ffa6fe4c013e01d10300': 50.9,
      };
      final ratios = [
        for (final e in observed.entries)
          LocalDb.extendedChargeUnits(_body(e.key))! / e.value,
      ];
      expect(ratios.first, closeTo(19.2, 0.05));
      // THE WHOLE CLAIM: one straight line, not four unrelated numbers. If a
      // future firmware moves the field this is what stops it decoding as a
      // plausible-looking counter that means something else.
      for (final r in ratios) {
        expect(r, closeTo(ratios.first, 0.02));
      }
    });

    test('rev 1 (gen4) reads the counter at [11], not at [9]', () {
      // [9] holds 48 on this body. Reading the gen5 offset on a gen4 body is
      // exactly why the offset is chosen by revision byte and never by length.
      expect(LocalDb.extendedChargeUnits(_event(_gen4Ext).body), 1067);
    });

    test('an unknown revision decodes to nothing rather than to a guess', () {
      expect(
        LocalDb.extendedChargeUnits(_body('0976ff3aff57014c017b0700')),
        isNull,
      );
    });

    test('a truncated body decodes to nothing', () {
      expect(LocalDb.extendedChargeUnits(Uint8List.fromList([3, 0, 0])), isNull);
      expect(LocalDb.extendedChargeUnits(Uint8List(0)), isNull);
    });

    test('zero is absence, never a flat pack', () {
      expect(LocalDb.extendedChargeUnits(_body('030000000000000000000000')),
          isNull);
    });
  });

  group('batteryRowFromEvent', () {
    test('BATTERY_LEVEL carries the voltage that had no writer', () {
      final row = LocalDb.batteryRowFromEvent(_event(_mgLevel))!;
      expect(row['source'], 'band_event');
      expect(row['millivolts'], 4375);
      expect(row['battery_pct'], 99.7);
      expect(row['charging'], 0);
      expect(row['charge_units'], isNull);
    });

    test('gen4 BATTERY_LEVEL decodes the same three fields', () {
      final row = LocalDb.batteryRowFromEvent(_event(_gen4Level))!;
      expect(row['millivolts'], 3881);
      expect(row['battery_pct'], 54.3);
      expect(row['charging'], 0);
    });

    test('the extended event lands under its own source, not the same row', () {
      // Both events arrive on the SAME strap second. band_battery is keyed
      // (ts, source), so one shared source would make each overwrite the
      // other's columns — which is why they are split.
      final level = LocalDb.batteryRowFromEvent(_event(_mgLevel))!;
      final ext = LocalDb.batteryRowFromEvent(_event(_mgExt))!;
      expect(level['ts'], ext['ts']);
      expect(level['source'], isNot(ext['source']));
      expect(ext['charge_units'], 1915);
      expect(ext['battery_pct'], isNull);
      expect(ext['millivolts'], isNull);
    });

    test('an event that carries no battery makes no row', () {
      // WRIST_ON, verbatim off the same strap.
      final e = _event('30ac090092bf7c6aa3300000');
      expect(LocalDb.batteryRowFromEvent(e), isNull);
    });
  });

  // The bug was never the decode — it was that nothing carried the number the
  // last four inches into the table the widget reads. These two run the real
  // LocalDb.
  group('the series actually gets written', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    tearDown(() async {
      await LocalDb.close();
    });

    test('insertEvent fills the voltage that batteryHealth reports', () async {
      LocalDb.dbName = 'band_battery_live_test.db';
      await LocalDb.close();
      final db = await LocalDb.instance;
      await db.delete('band_battery');
      await db.delete('band_events');

      // 99.7% / 4375 mV, OFF the charger.
      await LocalDb.insertEvent(3, 1786502089, _mgLevel,
          deviceId: LocalDb.kPrimaryDeviceId);
      await LocalDb.insertEvent(63, 1786502089, _mgExt,
          deviceId: LocalDb.kPrimaryDeviceId);
      await LocalDb.insertEvent(7, 1786510000, _mgChargingOn,
          deviceId: LocalDb.kPrimaryDeviceId);
      // 82.7% / 4335 mV, ON the charger — a real frame off the same strap.
      await LocalDb.insertEvent(3, 1786510510, _mgLevelCharging,
          deviceId: LocalDb.kPrimaryDeviceId);

      final rows = await LocalDb.recentBandBatterySamples();
      expect(rows.where((r) => r['millivolts'] != null), isNotEmpty);
      expect(rows.where((r) => r['charge_units'] == 1915), hasLength(1));

      final h = await LocalDb.batteryHealth();
      // 4335, NOT the higher 4375: a full-charge voltage is the highest
      // reading seen WHILE CHARGING, and an off-charger reading is not one.
      expect(h['full_charge_mv'], 4335);
      expect(h['latest_mv'], 4335);
      expect(h['latest_pct'], 82.7);
      // One CHARGING_ON event went in, so one charge is logged — counted off
      // the event, not off edges in a sampled series.
      expect(h['charge_cycles'], 1);
    });

    test('the upgrade replays history that was already on disk', () async {
      LocalDb.dbName = 'band_battery_backfill_test.db';
      await LocalDb.close();
      var db = await LocalDb.instance;
      await db.delete('band_battery');
      await db.delete('band_events');
      // Exactly the state every existing install is in: the frames are banked,
      // the battery series is empty.
      for (final f in const [
        (3, 1786502089, _mgLevel),
        (63, 1786502089, _mgExt),
      ]) {
        await db.insert('band_events', {
          'hex': f.$3,
          'event_id': f.$1,
          'name': 'x',
          'ts': f.$2,
          'payload_json': '{}',
          'captured_at': 0,
        });
      }
      expect(await LocalDb.recentBandBatterySamples(), isEmpty);

      // Force the ladder to re-run this rung.
      await db.execute('PRAGMA user_version = 44');
      await LocalDb.close();
      db = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNull);

      final rows = await LocalDb.recentBandBatterySamples();
      expect(rows.map((r) => r['millivolts']).whereType<int>(), [4375]);
      expect(rows.map((r) => r['charge_units']).whereType<int>(), [1915]);
    });
  });
}
