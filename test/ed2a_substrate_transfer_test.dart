// ED-2a E5: upstream's existing worker, no E3 annotations/registry/AST guard.
// fromTransfer delegates to fromJson in RED: parity passes, adoption fails.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';

import 'support/dart_source.dart';

const _intKeys = ['ts_sec', 'hr', 'spo2_red', 'spo2_ir', 'skin_temp',
    'skin_contact', 'step_count', 'hr_valid', 'band_sleep_state'];
const _doubleKeys = ['rr_ts_ms', 'rr_ms', 'ax', 'ay', 'az'];
const _start = 1577923200; // existing two_device_day fixture, UTC

Map<String, dynamic> _columns() => {
  'ts_sec': <int>[_start, _start + 1, _start + 2],
  'hr': <int>[60, 0, 61],
  'rr_ts_ms': Float64List.fromList([1577923199999.5, 1577923201000.25]),
  'rr_ms': Float64List.fromList([850.125, 900.5]),
  'ax': Float64List.fromList([-0.0, double.minPositive, double.nan]),
  'ay': Float64List.fromList([double.infinity, double.negativeInfinity, 0.1 + 0.2]),
  'az': Float64List.fromList([1, -1, 0.5]),
  'spo2_red': <int>[0, 1, 65535], 'spo2_ir': <int>[123, 0, 65534],
  'skin_temp': <int>[30001, 0, 30002], 'skin_contact': <int>[1, 0, -1],
  'step_count': <int>[65535, 0, -1], 'hr_valid': <int>[1, 0, -1],
  'band_sleep_state': <int>[1, 0, -1],
  'device_family': 'gen5', 'device_ids': ['secondary', '', 'secondary'],
};

void _same(Substrate got, Substrate oracle) {
  final a = got.toJson(), b = oracle.toJson();
  expect(a.keys, b.keys, reason: 'every serialized field must survive');
  for (final key in _intKeys) { expect(a[key], b[key], reason: key); }
  for (final key in _doubleKeys) {
    expect(a[key], isA<Float64List>(), reason: '$key must remain packed');
    final g = a[key] as Float64List, w = b[key] as Float64List;
    expect(g.buffer.asUint64List(g.offsetInBytes, g.length),
        w.buffer.asUint64List(w.offsetInBytes, w.length), reason: '$key IEEE-754 bits');
  }
  expect(got.deviceFamily, oracle.deviceFamily);
  expect(got.deviceIds, oracle.deviceIds);
}

// Exercise the actual upstream prepare worker. Own every port/subscription and
// kill on every exit, including a failed handshake or malformed-page error.
Future<Map<String, dynamic>> _worker(List<Map<String, dynamic>> frames,
    List<Map<String, dynamic>> rr, {Map<String, dynamic>? page}) async {
  final port = ReceivePort();
  Isolate? isolate;
  StreamSubscription<dynamic>? subscription;
  final ready = Completer<SendPort>();
  final done = Completer<Map<String, dynamic>>();
  // Either future can fail before the caller reaches it.
  unawaited(ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  unawaited(done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  void fail(Object error) {
    if (!ready.isCompleted) ready.completeError(error);
    if (!done.isCompleted) done.completeError(error);
  }
  try {
    subscription = port.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is Map && message['type'] == 'result') {
        if (!done.isCompleted) done.complete((message['payload'] as Map).cast<String, dynamic>());
      } else if (message is Map && message['type'] == 'error') {
        fail(StateError('${message['error']}'));
      } else if (message is List) {
        fail(StateError('uncaught worker error: $message'));
      } else if (message == null && !done.isCompleted) {
        fail(StateError('worker exited before returning a payload'));
      }
    });
    isolate = await Isolate.spawn(derivationPrepareWorker, port.sendPort,
        onError: port.sendPort, onExit: port.sendPort);
    final worker = await ready.future.timeout(const Duration(seconds: 10));
    worker.send({'type': 'config', 'mode': 'substrate'});
    worker.send(page ?? {'type': 'page', 'frames': frames, 'rr': rr});
    worker.send({'type': 'finish'});
    return await done.future.timeout(const Duration(seconds: 10));
  } finally {
    await subscription?.cancel();
    port.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}

