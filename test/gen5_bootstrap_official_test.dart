// The official WHOOP 5 connection bootstrap, end to end.
//
// What this stands in for: the exact readiness sequence recovered from the
// official client —
//
//   connect → prefer LE 2M PHY → discover/validate fd4b → MTU 247 → bond →
//   600 ms → register required notifications serially → 500 ms →
//   GET_HELLO(145, body 01, 5 s, PENDING non-terminal) → Android native name
//   non-null → identity (serial/CPU fully alphanumeric) → clock contract
//   (hello's own timestamp incl. subseconds; <2 whole seconds: no write;
//   ≥2 s: ONE awaited SET_CLOCK, no read-back) → awaited
//   GET_ADVERTISING_NAME(141, body 01) → READY → charging-only opcode-151
//   follow-up —
//
// driven over the REAL production sequence (debugConnectGen5Official runs
// _connectGen5Official itself) with only the radio replaced: a scripted
// GattBootstrapOps records the platform steps and the fake link records every
// command, interleaved with the READY transition in one trace.
//
// The hello-failure counter rules live here too: failures 1–4 record and
// disconnect; the fifth removes the platform bond exactly once and resets the
// counter; NOTHING clears the accumulated count except a complete bootstrap
// reaching READY.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

int _wallNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A revision-1 gen5 hello body built for the real protocol parser.
Uint8List _helloBody({
  required int tsSeconds,
  String serial = 'W5AB12CD34',
  bool charging = false,
}) {
  final body = Uint8List(Gen5HelloInfo.semanticBodyLen);
  final v = ByteData.sublistView(body);
  body[0] = 1; // hello revision
  v.setUint32(1, 730, Endian.little);
  body[5] = charging ? 1 : 0;
  v.setUint32(6, tsSeconds, Endian.little);
  for (var i = 0; i < serial.length && 14 + i < 25; i++) {
    body[14 + i] = serial.codeUnitAt(i);
  }
  v.setUint32(87, 82, Endian.little); // optical discriminator ⇒ WHOOP 5
  body[91] = 50;
  body[92] = 40;
  body[93] = 1;
  body[102] = 1;
  return body;
}

Decoded _helloReply(
  int seq, {
  int? tsSeconds,
  int status = CommandAwaiter.statusSuccess,
  String serial = 'W5AB12CD34',
  bool charging = false,
  Gen5HelloInfo? hello,
}) => Decoded('cmd_response', {
  'opcode': Cmd.getHello,
  'req_seq': seq,
  'cmd_status': status,
  if (status == CommandAwaiter.statusSuccess)
    'gen5_hello':
        hello ??
        Gen5HelloInfo.parse(
          _helloBody(
            tsSeconds: tsSeconds ?? _wallNow(),
            serial: serial,
            charging: charging,
          ),
        )!,
});

Decoded _clockAck(int seq) => Decoded('cmd_response', {
  'opcode': Cmd.setClock,
  'req_seq': seq,
  'cmd_status': CommandAwaiter.statusSuccess,
});

Decoded _nameReply(int seq) => Decoded('cmd_response', {
  'opcode': Cmd.getCustomAdvertisingName,
  'req_seq': seq,
  'cmd_status': CommandAwaiter.statusSuccess,
});

/// The fake link + scripted platform ops, sharing ONE trace:
/// 'phy' / 'discover' / 'mtu:247' / 'bond:check' / 'bond:create' /
/// 'sub:{role}' / 'native_name' / 'cmd:{opcode}' / 'ready'.
class _Rig {
  final logs = <String>[];
  final commands = <({int seq, int opcode, List<int> body})>[];
  final afterSupersede = <int>[];
  final trace = <String>[];
  late final BleEngine engine;

  Decoded? Function(int seq, int opcode)? replyTo;

  /// What the injected Android native-name reader answers; the reader also
  /// records the remoteId it was asked about.
  String? nativeName = 'WHOOP 4A0X';
  final nativeNameQueries = <String>[];

  bool _sawReady = false;
  bool get ready => _sawReady;

  int bondRemovals = 0;

  /// [onCommitBatch] is the production durable-commit sink; [armDrains]
  /// false leaves the link's drain controllers to the connect sequence
  /// itself, exactly as on a real connect.
  _Rig({CommitSyncBatchSink? onCommitBatch, bool armDrains = true}) {
    engine = BleEngine(
      onCommitBatch: onCommitBatch,
      onRecord: (_, _) async {},
      onState: (s) {
        if (!_sawReady && s.connection == 'connected') {
          _sawReady = true;
          trace.add('ready');
        }
      },
      log: logs.add,
    );
    engine.debugNativeNameReader = (remoteId) async {
      nativeNameQueries.add(remoteId);
      trace.add('native_name');
      return nativeName;
    };
    engine.debugBondRemover = () async {
      bondRemovals++;
    };
    // Every entry into the engine's connection-priority path lands in the
    // trace, so the exact pre-READY order below PROVES the official sequence
    // carries no requestConnectionPriority (doc 06 found none in the official
    // data path); the post-READY offload transition still may.
    engine.debugOnPriorityRequest = () => trace.add('link_priority');
    engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      armDrains: armDrains,
      onWrite: (frame) async {
        final inner = parseFrame(frame, profile: BandProfile.gen5)!.inner;
        commands.add((seq: inner[1], opcode: inner[2], body: inner.sublist(3)));
        trace.add('cmd:${inner[2]}');
        final reply = replyTo?.call(inner[1], inner[2]);
        if (reply != null) engine.debugAbsorbDecoded(reply);
        return true;
      },
    );
  }

  List<int> get opcodes => commands.map((c) => c.opcode).toList();
  int count(int opcode) => opcodes.where((o) => o == opcode).length;
  bool logged(String needle) => logs.any((l) => l.contains(needle));

  /// The standard all-answering strap: hello (with [tsSeconds]/[serial]/
  /// [charging]), SET_CLOCK ack, advertising-name reply.
  void answerAll({
    int? tsSeconds,
    String serial = 'W5AB12CD34',
    bool charging = false,
  }) {
    replyTo = (seq, op) => switch (op) {
      Cmd.getHello => _helloReply(
        seq,
        tsSeconds: tsSeconds ?? _wallNow(),
        serial: serial,
        charging: charging,
      ),
      Cmd.setClock => _clockAck(seq),
      Cmd.getCustomAdvertisingName => _nameReply(seq),
      _ => null,
    };
  }

  void supersedeSession() {
    engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      onWrite: (frame) async {
        afterSupersede.add(
          parseFrame(frame, profile: BandProfile.gen5)!.inner[2],
        );
        return true;
      },
    );
  }
}

