// Band-state night END (gen5/MG): when the band reports its own LAST SLEEP
// second inside our auto window and stays awake afterwards, analytics ends the
// night there (`SleepSegmentation.bandOffsetTrimSec`). These pin the EDGE
// wiring of that rule end to end:
//   (a) the trim reaches the day `calendarDays` builds (AUTO path only);
//   (b) the day payload carries `sleep.band_offset_trim_sec` (null when absent);
//   (c) which day owns a midnight-crossing night is decided on the UNTRIMMED
//       end — the band moves the wake time, never the night's day;
//   (d) the trimmed-off lie-in cannot be reclaimed as a nap, through the
//       production handoff (`_DayBlocksInput.napExcludeEndSec`).
//
// Fixed local `DateTime(...)` literals, never `DateTime.now()`.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';

// Band envelope codes (analytics band_offset.dart).
const _wake = 0;
const _sleep = 2;
const _up = 3;

typedef _Sec = ({int hr, bool still, int band});

int _local(int y, int mo, int d, [int h = 0, int mi = 0]) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

/// A 1 Hz substrate from [start] for [n] seconds; [at] describes each second.
/// Still = a constant gravity vector (a genuine van Hees immobile block);
/// moving = a 10°/s RAMP (an alternation would be erased by the mask's 5-s
/// rolling median — see substrate_accel_absence_test). [withBand] false gives
/// the identical substrate with every band state ABSENT (-1).
Substrate _build(int start, int n, _Sec Function(int t) at,
    {bool withBand = true}) {
  final ts = <int>[], hr = <int>[], band = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  for (var i = 0; i < n; i++) {
    final t = start + i;
    final s = at(t);
    ts.add(t);
    hr.add(s.hr);
    band.add(withBand ? s.band : -1);
    if (s.still) {
      ax.add(0.0);
      ay.add(0.0);
      az.add(1.0);
    } else {
      final rad = (i % 9) * 10.0 * math.pi / 180.0;
      ax.add(math.cos(rad));
      ay.add(0.0);
      az.add(math.sin(rad));
    }
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: const [],
    rrMs: const [],
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    bandSleepState: band,
  );
}

int _offSec(PhysioDay d) => d.sleep.window!.offsetMs! ~/ 1000;

// ── (a)/(b) fixture: the `night()` shape of substrate_accel_absence_test ──
// 22:00 → 08:00 local, asleep (still, HR 50) 23:00 → 07:00. The band says
// SLEEP 23:00 → 06:30 and UP from 06:30: the last half hour was a lie-in.
final _nightStart = _local(2025, 6, 15, 22);
final _bandWake = _local(2025, 6, 16, 6, 30); // band last SLEEP + 1
const _nightLen = 10 * 3600;

_Sec _nightAt(int t) {
  final i = t - _nightStart;
  final asleep = i > 3600 && i < 9 * 3600;
  final band = i < 3600 ? _wake : (t < _bandWake ? _sleep : _up);
  return (hr: asleep ? 50 : 70, still: asleep, band: band);
}

// ── (d) fixture: post-midnight onset, a lie-in, then a still hour ─────────
// 00:00 awake → 01:00 asleep (band SLEEP) → 07:10 a 20-min walk (band UP, real
// movement so van Hees breaks the bout) → 07:30 still, HR well under 0.95× the
// awake baseline (band UP) → 08:30 activity until 14:00. The nocturnal
// detector bridges the walk (gap < 60 min), so the untrimmed night runs to
// ~08:30; the band ends it at 07:10.
final _lieDay = _local(2025, 6, 16);
final _lieTrimmed = _local(2025, 6, 16, 7, 10);
const _lieLen = 14 * 3600;

_Sec _lieAt(int t) {
  final s = t - _lieDay;
  if (s < 3600) return (hr: 78, still: false, band: _wake);
  if (s < 7 * 3600 + 600) return (hr: 50, still: true, band: _sleep);
  if (s < 7 * 3600 + 1800) return (hr: 90, still: false, band: _up);
  if (s < 8 * 3600 + 1800) return (hr: 56, still: true, band: _up);
  return (hr: 78, still: false, band: _wake);
}