Map<String, dynamic> _bundle(Substrate sub) {
  final day = prepareDerivationPayload(sub).days.first;
  final d = day.daySub, s = day.sleepSub;
  return deriveDayBundle(DayBundleInput(
    date: day.date, dayTsSec: d.tsSec, dayHr: d.hr,
    dayRrTsMs: d.rrTsMs, dayRrMs: d.rrMs,
    sleepTsSec: s.tsSec, sleepHr: s.hr, sleepRrTsMs: s.rrTsMs,
    sleepRrMs: s.rrMs, sleepSkinTemp: s.skinTemp,
    sleepJson: day.sleepJson, hypnoStages: day.hypnoStages,
    sleepOnsetSec: day.sleepOnsetSec, sleepOffsetSec: day.sleepOffsetSec,
    profile: const Profile().toMap(), dayConfidence: day.confidence,
    dayFlags: day.flags, deviceFamily: d.deviceFamily,
    sleepSource: day.sleepSource,
  ).toJson());
}

// Same generator as case 1 in two_device_fixture_test.dart, driven by the
// committed region spec. Only the documented gen4 regions feed that golden.
({List<Map<String, dynamic>> frames, List<Map<String, dynamic>> rr}) _fixture() {
  final spec = jsonDecode(File('test/fixtures/two_device_day.json').readAsStringSync()) as Map;
  int offset(String hhmmss) {
    final p = hhmmss.split(':').map(int.parse).toList();
    return p[0] * 3600 + p[1] * 60 + p[2];
  }
  final frames = <Map<String, dynamic>>[], rr = <Map<String, dynamic>>[];
  for (final region in spec['regions'] as List) {
    final r = region as Map;
    if (!(r['devices'] as List).contains('gen4')) continue;
    final holes = {for (final h in (r['holes'] as List?) ?? []) offset(h as String)};
    for (var i = offset(r['start'] as String); i <= offset(r['end'] as String); i++) {
      if (holes.contains(i)) continue;
      final ts = _start + i;
      frames.add({'rec_ts': ts, 'device_family': 'gen4', 'hr': 60 + ts % 7,
        'ax': 0.0, 'ay': 0.0, 'az': 1.0, 'skin_temp_raw': 30000 + ts % 11});
      rr.add({'rec_ts': ts, 'rr_ms': 1000 - ts % 5 * 10});
    }
  }
  return (frames: frames, rr: rr);
}