class _Ops implements GattBootstrapOps {
  final _Rig rig;
  final bool alreadyBonded;
  final bool phyFails;
  final bool bondFails;
  /// The bond-state read never answers — the hang the seam's timeout bounds.
  final bool bondCheckHangs;
  final bool discoveryFails;
  final bool memfaultPresent;
  final Set<String> failSubscribe;
  /// Runs right after a registration succeeds — traffic the band (or another
  /// client's transfer) delivers the moment notifications are on.
  final void Function(String role)? afterSubscribe;

  _Ops(
    this.rig, {
    this.alreadyBonded = false,
    this.phyFails = false,
    this.bondFails = false,
    this.bondCheckHangs = false,
    this.discoveryFails = false,
    this.memfaultPresent = true,
    this.failSubscribe = const {},
    this.afterSubscribe,
  });

  @override
  bool get bondingApplies => true;

  @override
  Future<void> preferLe2mPhy() async {
    rig.trace.add('phy');
    if (phyFails) throw Exception('PHY_UPDATE unsupported');
  }

  @override
  Future<BandEntry?> discoverAndValidate() async {
    rig.trace.add('discover');
    return discoveryFails ? null : kWhoopGen5;
  }

  @override
  Future<int> requestMtu(int mtu) async {
    rig.trace.add('mtu:$mtu');
    return mtu;
  }

  @override
  Future<bool> isBonded() async {
    rig.trace.add('bond:check');
    // A platform `getBondState` that never comes back.
    if (bondCheckHangs) return Completer<bool>().future;
    return alreadyBonded;
  }

  @override
  Future<void> createBond() async {
    rig.trace.add('bond:create');
    if (bondFails) throw Exception('bond refused');
  }

  @override
  Future<void> subscribe(String role) async {
    rig.trace.add('sub:$role');
    if (failSubscribe.contains(role)) throw Exception('CCC write failed');
    afterSubscribe?.call(role);
  }

  @override
  Future<bool> subscribeOptionalMemfault() async {
    rig.trace.add('sub:memfault(opt)');
    return memfaultPresent;
  }
}