void main() {
  group('(a) the band trim reaches the day calendarDays builds', () {
    test('band-trimmed: the owning day ends at the band\'s last SLEEP', () {
      final days = calendarDays(_build(_nightStart, _nightLen, _nightAt));
      final owner = days.singleWhere((d) => d.sleep.present);
      expect(owner.sleepSource, 'auto');
      expect(_offSec(owner), _bandWake);
      expect(owner.sleep.bandOffsetTrimSec, isNotNull);
      expect(owner.sleep.bandOffsetTrimSec, greaterThan(0));
    });

    test('band absent: the old, later end and no trim', () {
      final days = calendarDays(
          _build(_nightStart, _nightLen, _nightAt, withBand: false));
      final owner = days.singleWhere((d) => d.sleep.present);
      expect(_offSec(owner), greaterThan(_bandWake));
      expect(owner.sleep.bandOffsetTrimSec, isNull);
    });

    test('trimmed + trim == the untrimmed end of the no-band run', () {
      final trimmed = calendarDays(_build(_nightStart, _nightLen, _nightAt))
          .singleWhere((d) => d.sleep.present);
      final plain = calendarDays(
              _build(_nightStart, _nightLen, _nightAt, withBand: false))
          .singleWhere((d) => d.sleep.present);
      expect(trimmed.date, plain.date);
      expect(_offSec(trimmed) + trimmed.sleep.bandOffsetTrimSec!,
          _offSec(plain));
    });
  });

  group('(b) the day payload carries sleep.band_offset_trim_sec', () {
    Map<String, dynamic> payloadFor(PhysioDay day, Substrate sub) {
      final ts = sub.tsSec.sublist(day.sleepLoIdx, day.sleepHiIdx);
      final hr = sub.hr.sublist(day.sleepLoIdx, day.sleepHiIdx);
      final out = deriveDayBundle(
        DayBundleInput(
          date: day.date,
          dayTsSec: sub.tsSec,
          dayHr: sub.hr,
          sleepTsSec: ts,
          sleepHr: hr,
          sleepRrTsMs: const [],
          sleepRrMs: const [],
          sleepSkinTemp: List<int>.filled(ts.length, 0),
          sleepJson: day.sleep.toJson(),
          hypnoStages: const [],
          sleepOnsetSec: day.sleep.window!.onsetMs! ~/ 1000,
          sleepOffsetSec: _offSec(day),
          profile: const {
            'age': 30,
            'sex': 'm',
            'weight_kg': 70,
            'height_cm': 175,
          },
          deviceFamily: 'gen5',
        ).toJson(),
      );
      return (out['sleep'] as Map).cast<String, dynamic>();
    }

    test('trimmed: the key equals the segmentation\'s trim', () {
      final sub = _build(_nightStart, _nightLen, _nightAt);
      final day = calendarDays(sub).singleWhere((d) => d.sleep.present);
      expect(day.sleep.bandOffsetTrimSec, isNotNull, reason: 'precondition');
      final sleep = payloadFor(day, sub);
      expect(sleep.containsKey('band_offset_trim_sec'), isTrue);
      expect(sleep['band_offset_trim_sec'], day.sleep.bandOffsetTrimSec);
    });

    test('band absent: the key is null', () {
      final sub = _build(_nightStart, _nightLen, _nightAt, withBand: false);
      final day = calendarDays(sub).singleWhere((d) => d.sleep.present);
      expect(payloadFor(day, sub)['band_offset_trim_sec'], isNull);
    });
  });

  group('(c) midnight ownership is unchanged vs the no-band baseline', () {
    // Onset 20:30, untrimmed Edge end 00:30. Day D-1 already sees a ~3½ h
    // prefix closed at its last sample and passes the 3 h gate, so today the
    // night can be owned by BOTH days. That pre-existing double ownership is
    // out of scope; the band must simply not change the SET of owners.
    final d = _local(2025, 6, 16);
    final onset = _local(2025, 6, 15, 20, 30);
    final offset = _local(2025, 6, 16, 0, 30);
    final start = _local(2025, 6, 15, 18);
    const n = 12 * 3600;

    for (final lastSleep in [
      _local(2025, 6, 15, 23, 40),
      _local(2025, 6, 15, 23, 55),
    ]) {
      final label = DateTime.fromMillisecondsSinceEpoch(lastSleep * 1000);
      test('band last SLEEP at ${label.hour}:${label.minute}', () {
        _Sec at(int t) {
          if (t < onset || t >= offset) {
            return (hr: 75, still: false, band: _wake);
          }
          return (hr: 50, still: true, band: t < lastSleep ? _sleep : _up);
        }

        Map<String, (int, int)> owners(List<PhysioDay> days) => {
              for (final x in days)
                if (x.sleep.present)
                  x.date: (x.sleep.window!.onsetMs! ~/ 1000, _offSec(x)),
            };

        final baseline = owners(calendarDays(_build(start, n, at, withBand: false)));
        final banded = calendarDays(_build(start, n, at));
        expect(baseline, isNotEmpty, reason: 'precondition: a night exists');
        expect(banded.any((x) => x.sleep.bandOffsetTrimSec != null), isTrue,
            reason: 'precondition: the band rule actually fired');
        expect(owners(banded).keys.toSet(), baseline.keys.toSet(),
            reason: 'baseline windows: $baseline');
        // And the trimmed window on day D still ends at the band's wake.
        final dayD = banded.singleWhere((x) => x.startSec == d);
        expect(_offSec(dayD), lastSleep);
      });
    }
  });

  group('(d) the trimmed-off lie-in is not a nap', () {
    // The untrimmed end the edge would have used without the band.
    int untrimmedEnd() {
      final day = calendarDays(_build(_lieDay, _lieLen, _lieAt))
          .singleWhere((x) => x.sleep.present);
      expect(day.sleep.bandOffsetTrimSec, isNotNull, reason: 'precondition');
      expect(_offSec(day), _lieTrimmed, reason: 'precondition');
      return _offSec(day) + day.sleep.bandOffsetTrimSec!;
    }

    // Detected naps are review candidates now, not credited periods, so the
    // detector's output is read from `candidates`.
    List<Map<String, dynamic>>? naps(int excludeEnd) {
      final sub = _build(_lieDay, _lieLen, _lieAt);
      final onset = calendarDays(sub)
              .singleWhere((x) => x.sleep.present)
              .sleep
              .window!
              .onsetMs! ~/
          1000;
      final candidates = <Map<String, dynamic>>[];
      DerivationEngine.debugAttachNaps(
        <String, dynamic>{},
        <String, dynamic>{},
        sub,
        onset,
        _lieTrimmed,
        attributionStartSec: _lieDay,
        attributionEndSec: _lieDay + 86400,
        candidates: candidates,
        napExcludeEndSec: excludeEnd,
      );
      return candidates;
    }

    final napStart = _local(2025, 6, 16, 7, 30);

    test('control: excluding only up to the trimmed wake emits the nap', () {
      final out = naps(_lieTrimmed);
      expect(out, isNotNull);
      expect(
        out!.any((n) =>
            (n['start'] as int) >= napStart - 120 &&
            (n['start'] as int) <= napStart + 300),
        isTrue,
        reason: 'the fixture must create a nap candidate: $out',
      );
    });

    test('excluding up to the UNTRIMMED end suppresses it', () {
      final end = untrimmedEnd();
      expect(end, greaterThan(napStart), reason: 'precondition');
      final out = naps(end);
      expect(out, isNotNull);
      expect(
        out!.where((n) =>
            (n['start'] as int) >= _lieTrimmed &&
            (n['start'] as int) < end),
        isEmpty,
      );
    });
  });

  group('(d) end to end through the derive engine', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'sleep_band_trim_wiring_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    test('a band-trimmed day carries no nap inside [trimmed, untrimmed)',
        () async {
      final db = await LocalDb.instance;
      final batch = db.batch();
      for (var i = 0; i < _lieLen; i++) {
        final t = _lieDay + i;
        final s = _lieAt(t);
        final rad = (i % 9) * 10.0 * math.pi / 180.0;
        batch.insert('decoded_onehz', {
          'device_id': LocalDb.kPrimaryDeviceId,
          'ts_ms': t * 1000,
          'rec_ts': t,
          'counter': i,
          'hr': s.hr,
          'ax': s.still ? 0.0 : math.cos(rad),
          'ay': 0.0,
          'az': s.still ? 1.0 : math.sin(rad),
          'device_family': 'gen5',
          'band_sleep_state': s.band,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);

      const dayId = '2025-06-16';
      final done =
          await DerivationEngine().runDays(const Profile(), {dayId}, force: true);
      expect(done, 1, reason: 'the day must actually derive');

      final row = await LocalDb.dayResult(dayId);
      final bundle = jsonDecode(row!['payload_json'] as String) as Map;
      final sleep = (bundle['sleep'] as Map).cast<String, dynamic>();
      final trim = (sleep['band_offset_trim_sec'] as num?)?.toInt();
      expect(trim, isNotNull, reason: 'precondition: the day was band-trimmed');
      final win = ((sleep['window'] as Map)['value'] as Map)
          .cast<String, dynamic>();
      final trimmedEnd = (win['offset_ms'] as num).toInt() ~/ 1000;
      expect(trimmedEnd, _lieTrimmed);
      final untrimmed = trimmedEnd + trim!;

      final naps = (bundle['naps'] as Map).cast<String, dynamic>();
      final list = ((naps['value'] as List?) ?? const [])
          .cast<Map>()
          .map((m) => m.cast<String, dynamic>());
      expect(naps['value'], isNotNull, reason: 'naps were judged: $naps');
      expect(
        list.where((n) {
          final s = (n['start'] as num).toInt();
          return s >= trimmedEnd && s < untrimmed;
        }),
        isEmpty,
        reason: 'naps: ${naps['value']}',
      );
      // Detected naps land as review suggestions; the lie-in must not either.
      final suggested = await db.query('activity_suggestions',
          where: "kind = 'nap' AND start_ts >= ? AND start_ts < ?",
          whereArgs: [trimmedEnd, untrimmed]);
      expect(suggested, isEmpty);
    });
  });
}