void main() {
  test('engine receives prepare-worker substrate through the transfer seam', () {
    final code = stripCommentsAndStrings(File('lib/compute/derivation_engine.dart').readAsStringSync());
    expect(code, matches(RegExp(r'\bSubstrate\.fromTransfer\(\s*payload\s*\)')),
        reason: 'the actual receiver still calls fromJson, which copies every column');
  });

  for (final key in [..._intKeys, ..._doubleKeys]) {
    test('transfer adopts correctly typed $key without an element copy', () {
      final message = _columns();
      final got = Substrate.fromTransfer(message).toJson();
      expect(identical(got[key], message[key]), isTrue,
          reason: '$key was copied on the receiving/UI isolate');
    });
  }

  test('transfer preserves every field and double bit, including band sleep state', () {
    final message = _columns();
    final got = Substrate.fromTransfer(message);
    _same(got, Substrate.fromJson(message));
    expect(got.bandSleepState, [1, 0, -1], reason: '0 is wake, -1 is absent');
    expect(got.deviceIds, {'secondary', ''});
  });

  final variants = <String, Map<String, dynamic> Function()>{
    'empty': () => {},
    'timestamps only': () => {'ts_sec': <int>[_start, _start + 1]},
    'missing timestamps': () => {..._columns()}..remove('ts_sec'),
    'empty optional columns': () => {..._columns(), 'hr': <int>[], 'ax': Float64List(0),
      'step_count': <int>[], 'hr_valid': <int>[], 'band_sleep_state': <int>[]},
    'short columns and sparse unpaired RR': () => {..._columns(), 'hr': <int>[62],
      'az': Float64List.fromList([0.25]), 'step_count': <int>[1],
      'hr_valid': <int>[1], 'band_sleep_state': <int>[0],
      'rr_ms': Float64List.fromList([850])},
    'null provenance': () => {..._columns(), 'device_family': null, 'device_ids': null},
    'loose numeric columns': () => {
      for (final e in _columns().entries)
        e.key: e.value is List ? List<dynamic>.from(e.value as List) : e.value,
    },
    'mixed integer and double numbers': () => {'ts_sec': <dynamic>[_start.toDouble(), _start + 1],
      'hr': <dynamic>[60.0, 61], 'rr_ms': <dynamic>[850, 900.5],
      'rr_ts_ms': <dynamic>[1577923200123, 1577923201000.5],
      'band_sleep_state': <dynamic>[0.0, 1]},
    'wide integers': () => {..._columns(), 'ts_sec': <int>[1 << 40, (1 << 40) + 1, (1 << 40) + 2],
      'step_count': <int>[1 << 40, -(1 << 40), 0]},
  };
  for (final variant in variants.entries) {
    test('transfer defaults equal fromJson: ${variant.key}', () {
      final m = variant.value();
      _same(Substrate.fromTransfer(m), Substrate.fromJson(m));
    });
  }

  test('GUARD constructor optional arrays remain empty; decoder defaults remain absent', () {
    final direct = Substrate(tsSec: [_start], hr: [60], rrTsMs: [], rrMs: [],
        ax: [0], ay: [0], az: [1], spo2Red: [0], spo2Ir: [0], skinTemp: [0], skinContact: [0]);
    expect(direct.stepCount, isEmpty);
    expect(direct.hrValid, isEmpty);
    expect(direct.bandSleepState, isEmpty);
    final decoded = Substrate.fromTransfer({'ts_sec': <int>[_start]});
    expect(decoded.stepCount, [-1]);
    expect(decoded.hrValid, [-1]);
    expect(decoded.bandSleepState, [-1]);
    expect(decoded.hr, [0]);
    expect(decoded.ax, [0.0]);
    expect(decoded.rrMs, isEmpty);
  });

  test('actual prepare worker emits columnar typed doubles and preserves band sleep', () async {
    final frames = [for (var i = 0; i < 3; i++) <String, dynamic>{
      'rec_ts': _start + i, 'hr': 60 + i, 'device_family': 'gen5',
      'ax': 0.25, 'ay': -0.0, 'az': 1.0, 'step_count': 20 + i,
      'hr_valid': i % 2, 'band_sleep_state': [1, 0, -1][i],
      'device_id': '', 'skin_temp_raw': 30000 + i,
    }];
    final rr = [<String, dynamic>{'rec_ts': _start, 'rr_ms': 850,
      'rr_ts_ms': _start * 1000, 'beat_ts_ms': _start * 1000 + 123}];
    final message = await _worker(frames, rr);
    for (final key in _doubleKeys) { expect(message[key], isA<Float64List>(), reason: key); }
    for (final key in _intKeys) { expect(message[key], isA<List<int>>(), reason: key); }
    expect(message.values.any((v) => v is List && v.any((e) => e is Map)), isFalse,
        reason: 'worker substrate contains columns, never per-row maps');
    final got = Substrate.fromTransfer(message);
    _same(got, substrateFromDecodedPage(frames, rr));
    expect(got.bandSleepState, [1, 0, -1]);
    expect(got.rrTsMs, [_start * 1000.0 + 123]);
  });

  test('actual worker result adopts its received arrays', () async {
    final message = await _worker([{'rec_ts': _start, 'hr': 60, 'az': 1.0}], []);
    final adopted = Substrate.fromTransfer(message).toJson();
    for (final key in [..._intKeys, ..._doubleKeys]) {
      expect(identical(adopted[key], message[key]), isTrue, reason: '$key copied after worker receive');
    }
  });

  test('a worker error does not prevent the next transfer', () async {
    await expectLater(_worker([], [], page: {'type': 'page', 'frames': 'malformed transport'}), throwsStateError);
    final good = await _worker([{'rec_ts': _start, 'hr': 60}], []);
    expect(Substrate.fromTransfer(good).hr, [60]);
  });

  test('GUARD existing golden is byte-equal with transfer off, on, and across the worker', () async {
    // Same timezone condition as the existing golden test; no regeneration.
    if (DateTime.fromMillisecondsSinceEpoch(_start * 1000).timeZoneOffset != Duration.zero) {
      markTestSkipped('committed golden is UTC; run this test with TZ=UTC');
      return;
    }
    expect(kAlgoVersion, 119, reason: 'ED-2a changes no output');
    final fixture = _fixture();
    final baseline = substrateFromDecodedPage(fixture.frames, fixture.rr);
    final transferred = Substrate.fromTransfer(baseline.toJson());
    final workerMessage = await _worker(fixture.frames, fixture.rr);
    final acrossWorker = Substrate.fromTransfer(workerMessage);
    _same(transferred, baseline);
    _same(acrossWorker, baseline);
    final golden = jsonDecode(File('test/fixtures/two_device_day_expected.json').readAsStringSync()) as Map;
    final expected = jsonEncode(golden['single_device']);
    expect(jsonEncode(_bundle(baseline)), expected, reason: 'transfer off');
    expect(jsonEncode(_bundle(transferred)), expected, reason: 'transfer on');
    expect(jsonEncode(_bundle(acrossWorker)), expected, reason: 'actual worker round trip');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