/// Run the real official connect under [async]. Null until it settles.
bool? _run(
  _Rig rig,
  FakeAsync async, {
  _Ops? ops,
  Duration elapse = const Duration(seconds: 8),
}) {
  bool? ok;
  rig.engine.debugConnectGen5Official(ops ?? _Ops(rig)).then((v) => ok = v);
  async.elapse(elapse);
  return ok;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  group('another client\'s transfer during bootstrap', () {
    test(
      'records delivered while notifications come up are banked tokenless, '
      'with the production construction order', () {
        fakeAsync((async) {
          final commits = <(String?, int)>[];
          final rig = _Rig(
            armDrains: false,
            onCommitBatch: (raws, samples, token,
                {archives, ecgRawPackets, deviceFamily}) async {
              commits.add((token, raws.length + (archives?.length ?? 0)));
            },
          )..answerAll();
          void rx(Uint8List inner) => rig.engine
              .debugReceiveFrame(Frame(inner, true, true), role: 'data');
          final ops = _Ops(rig, afterSubscribe: (role) {
            if (role != 'data') return;
            // The other client is mid-transfer the moment we subscribe.
            rx(Uint8List.fromList(
                [PacketType.metadata, 0x01, SyncMeta.historyStart]));
            final rec = Uint8List(kGen5V18InnerLen);
            final v = ByteData.sublistView(rec);
            rec[0] = PacketType.historicalData;
            rec[1] = 18;
            rec[2] = 0x80;
            v.setUint32(3, 5100, Endian.little);
            v.setUint32(7, _wallNow() - 3600, Endian.little);
            rec[14] = 64;
            v.setFloat32(33, 0.5, Endian.little);
            v.setFloat32(45, 1.0, Endian.little);
            rx(rec);
            final end = Uint8List(24);
            end[0] = PacketType.metadata;
            end[1] = 0x02;
            end[2] = SyncMeta.historyEnd;
            ByteData.sublistView(end)
              ..setUint32(3, 1786000000, Endian.little)
              ..setUint32(9, 1, Endian.little)
              ..setUint32(13, 0xE100, Endian.little)
              ..setUint32(17, 0x18, Endian.little);
            rx(end);
          });
          _run(rig, async, ops: ops);

          expect(commits, [(null, 1)],
              reason: 'the record is banked, and without a trim token');
          expect(rig.count(Cmd.historicalDataResult), 0,
              reason: 'never answered');
          expect(rig.count(Cmd.abortHistoricalTransmits), 0);
          expect(rig.count(Cmd.sendHistoricalData), 0,
              reason: 'INIT does not start a competing transfer');
        });
      },
    );
  });

  test('a foreign bank delayed past a change of band is stamped with the '
      'band that sent the rows', () {
    fakeAsync((async) {
      final families = <String?>[];
      final hold = Completer<void>();
      var first = true;
      final rig = _Rig(
        armDrains: false,
        onCommitBatch: (raws, samples, token,
            {archives, ecgRawPackets, deviceFamily}) async {
          if (first) {
            first = false;
            await hold.future;
          }
          families.add(deviceFamily);
        },
      )..answerAll();
      void rx(Uint8List inner) => rig.engine
          .debugReceiveFrame(Frame(inner, true, true), role: 'data');
      Uint8List rec(int counter) {
        final r = Uint8List(kGen5V18InnerLen);
        final v = ByteData.sublistView(r);
        r[0] = PacketType.historicalData;
        r[1] = 18;
        r[2] = 0x80;
        v.setUint32(3, counter, Endian.little);
        v.setUint32(7, _wallNow() - 3600 + counter, Endian.little);
        r[14] = 64;
        v.setFloat32(33, 0.5, Endian.little);
        v.setFloat32(45, 1.0, Endian.little);
        return r;
      }
      Uint8List end(int token) {
        final e = Uint8List(24);
        e[0] = PacketType.metadata;
        e[1] = 0x02;
        e[2] = SyncMeta.historyEnd;
        ByteData.sublistView(e)
          ..setUint32(3, 1786000000, Endian.little)
          ..setUint32(9, 1, Endian.little)
          ..setUint32(13, token, Endian.little)
          ..setUint32(17, 0x18, Endian.little);
        return e;
      }
      final ops = _Ops(rig, afterSubscribe: (role) {
        if (role != 'data') return;
        rx(Uint8List.fromList(
            [PacketType.metadata, 0x01, SyncMeta.historyStart]));
        rx(rec(5200));
        rx(end(0xE200)); // its bank parks in the store
        rx(rec(5201));
        rx(end(0xE201)); // this one queues behind it
      });
      _run(rig, async, ops: ops);
      final family = rig.engine.linkDeviceFamily;
      expect(family, isNotNull);
      // A different band is connected by the time the store frees up.
      rig.engine.state.generation = 'gen4';
      hold.complete();
      async.elapse(const Duration(seconds: 1));
      expect(families, hasLength(2));
      expect(families, everyElement(family));
    });
  });

  group('a headless connect that fails after taking in foreign records', () {
    ({_Rig rig, _Ops ops, Completer<void> hold}) setup() {
      final hold = Completer<void>();
      var first = true;
      final rig = _Rig(
        armDrains: false,
        onCommitBatch: (raws, samples, token,
            {archives, ecgRawPackets, deviceFamily}) async {
          if (first) {
            first = false;
            await hold.future;
          }
        },
      )..answerAll();
      void rx(Uint8List inner) => rig.engine
          .debugReceiveFrame(Frame(inner, true, true), role: 'data');
      final ops = _Ops(rig, failSubscribe: {'events'}, afterSubscribe: (role) {
        if (role != 'data') return;
        rx(Uint8List.fromList(
            [PacketType.metadata, 0x01, SyncMeta.historyStart]));
        final rec = Uint8List(kGen5V18InnerLen);
        final v = ByteData.sublistView(rec);
        rec[0] = PacketType.historicalData;
        rec[1] = 18;
        rec[2] = 0x80;
        v.setUint32(3, 5300, Endian.little);
        v.setUint32(7, _wallNow() - 3600, Endian.little);
        rec[14] = 64;
        v.setFloat32(33, 0.5, Endian.little);
        v.setFloat32(45, 1.0, Endian.little);
        rx(rec);
        final end = Uint8List(24);
        end[0] = PacketType.metadata;
        end[1] = 0x02;
        end[2] = SyncMeta.historyEnd;
        ByteData.sublistView(end)
          ..setUint32(3, 1786000000, Endian.little)
          ..setUint32(9, 1, Endian.little)
          ..setUint32(13, 0xE300, Endian.little)
          ..setUint32(17, 0x18, Endian.little);
        rx(end); // its bank parks in the store
      });
      return (rig: rig, ops: ops, hold: hold);
    }

    test('waits for their bank before giving up', () {
      fakeAsync((async) {
        final t = setup();
        bool? connected;
        connectHeadless(
          t.rig.engine,
          () => t.rig.engine.debugConnectGen5Official(t.ops),
        ).then((v) => connected = v);
        async.elapse(const Duration(seconds: 8));
        expect(t.rig.trace, contains('sub:events'));
        expect(connected, isNull,
            reason: 'the failed run must not finish while those rows are in '
                'flight');
        t.hold.complete();
        async.elapse(const Duration(seconds: 1));
        expect(connected, isFalse);
      });
    });

    test('… bounded', () {
      fakeAsync((async) {
        final t = setup();
        bool? connected;
        connectHeadless(
          t.rig.engine,
          () => t.rig.engine.debugConnectGen5Official(t.ops),
          bound: const Duration(seconds: 12),
        ).then((v) => connected = v);
        async.elapse(const Duration(seconds: 8));
        expect(connected, isNull);
        async.elapse(const Duration(seconds: 13));
        expect(connected, isFalse);
        expect(t.rig.logged('not waiting longer'), isTrue);
      });
    });
  });

  group('the successful sequence, in order, through READY', () {
    test(
      'drift below two seconds: no GET_CLOCK, no SET_CLOCK, exact order',
      () {
        fakeAsync((async) {
          final rig = _Rig()..answerAll();
          expect(_run(rig, async), isTrue);

          // The exact pre-READY portion of the trace, in order. The equality
          // also PROVES two absences: no requestConnectionPriority (every
          // entry into that path would land as 'link_priority' — the official
          // data path was found to carry none) and no clock traffic.
          // Registrations follow the retained official fixture order:
          // command response → optional Memfault → data → events.
          final readyAt = rig.trace.indexOf('ready');
          expect(readyAt, isNot(-1));
          expect(rig.trace.sublist(0, readyAt), [
            'phy',
            'discover',
            'mtu:247',
            'bond:check',
            'bond:create',
            'sub:cmd_from',
            'sub:memfault(opt)',
            'sub:data',
            'sub:events',
            'cmd:${Cmd.getHello}',
            'native_name',
            'cmd:${Cmd.getCustomAdvertisingName}',
          ]);
          expect(rig.count(Cmd.getClock), 0);
          expect(rig.count(Cmd.setClock), 0);
          expect(
            rig.commands.first.body,
            [0x01],
            reason: 'GET_HELLO body is the fixed revision byte 01',
          );
          // The gen4 advertising-name opcode must never ride a gen5 link.
          expect(rig.opcodes, isNot(contains(Cmd.getAdvertisingNameHarvard)));
        });
      },
    );

    test('drift of exactly two seconds: one awaited SET_CLOCK before the '
        'advertising name and READY', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll(tsSeconds: _wallNow() - 2);
        expect(_run(rig, async), isTrue);

        expect(
          rig.count(Cmd.setClock),
          1,
          reason:
              '"at 2 or more, send one SET_CLOCK" — the threshold is '
              'inclusive',
        );
        expect(rig.count(Cmd.getClock), 0, reason: 'and no read-back');
        final t = rig.trace;
        expect(
          t.indexOf('cmd:${Cmd.setClock}'),
          lessThan(t.indexOf('cmd:${Cmd.getCustomAdvertisingName}')),
        );
        expect(
          t.indexOf('cmd:${Cmd.getCustomAdvertisingName}'),
          lessThan(t.indexOf('ready')),
        );
        // The 8-byte confirmed gen5 body: u32 LE seconds + u32 LE subseconds
        // (the inner packet pads to a 4-byte boundary behind it). The seconds
        // are a FRESH phone sample taken when the request was built.
        final body = rig.commands
            .firstWhere((c) => c.opcode == Cmd.setClock)
            .body;
        expect(body.length, greaterThanOrEqualTo(8));
        final sec =
            body[0] | (body[1] << 8) | (body[2] << 16) | (body[3] << 24);
        expect(
          (sec - _wallNow()).abs(),
          lessThanOrEqualTo(2),
          reason:
              'the write carries newly sampled phone time, not the '
              'hello timestamp',
        );
        // BOTH HALVES OF THE CORRELATION COME FROM THAT ONE SAMPLE. Re-reading
        // the wall clock after the response resolves would make `driftSec` the
        // round trip, and `setAlarm` arms at `when - driftSec`.
        //
        // A CONTRACT PIN, NOT A REGRESSION CATCHER: the engine samples
        // `DateTime.now()`, which `fakeAsync` does not drive (it only rebinds
        // `package:clock`), so no amount of elapsed fake time separates the two
        // reads here and the previous shape passes this too. Making it
        // discriminate means moving the engine onto `clock.now()` — a
        // production change for a test, and one that would re-base every other
        // wall-clock assertion in this file.
        expect(rig.engine.clockRef?.device, sec);
        expect(
          rig.engine.clockRef?.driftSec,
          0,
          reason: 'the strap just took this sample — the drift the write '
              'corrected must not come back as latency',
        );
      });
    });

    test(
      'a zero HELLO timestamp is PRESENT: one SET_CLOCK, never GET_CLOCK',
      () {
        fakeAsync((async) {
          final rig = _Rig()..answerAll(tsSeconds: 0);
          expect(_run(rig, async), isTrue);

          expect(
            rig.count(Cmd.setClock),
            1,
            reason:
                'zero means the RTC needs correcting, not that the '
                'timestamp is missing',
          );
          expect(
            rig.count(Cmd.getClock),
            0,
            reason:
                'GET_CLOCK is only the generic null-timestamp fallback, '
                'and a parsed hello always carries the timestamp',
          );
        });
      },
    );

    test('an UNKNOWN hello revision still reaches READY, and forfeits the '
        '"already in sync" shortcut', () {
      fakeAsync((async) {
        // The pinned parser records the revision byte instead of gating on it
        // (protocol#35) precisely so a firmware that bumps it can still
        // connect — HELLO is MANDATORY here. But every field is still read at
        // the revision-1 offsets, so the one value this path ACTS on that a
        // moved layout could make plausible-but-wrong is the timestamp.
        final body = _helloBody(tsSeconds: _wallNow());
        body[0] = 2; // a layout these fixed offsets do not describe
        final hello = Gen5HelloInfo.parse(body)!;
        final rig = _Rig();
        rig.replyTo = (seq, op) => switch (op) {
          Cmd.getHello => _helloReply(seq, hello: hello),
          Cmd.setClock => _clockAck(seq),
          Cmd.getCustomAdvertisingName => _nameReply(seq),
          _ => null,
        };
        expect(
          _run(rig, async),
          isTrue,
          reason: 'an unknown revision is NOT a connection failure — that is '
              'the whole point of the repin',
        );
        expect(
          rig.count(Cmd.setClock),
          1,
          reason: 'a timestamp that reads as in-sync at revision-1 offsets is '
              'not evidence under an unknown layout, so the unconditional '
              'write of freshly sampled phone time runs instead',
        );
        expect(rig.count(Cmd.getClock), 0);
        // AND NOTHING REVISION-SPECIFIC IS PUBLISHED. `onState` is durable —
        // it writes a band_battery sample, can fire the battery notification,
        // heals the serial onto the PAIRING RECORD and pushes the lock-screen
        // widget — so a moved layout would persist four fabricated values.
        // The identity gate cannot be leaned on to stop that: it runs after
        // this publication, and `cpuHex` is hex by construction so it only
        // fails when empty.
        final st = rig.engine.state;
        expect(st.serial, isNull, reason: 'body[14..24] under an unknown map');
        expect(st.batteryPct, isNull, reason: 'body[1..4] — the hello says 73');
        expect(st.charging, isNull, reason: 'body[5] bit0');
        expect(st.wristOn, isNull, reason: 'body[102]');
      });
    });

    test('an UNKNOWN hello revision does not start the charging follow-up', () {
      fakeAsync((async) {
        // `charging` is body[5] of the revision-1 map, so an unknown revision
        // is no evidence the band is on a charger — and opcode 151 is five
        // requests five seconds apart against a band that never said so.
        final body = _helloBody(tsSeconds: _wallNow(), charging: true);
        body[0] = 2;
        final hello = Gen5HelloInfo.parse(body)!;
        final rig = _Rig();
        rig.replyTo = (seq, op) => switch (op) {
          Cmd.getHello => _helloReply(seq, hello: hello),
          Cmd.setClock => _clockAck(seq),
          Cmd.getCustomAdvertisingName => _nameReply(seq),
          _ => null,
        };
        expect(_run(rig, async, elapse: const Duration(seconds: 40)), isTrue);
        expect(
          rig.count(Cmd.getBatteryPackInfo),
          0,
          reason: 'the charge flag was read at offsets that may describe '
              'something else entirely',
        );
      });
    });

    test('a strap TWO DAYS ahead: the contract is unconditional, and the '
        'corrected clock does not suppress the initial history drain', () {
      fakeAsync((async) {
        // The pre-correction hello reading trips Edge's phone-suspect history
        // policy. The official contract still writes exactly one SET_CLOCK
        // (doc 01: ≥2 s → one awaited write, non-null response → readiness),
        // and the accepted correction must clear the now-stale verdict so
        // the INIT drain is not deferred against a reading the write erased.
        final rig = _Rig()..answerAll(tsSeconds: _wallNow() + 2 * 86400);
        expect(_run(rig, async), isTrue);

        expect(rig.count(Cmd.setClock), 1);
        expect(rig.count(Cmd.getClock), 0);
        expect(rig.ready, isTrue);
        expect(rig.engine.historyPausedForClock, isFalse);
        expect(
          rig.count(Cmd.sendHistoricalData),
          1,
          reason:
              'the initial drain went out — a stale suspect verdict '
              'would have deferred it',
        );
        expect(rig.logs.any((l) => l.contains('DEFERRED')), isFalse);
      });
    });

    test('an unsuccessful but NON-NULL SET_CLOCK response still satisfies '
        'readiness — without clearing the unconfirmed suspect verdict', () {
      fakeAsync((async) {
        // The contract judges the clock step on a non-null
        // RESPONSE OBJECT, not on its result byte: only a null result fails
        // readiness. But a FAILURE result means the strap did NOT take the
        // write, so the phone-suspect history deferral computed off the
        // pre-correction reading is still live evidence and must survive —
        // clearing it is reserved for an ACCEPTED correction.
        final rig = _Rig();
        rig.replyTo = (seq, op) => switch (op) {
          Cmd.getHello => _helloReply(seq, tsSeconds: _wallNow() + 2 * 86400),
          Cmd.setClock => Decoded('cmd_response', {
            'opcode': Cmd.setClock,
            'req_seq': seq,
            'cmd_status': CommandAwaiter.statusFailure,
          }),
          Cmd.getCustomAdvertisingName => _nameReply(seq),
          _ => null,
        };
        expect(
          _run(rig, async),
          isTrue,
          reason:
              'a non-null set-clock response object is treated as '
              'success — only a null result fails readiness',
        );
        expect(rig.ready, isTrue);
        expect(
          rig.count(Cmd.setClock),
          1,
          reason: 'one write, no resend on a FAILURE result',
        );
        expect(
          rig.count(Cmd.getClock),
          0,
          reason:
              'no read-back and no fallback — the FAILURE result changes '
              'nothing about the no-GET_CLOCK rule',
        );
        // The sequence holds around the failed-but-answered write:
        // SET_CLOCK → advertising name → READY.
        expect(
          rig.trace.indexOf('cmd:${Cmd.setClock}'),
          lessThan(rig.trace.indexOf('cmd:${Cmd.getCustomAdvertisingName}')),
        );
        expect(
          rig.trace.indexOf('cmd:${Cmd.getCustomAdvertisingName}'),
          lessThan(rig.trace.indexOf('ready')),
        );
        expect(
          rig.engine.historyPausedForClock,
          isTrue,
          reason:
              'the correction went UNCONFIRMED — the history-safety '
              'deferral keeps the drain parked until a reading agrees',
        );
        expect(
          rig.logs.any((l) => l.contains('clearing the phone-clock')),
          isFalse,
        );
      });
    });

    test('HELLO PENDING → SUCCESS completes the bootstrap', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.replyTo = (seq, op) => switch (op) {
          Cmd.getHello => () {
            // Terminal SUCCESS arrives 800 ms after the PENDING.
            Timer(const Duration(milliseconds: 800), () {
              rig.engine.debugAbsorbDecoded(_helloReply(seq));
            });
            return _helloReply(seq, status: CommandAwaiter.statusPending);
          }(),
          Cmd.getCustomAdvertisingName => _nameReply(seq),
          _ => null,
        };
        expect(
          _run(rig, async),
          isTrue,
          reason:
              'PENDING is non-terminal for GET_HELLO — the await stays '
              'open for the terminal result',
        );
        expect(rig.count(Cmd.getHello), 1, reason: 'no resend on PENDING');
        expect(rig.engine.helloFailureCount, 0);
      });
    });
  });

  group('HELLO is mandatory — every failure mode stops the bootstrap', () {
    void expectNothingAfterHello(_Rig rig) {
      expect(
        rig.trace,
        isNot(contains('native_name')),
        reason: 'no name gate after a failed hello',
      );
      expect(rig.count(Cmd.setClock), 0);
      expect(
        rig.count(Cmd.getClock),
        0,
        reason: 'no GET_CLOCK fallback — hello is mandatory',
      );
      expect(rig.count(Cmd.getCustomAdvertisingName), 0);
      expect(rig.ready, isFalse);
      expect(
        rig.engine.isConnected,
        isFalse,
        reason: 'the failed session is torn down',
      );
    }

    test('timeout: no reply within five seconds', () {
      fakeAsync((async) {
        final rig = _Rig(); // nothing answers
        expect(_run(rig, async, elapse: const Duration(seconds: 10)), isFalse);
        expect(rig.engine.helloFailureCount, 1);
        expectNothingAfterHello(rig);
      });
    });

    test('terminal FAILURE', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, status: CommandAwaiter.statusFailure)
            : null;
        expect(_run(rig, async), isFalse);
        expect(rig.engine.helloFailureCount, 1);
        expectNothingAfterHello(rig);
      });
    });

    test('UNSUPPORTED', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, status: CommandAwaiter.statusUnsupported)
            : null;
        expect(_run(rig, async), isFalse);
        expect(rig.engine.helloFailureCount, 1);
        expectNothingAfterHello(rig);
      });
    });

    test('a SUCCESS whose body never parsed fails the bootstrap', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.replyTo = (seq, op) => op == Cmd.getHello
            ? Decoded('cmd_response', {
                'opcode': Cmd.getHello,
                'req_seq': seq,
                'cmd_status': CommandAwaiter.statusSuccess,
                // no gen5_hello field — the parser rejected the body
              })
            : null;
        expect(
          _run(rig, async),
          isFalse,
          reason:
              'a completed write, and even a SUCCESS status, is not a '
              'hello — only the parsed object counts',
        );
        expect(rig.engine.helloFailureCount, 1);
        expectNothingAfterHello(rig);
      });
    });

    test('a reply with the WRONG SEQUENCE does not satisfy the hello', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.replyTo = (seq, op) =>
            op == Cmd.getHello ? _helloReply(seq + 1) : null;
        expect(_run(rig, async, elapse: const Duration(seconds: 10)), isFalse);
        expect(rig.engine.helloFailureCount, 1);
        expectNothingAfterHello(rig);
      });
    });

    test('a reply with the WRONG OPCODE does not satisfy the hello', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.replyTo = (seq, op) => op == Cmd.getHello
            ? Decoded('cmd_response', {
                'opcode': Cmd.getClock,
                'req_seq': seq,
                'cmd_status': CommandAwaiter.statusSuccess,
              })
            : null;
        expect(_run(rig, async, elapse: const Duration(seconds: 10)), isFalse);
        expect(rig.engine.helloFailureCount, 1);
        expectNothingAfterHello(rig);
      });
    });
  });

  group('the post-HELLO gates', () {
    test('a null Android native name prevents READY', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll();
        rig.nativeName = null;
        expect(_run(rig, async), isFalse);

        expect(rig.ready, isFalse);
        expect(
          rig.count(Cmd.setClock),
          0,
          reason: 'the sequence stops at the name gate',
        );
        expect(rig.count(Cmd.getCustomAdvertisingName), 0);
        expect(
          rig.engine.helloFailureCount,
          0,
          reason:
              'a name-gate failure is a CONNECTION failure, not a '
              'hello-exchange failure — the evidence never counts it there',
        );
        expect(rig.logged('requires a non-null native name'), isTrue);
      });
    });

    test('a cold reconnect reads the NATIVE name for the session\'s remote '
        'id — never flutter_blue_plus\'s platformName cache', () {
      fakeAsync((async) {
        // The fake link's device is built the way a cold-start reconnect
        // builds it — BluetoothDevice.fromId — so its FBP platformName cache
        // is EMPTY by construction. Readiness must come from the injected
        // native getter, asked about this exact remote id.
        final rig = _Rig()..answerAll();
        expect(_run(rig, async), isTrue);
        expect(
          rig.nativeNameQueries,
          ['AA:BB:CC:DD:EE:FF'],
          reason: 'exactly one native read, for the session device',
        );
      });
    });

    test('a partially-alphanumeric serial prevents READY', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll(serial: 'W5-AB12');
        expect(_run(rig, async), isFalse);
        expect(rig.ready, isFalse);
        expect(rig.count(Cmd.setClock), 0);
        expect(rig.count(Cmd.getCustomAdvertisingName), 0);
        expect(rig.logged('identity gate FAILED'), isTrue);
        expect(
          rig.engine.helloFailureCount,
          0,
          reason:
              'an identity failure is a connection failure, not a '
              'hello-exchange failure',
        );
      });
    });

    test('an empty serial prevents READY', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll(serial: '');
        expect(_run(rig, async), isFalse);
        expect(rig.logged('identity gate FAILED'), isTrue);
      });
    });

    test('an empty CPU identity prevents READY', () {
      fakeAsync((async) {
        // The parser hex-encodes the CPU bytes, so a parsed body can only
        // fail this gate when the field is EMPTY — construct that directly.
        final parsed = Gen5HelloInfo.parse(_helloBody(tsSeconds: _wallNow()))!;
        final noCpu = Gen5HelloInfo(
          helloRevision: parsed.helloRevision,
          batteryPct: parsed.batteryPct,
          charging: parsed.charging,
          tsSeconds: parsed.tsSeconds,
          tsSubseconds: parsed.tsSubseconds,
          serial: parsed.serial,
          commitHex: parsed.commitHex,
          cpuHex: '',
          hardwareFamily: parsed.hardwareFamily,
          pcbaRevision: parsed.pcbaRevision,
          opticalDiscriminator: parsed.opticalDiscriminator,
          fwMajor: parsed.fwMajor,
          fwMinor: parsed.fwMinor,
          fwBuild: parsed.fwBuild,
          fwUnreleased: parsed.fwUnreleased,
          sigprocMajor: parsed.sigprocMajor,
          sigprocMinor: parsed.sigprocMinor,
          sigprocPatch: parsed.sigprocPatch,
          hrBroadcast: parsed.hrBroadcast,
          wristOn: parsed.wristOn,
          errorByte: parsed.errorByte,
        );
        final rig = _Rig();
        rig.replyTo = (seq, op) => switch (op) {
          Cmd.getHello => _helloReply(seq, hello: noCpu),
          Cmd.getCustomAdvertisingName => _nameReply(seq),
          _ => null,
        };
        expect(_run(rig, async), isFalse);
        expect(rig.logged('identity gate FAILED'), isTrue);
      });
    });

    test(
      'an all-zero serial passes the gate and keeps the EEPROM diagnostic',
      () {
        fakeAsync((async) {
          final rig = _Rig()..answerAll(serial: '0000000000');
          expect(
            _run(rig, async),
            isTrue,
            reason:
                'all-zero fully matches [A-Za-z0-9]+ — the official rule '
                'accepts it',
          );
          expect(rig.logged('EEPROM'), isTrue);
          expect(
            rig.engine.offloadSnapshot['hello_serial_eeprom_failure'],
            isTrue,
          );
        });
      },
    );
  });

  group('the hello-failure counter and the bond reset', () {
    test('the fifth consecutive failure removes the bond exactly once, '
        'resets the counter, and starts no nested reconnect', () {
      fakeAsync((async) {
        final rig = _Rig(); // nothing ever answers the hello
        for (var i = 1; i <= 4; i++) {
          expect(
            _run(rig, async, elapse: const Duration(seconds: 10)),
            isFalse,
          );
          expect(
            rig.engine.helloFailureCount,
            i,
            reason: 'the count survives reconnect attempts',
          );
          expect(rig.bondRemovals, 0);
          // The reconnect owner (AppState) would build the next session; the
          // engine itself must not. Model the owner's next attempt:
          rig.engine.debugInstallFakeLink(
            band: BandProfile.gen5,
            onWrite: (frame) async {
              final inner = parseFrame(frame, profile: BandProfile.gen5)!.inner;
              rig.commands.add((
                seq: inner[1],
                opcode: inner[2],
                body: inner.sublist(3),
              ));
              rig.trace.add('cmd:${inner[2]}');
              return true;
            },
          );
        }
        final helloWritesBefore = rig.count(Cmd.getHello);
        expect(_run(rig, async, elapse: const Duration(seconds: 10)), isFalse);
        expect(rig.bondRemovals, 1, reason: 'exactly one bond removal');
        expect(
          rig.engine.helloFailureCount,
          0,
          reason: 'the fifth failure resets the counter',
        );
        expect(
          rig.count(Cmd.getHello),
          helloWritesBefore + 1,
          reason:
              'no nested reconnect: the failed bootstrap wrote its one '
              'hello and stopped — the next attempt belongs to the '
              'existing reconnect owner',
        );
        expect(rig.engine.isConnected, isFalse);
      });
    });

    test('a successful complete bootstrap clears earlier failures only at '
        'READY', () {
      fakeAsync((async) {
        final rig = _Rig();
        // Three failed exchanges first.
        rig.replyTo = (seq, op) => op == Cmd.getHello
            ? _helloReply(seq, status: CommandAwaiter.statusFailure)
            : null;
        for (var i = 0; i < 3; i++) {
          rig.engine.debugReadGen5Hello();
          async.flushMicrotasks();
        }
        expect(rig.engine.helloFailureCount, 3);

        // Now a working strap — but with the advertising name unanswered, so
        // there is a window where hello has landed and READY has not.
        rig.replyTo = (seq, op) => switch (op) {
          Cmd.getHello => _helloReply(seq),
          Cmd.setClock => _clockAck(seq),
          _ => null,
        };
        bool? ok;
        rig.engine.debugConnectGen5Official(_Ops(rig)).then((v) => ok = v);
        async.elapse(const Duration(seconds: 3));
        expect(ok, isNull, reason: 'still inside the adv-name await');
        expect(
          rig.engine.helloFailureCount,
          3,
          reason:
              'the hello object arriving did NOT clear the count — '
              'only READY does',
        );
        async.elapse(const Duration(seconds: 4));
        expect(ok, isTrue);
        expect(rig.ready, isTrue);
        expect(
          rig.engine.helloFailureCount,
          0,
          reason: 'cleared at the READY transition',
        );
      });
    });
  });

  group('bond, PHY, discovery and registration', () {
    test('a failed bond prevents subscriptions, HELLO and READY', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll();
        expect(_run(rig, async, ops: _Ops(rig, bondFails: true)), isFalse);

        expect(
          rig.trace.where((t) => t.startsWith('sub:')),
          isEmpty,
          reason: 'no notification registration after a failed bond',
        );
        expect(
          rig.commands,
          isEmpty,
          reason: 'no HELLO — no encrypted command at all',
        );
        expect(rig.ready, isFalse);
        expect(
          rig.engine.state.needsRepairGuide,
          isTrue,
          reason: 'the existing repair guidance surfaces',
        );
        expect(
          rig.engine.state.bondRefusals,
          1,
          reason: 'a refused createBond() IS the thing the refusal counter '
              'and its give-up threshold are for',
        );
        expect(
          rig.engine.isConnected,
          isFalse,
          reason: 'the failed session is torn down cleanly',
        );
      });
    });

    test('a bond-state read that never answers cannot park the bootstrap', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll();
        expect(_run(rig, async, ops: _Ops(rig, bondCheckHangs: true)), isFalse);

        expect(rig.trace, contains('bond:check'));
        expect(
          rig.trace,
          isNot(contains('bond:create')),
          reason: 'the read never resolved, so nothing decided to bond',
        );
        expect(
          rig.trace.where((t) => t.startsWith('sub:')),
          isEmpty,
          reason: 'no registration behind an unfinished bond step',
        );
        expect(rig.commands, isEmpty);
        expect(rig.ready, isFalse);
        expect(
          rig.engine.isConnected,
          isFalse,
          reason: 'the bound expired, which tore the session down — without '
              'it the claim stays live forever and every later headless '
              'drain yields to it',
        );
        // AND IT IS NOT A BOND REFUSAL. A stalled `getBondState` is a
        // phone-stack condition; counted here it would walk the give-up
        // threshold and then tell the user to remove a bond that is fine.
        expect(
          rig.engine.state.bondRefusals,
          0,
          reason: 'the band never refused anything — it was never asked',
        );
        expect(
          rig.engine.state.needsRepairGuide,
          isFalse,
          reason: '"remove the bond in system Bluetooth settings" is not the '
              'remedy for a bond-state read that never answered',
        );
        expect(rig.engine.state.autoReconnectPaused, isFalse);
      });
    });

    test('an already-bonded device does not create another bond', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll();
        expect(_run(rig, async, ops: _Ops(rig, alreadyBonded: true)), isTrue);
        expect(rig.trace, contains('bond:check'));
        expect(rig.trace, isNot(contains('bond:create')));
      });
    });

    test('a failed PHY preference is logged, non-fatal, and still ordered '
        'before discovery', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll();
        expect(
          _run(rig, async, ops: _Ops(rig, phyFails: true)),
          isTrue,
          reason: 'LE 2M is a preference; its failure never faults setup',
        );
        expect(
          rig.trace.indexOf('phy'),
          lessThan(rig.trace.indexOf('discover')),
        );
        expect(rig.logged('LE 2M PHY preference failed'), isTrue);
      });
    });

    test('a missing required service/characteristic prevents READY', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll();
        expect(_run(rig, async, ops: _Ops(rig, discoveryFails: true)), isFalse);
        expect(rig.ready, isFalse);
        expect(rig.commands, isEmpty);
        expect(
          rig.logged('required band service or characteristic missing'),
          isTrue,
        );
      });
    });

    test('a failed required notification registration prevents READY', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll();
        expect(
          _run(rig, async, ops: _Ops(rig, failSubscribe: {'events'})),
          isFalse,
        );
        expect(rig.ready, isFalse);
        expect(rig.commands, isEmpty, reason: 'no HELLO after a failed CCC');
        expect(rig.logged('required notification registration failed'), isTrue);
      });
    });

    test('an absent optional Memfault characteristic never blocks READY', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll();
        expect(
          _run(rig, async, ops: _Ops(rig, memfaultPresent: false)),
          isTrue,
          reason:
              'Memfault (0007) is optional in the retained fixture — '
              'its absence must not fault setup',
        );
        expect(rig.ready, isTrue);
        expect(rig.logged('not required; setup continues'), isTrue);
      });
    });

    test('a Memfault chunk counts as LIVENESS and lands in the counters', () {
      // Through the same _onMemfaultChunk the real notification listener
      // uses — a strap volunteering crash data must not look silent to the
      // staleness fuse, or a quiet-but-alive link gets bounced.
      final rig = _Rig();
      expect(
        rig.engine.sinceLastRx.inDays,
        greaterThan(365),
        reason: 'a fresh engine has never received anything',
      );

      rig.engine.debugIngestMemfaultChunk(const [1, 2, 3]);
      expect(
        rig.engine.sinceLastRx.inSeconds,
        lessThan(5),
        reason: 'the chunk advanced the liveness clock',
      );
      expect(rig.engine.offloadSnapshot['memfault_chunks'], 1);
      expect(rig.engine.offloadSnapshot['memfault_bytes'], 3);
      expect(rig.logged('collected only'), isTrue);

      rig.engine.debugIngestMemfaultChunk(const [4, 5]);
      expect(rig.engine.offloadSnapshot['memfault_chunks'], 2);
      expect(rig.engine.offloadSnapshot['memfault_bytes'], 5);
    });
  });

  group('the connect route is chosen before discovery', () {
    // The production routing decision _doConnect makes — an unknown/null
    // generation must NOT bypass the official sequence. A pairing upgraded
    // from an older Edge build (no persisted generation) and a headless
    // engine both arrive here with null.
    test('only an explicit gen4 hint takes the legacy order', () {
      expect(connectRouteFor('gen4'), ConnectRoute.gen4Legacy);
      expect(connectRouteFor('gen5'), ConnectRoute.gen5Official);
      expect(
        connectRouteFor(null),
        ConnectRoute.gen5Official,
        reason:
            'unknown probes gen5-first; discovery identifies the band '
            'and a discovered gen4 falls back to the unchanged legacy flow',
      );
      expect(
        connectRouteFor('garbled'),
        ConnectRoute.gen5Official,
        reason:
            'a corrupted stored value must not demote a gen5 band to '
            'the wrong bond position',
      );
    });
  });

  group('an advertising-name failure is awaited but never a gate', () {
    test('a FAILURE reply is logged and the bootstrap reaches READY', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.replyTo = (seq, op) => switch (op) {
          Cmd.getHello => _helloReply(seq),
          Cmd.getCustomAdvertisingName => Decoded('cmd_response', {
            'opcode': Cmd.getCustomAdvertisingName,
            'req_seq': seq,
            'cmd_status': CommandAwaiter.statusFailure,
          }),
          _ => null,
        };
        expect(_run(rig, async), isTrue);
        expect(rig.ready, isTrue);
        expect(rig.logged('not a readiness gate'), isTrue);
      });
    });

    test('an unanswered read holds READY for its await, then continues', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.replyTo = (seq, op) => switch (op) {
          Cmd.getHello => _helloReply(seq),
          _ => null,
        };
        bool? ok;
        rig.engine.debugConnectGen5Official(_Ops(rig)).then((v) => ok = v);
        async.elapse(const Duration(seconds: 3));
        expect(rig.ready, isFalse, reason: 'the await completes BEFORE READY');
        async.elapse(const Duration(seconds: 5));
        expect(ok, isTrue);
        expect(rig.ready, isTrue);
      });
    });
  });

  group('session replacement mid-bootstrap', () {
    test(
      'a stale bootstrap cannot tear down or write into the newer session',
      () {
        fakeAsync((async) {
          final rig = _Rig(); // hello never answered → 5 s await in flight
          bool? ok;
          rig.engine.debugConnectGen5Official(_Ops(rig)).then((v) => ok = v);
          async.elapse(const Duration(seconds: 2));
          expect(rig.count(Cmd.getHello), 1, reason: 'mid-hello await');

          rig.supersedeSession();
          async.elapse(const Duration(seconds: 10));

          expect(ok, isFalse);
          expect(
            rig.afterSupersede,
            isEmpty,
            reason: 'the stale bootstrap never writes onto the new link',
          );
          expect(rig.logged('abandoning setup'), isTrue);
          expect(rig.ready, isFalse);
        });
      },
    );

    test('a session replaced during the pre-registration delay stops the '
        'stale bootstrap before any registration', () {
      fakeAsync((async) {
        final rig = _Rig()..answerAll();
        final ops = _Ops(rig);
        bool? ok;
        rig.engine.debugConnectGen5Official(ops).then((v) => ok = v);
        // Let it get past the bond into the 600 ms pre-registration sleep.
        async.elapse(const Duration(milliseconds: 100));
        expect(rig.trace, contains('bond:create'));
        rig.supersedeSession();
        async.elapse(const Duration(seconds: 10));

        expect(ok, isFalse);
        expect(
          rig.trace.where((t) => t.startsWith('sub:')),
          isEmpty,
          reason: 'no registration on a session that is gone',
        );
        expect(rig.afterSupersede, isEmpty);
      });
    });
  });

  group('the advertised generation hint is by service UUID only', () {
    test('a supported advertised service names a generation; nothing else '
        'does', () {
      expect(
        ScanAcceptPolicy.accepts(['FD4B0001-CCE1-4033-93CE-002D5875F58A']),
        'gen5',
      );
      expect(
        ScanAcceptPolicy.accepts(['61080001-8d6d-82b8-614a-1c8cb0f8dcc6']),
        'gen4',
      );
      expect(
        ScanAcceptPolicy.accepts([]),
        isNull,
        reason:
            'no advertised WHOOP service, no HINT — by construction there is '
            'no name parameter to fall back to. Acceptance is a separate, '
            'deliberately broader decision (#255) and is not this policy.',
      );
      expect(
        ScanAcceptPolicy.accepts(['0000180f-0000-1000-8000-00805f9b34fb']),
        isNull,
      );
    });
  });
}
