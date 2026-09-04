// Live HR / IMU ownership reconciler (discussion #287), driven end to end
// through the engine's fake-link seam: which opcodes go out for which owner
// set, in what order, and what happens when a write is slow, fails, or lands
// after the link it was written to is gone.
//
// HR is opcode 3 on both generations. The high-rate bundle is IMU opcode 106
// (0x6A) alone on gen5 and R10/R11 (0x3F) + IMU + optical (0x6B/0x6C) on
// gen4, whose byte sequences must stay exactly what the old enable / HR-only /
// disable methods wrote.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

typedef _Write = ({int opcode, List<int> body});

const _hr = Cmd.toggleRealtimeHr; // 0x03
const _imu = Cmd.toggleImuMode; // 0x6A
const _r10 = Cmd.sendR10R11Realtime; // 0x3F
const _optSave = Cmd.enableOpticalData; // 0x6B
const _optMode = Cmd.toggleOpticalMode; // 0x6C

const _fgGait = LiveStreamOwners(
  activeWorkout: true,
  foregroundGaitWorkout: true,
  foreground: true,
);
const _hrView = LiveStreamOwners(visibleLiveHrView: true, foreground: true);

/// A connected-looking link with no radio behind it.
///
/// The owner set is a mutable field the engine reads through its provider
/// callback, exactly as AppState supplies it. Writes are recorded per link
/// (a superseding link gets its own list) so a test can prove that a stale
/// tail never reaches a replacement session.
class _Rig {
  final BandProfile band;
  final logs = <String>[];
  late final BleEngine engine;
  LiveStreamOwners owners = LiveStreamOwners.none;

  /// Every write, on every link, in order.
  final all = <_Write>[];

  /// Writes on the CURRENT link only (reset by [newLink]).
  var link = <_Write>[];

  /// Park the NEXT write of an opcode until the completer completes. The park
  /// happens inside the write hook, i.e. inside the engine's write chain, so
  /// everything queued behind it waits too — the same shape as a slow GATT
  /// acknowledgement.
  final _gates = <int, Completer<void>>{};

  /// Opcodes whose writes report failure.
  final failing = <int>{};

  _Rig({this.band = BandProfile.gen5}) {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
      liveOwners: () => owners,
    );
    newLink();
  }

  /// Install a fresh fake session (after a drop, or to supersede one).
  /// [listening] = READY; a link still bootstrapping is not written to.
  void newLink({BandProfile? band, bool listening = true, bool? liveReady}) {
    link = <_Write>[];
    final sink = link;
    final profile = band ?? this.band;
    engine.debugInstallFakeLink(
      band: profile,
      listening: listening,
      liveReady: liveReady,
      onWrite: (Uint8List frame) async {
        final inner = parseFrame(frame, profile: profile)!.inner;
        final opcode = inner[2];
        final gate = _gates.remove(opcode);
        if (gate != null) await gate.future;
        final w = (opcode: opcode, body: inner.sublist(3));
        sink.add(w);
        all.add(w);
        return !failing.contains(opcode);
      },
    );
  }

  Completer<void> park(int opcode) => _gates[opcode] = Completer<void>();

  List<int> get opcodes => link.map((w) => w.opcode).toList();

  /// `(opcode, on/off)` pairs. The inner payload is padded, so the on/off
  /// byte is picked by opcode: `[rev1, on]` for the optical toggles and the
  /// gen5 IMU toggle, a bare `[on]` for everything else.
  List<(int, int)> get ops => [
        for (final w in link)
          (
            w.opcode,
            w.opcode == _optSave ||
                    w.opcode == _optMode ||
                    (w.opcode == _imu && band.isGen5)
                ? w.body[1]
                : w.body[0],
          ),
      ];

  Future<void> reconcile() => engine.reconcileLiveStreams();

  Future<void> setOwners(LiveStreamOwners o) {
    owners = o;
    return reconcile();
  }

  /// Let the engine start a pass and reach the write hook.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  group('gen5 — owner → opcode table', () {
    test('ordinary READY with no owner writes nothing', () async {
      final rig = _Rig();
      await rig.reconcile();
      expect(rig.opcodes, isEmpty);
      expect(rig.engine.liveEnabled, isFalse);
    });

    test('ordinary foreground connection is not an owner on gen5', () async {
      final rig = _Rig();
      await rig.setOwners(const LiveStreamOwners(foreground: true));
      expect(rig.opcodes, isEmpty);
    });

    test('visible live-HR view: HR only', () async {
      final rig = _Rig();
      await rig.setOwners(_hrView);
      expect(rig.ops, [(_hr, 1)]);
      expect(rig.engine.debugLiveApplied, const LiveStreamIntent(hr: true, imu: false));
    });

    test('breathing session/window: HR only', () async {
      final rig = _Rig();
      await rig.setOwners(const LiveStreamOwners(breathing: true, foreground: true));
      expect(rig.ops, [(_hr, 1)]);
    });

    test('foreground gait workout: HR ON then IMU ON, rev-1 body, no optical', () async {
      final rig = _Rig();
      await rig.setOwners(_fgGait);
      expect(rig.opcodes, [_hr, _imu]);
      expect(rig.link[0].body.first, 0x01);
      expect(rig.link[1].body.sublist(0, 2), [revision1, 0x01]);
      expect(rig.opcodes, isNot(contains(_optSave)));
      expect(rig.opcodes, isNot(contains(_optMode)));
      expect(rig.engine.debugLiveApplied, const LiveStreamIntent(hr: true, imu: true));
    });

    test('non-gait workout (manual strength): HR only', () async {
      final rig = _Rig();
      await rig.setOwners(const LiveStreamOwners(activeWorkout: true, foreground: true));
      expect(rig.ops, [(_hr, 1)]);
    });

    test('bounded movement-sampling window: IMU only; outside it, nothing', () async {
      final rig = _Rig();
      await rig.setOwners(const LiveStreamOwners(movementSampling: true, foreground: true));
      expect(rig.ops, [(_imu, 1)]);
      await rig.setOwners(const LiveStreamOwners(foreground: true));
      expect(rig.ops, [(_imu, 1), (_imu, 0)]);
      expect(rig.engine.liveEnabled, isFalse);
    });

    test('background gait workout: HR requested, IMU off', () async {
      final rig = _Rig();
      await rig.setOwners(const LiveStreamOwners(activeWorkout: true));
      expect(rig.ops, [(_hr, 1)]);
    });

    test('iOS background with no other owner: HR only', () async {
      final rig = _Rig();
      await rig.setOwners(const LiveStreamOwners(iosBackgroundKeepalive: true));
      expect(rig.ops, [(_hr, 1)]);
    });

    test('Android background with no owner: everything off, bundle before HR', () async {
      final rig = _Rig();
      await rig.setOwners(_fgGait);
      await rig.setOwners(LiveStreamOwners.none);
      expect(rig.ops, [(_hr, 1), (_imu, 1), (_imu, 0), (_hr, 0)]);
      expect(rig.engine.liveEnabled, isFalse);
      expect(rig.opcodes, isNot(contains(_optSave)));
      expect(rig.opcodes, isNot(contains(_optMode)));
    });

    test('marginal-radio fallback drops an applied IMU on the next pass', () async {
      final rig = _Rig();
      await rig.setOwners(_fgGait);
      rig.engine.state.standardHrFallback = true;
      await rig.reconcile();
      expect(rig.ops, [(_hr, 1), (_imu, 1), (_imu, 0)]);
      // An explicit user action clears it and re-arms.
      await rig.engine.clearRadioFallbackAndReconcile();
      expect(rig.engine.state.standardHrFallback, isFalse);
      expect(rig.ops.last, (_imu, 1));
    });
  });

  group('overlapping owners', () {
    test('two HR owners: HR goes off only after the last one leaves', () async {
      final rig = _Rig();
      await rig.setOwners(const LiveStreamOwners(activeWorkout: true, breathing: true));
      expect(rig.ops, [(_hr, 1)]);
      await rig.setOwners(const LiveStreamOwners(activeWorkout: true));
      expect(rig.ops, [(_hr, 1)], reason: 'the workout still owns HR');
      await rig.setOwners(LiveStreamOwners.none);
      expect(rig.ops, [(_hr, 1), (_hr, 0)]);
    });

    test('two IMU owners: IMU goes off only after the last one leaves', () async {
      final rig = _Rig();
      await rig.setOwners(const LiveStreamOwners(
        activeWorkout: true,
        foregroundGaitWorkout: true,
        movementSampling: true,
        foreground: true,
      ));
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
      await rig.setOwners(const LiveStreamOwners(movementSampling: true, foreground: true));
      expect(rig.ops, [(_hr, 1), (_imu, 1), (_hr, 0)], reason: 'IMU still owned');
      await rig.setOwners(const LiveStreamOwners(foreground: true));
      expect(rig.ops.last, (_imu, 0));
    });
  });

  group('transitions under delayed writes', () {
    test('close/reopen during a delayed OFF converges on the new owner', () async {
      final rig = _Rig();
      await rig.setOwners(_hrView);
      final gate = rig.park(_hr);
      rig.owners = LiveStreamOwners.none;
      final off = rig.reconcile(); // HR OFF parks in the hook
      await rig.settle();
      rig.owners = _hrView; // a new owner arrives while OFF is in flight
      final on = rig.reconcile(); // coalesces behind the running pass
      gate.complete();
      await Future.wait([off, on]);
      expect(rig.ops, [(_hr, 1), (_hr, 0), (_hr, 1)]);
      expect(rig.engine.debugLiveApplied.hr, isTrue);
    });

    test('rapid owner flips during a delayed write converge to the newest', () async {
      final rig = _Rig();
      final gate = rig.park(_hr);
      rig.owners = _hrView;
      final first = rig.reconcile(); // HR ON parks
      await rig.settle();
      rig.owners = LiveStreamOwners.none;
      unawaited(rig.reconcile());
      rig.owners = _hrView;
      unawaited(rig.reconcile());
      rig.owners = LiveStreamOwners.none;
      final last = rig.reconcile();
      gate.complete();
      await Future.wait([first, last]);
      expect(rig.ops, [(_hr, 1), (_hr, 0)]);
      expect(rig.engine.liveEnabled, isFalse);
    });

    test('a coalesced caller\'s await is a barrier for the pass that sees it', () async {
      final rig = _Rig();
      final gate = rig.park(_hr);
      rig.owners = _hrView;
      unawaited(rig.reconcile());
      await rig.settle();
      rig.owners = LiveStreamOwners.none;
      final done = rig.reconcile();
      var completed = false;
      unawaited(done.then((_) => completed = true));
      await rig.settle();
      expect(completed, isFalse, reason: 'still parked');
      gate.complete();
      await done;
      expect(rig.ops, [(_hr, 1), (_hr, 0)]);
    });
  });

  group('failed writes', () {
    test('failed ON: applied stays off, and a later pass retries', () async {
      final rig = _Rig();
      rig.failing.add(_hr);
      await rig.setOwners(_hrView);
      expect(rig.ops, [(_hr, 1)]);
      expect(rig.engine.liveEnabled, isFalse, reason: 'never claimed applied');
      rig.failing.clear();
      await rig.reconcile();
      expect(rig.ops, [(_hr, 1), (_hr, 1)]);
      expect(rig.engine.debugLiveApplied.hr, isTrue);
    });

    test('failed HR ON then the owner leaves: HR OFF is still written', () async {
      final rig = _Rig();
      rig.failing.add(_hr);
      await rig.setOwners(_hrView);
      rig.failing.clear();
      await rig.setOwners(LiveStreamOwners.none);
      expect(rig.ops, [(_hr, 1), (_hr, 0)],
          reason: 'a timed-out ON may have landed; the dirty bit replays OFF');
    });

    test('failed HR OFF then a new owner: HR ON is re-sent', () async {
      final rig = _Rig();
      await rig.setOwners(_hrView);
      rig.failing.add(_hr);
      await rig.setOwners(LiveStreamOwners.none);
      rig.failing.clear();
      await rig.setOwners(_hrView);
      expect(rig.ops, [(_hr, 1), (_hr, 0), (_hr, 1)]);
      expect(rig.engine.debugLiveApplied.hr, isTrue);
    });

    test('a nudge during a failed write is honoured in the same pass', () async {
      final rig = _Rig();
      rig.failing.add(_hr);
      final gate = rig.park(_hr);
      rig.owners = _hrView;
      final first = rig.reconcile();
      await rig.settle();
      rig.owners = LiveStreamOwners.none; // arrives while the ON is failing
      final second = rig.reconcile();
      gate.complete();
      await Future.wait([first, second]);
      expect(rig.ops, [(_hr, 1), (_hr, 0)],
          reason: 'the pass recomputed after the failure instead of exiting');
    });
  });

  group('link replacement', () {
    test('a step completing after teardown does not touch the new link', () async {
      final rig = _Rig();
      final gate = rig.park(_imu);
      rig.owners = _fgGait;
      final pass = rig.reconcile(); // HR ON lands, IMU ON parks
      await rig.settle();
      await Future<void>.delayed(const Duration(milliseconds: 150)); // past the 100 ms gap
      final oldLink = rig.link;
      await rig.engine.debugDropLink();
      expect(rig.engine.liveEnabled, isFalse, reason: 'applied cleared by teardown');
      rig.newLink();
      gate.complete();
      await pass;
      expect(oldLink.map((w) => w.opcode), [_hr, _imu]);
      expect(rig.logs, contains(contains('completed after teardown — discarded')),
          reason: 'the stale IMU completion was not recorded as applied');
      // The still-running pass then gives the replacement link its own clean
      // pass from the current owners — HR first, from scratch — rather than
      // inheriting the old link's half-applied state.
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
      expect(rig.engine.debugLiveApplied, const LiveStreamIntent(hr: true, imu: true));
    });

    test('a replacement link that has not reached READY is not written to', () async {
      final rig = _Rig();
      final gate = rig.park(_imu);
      rig.owners = _fgGait;
      final pass = rig.reconcile();
      await rig.settle();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await rig.engine.debugDropLink();
      rig.newLink(listening: false); // physically connected, mid-bootstrap
      gate.complete();
      await pass;
      expect(rig.link, isEmpty,
          reason: 'no live toggle may enter the bootstrap sequence');
      await rig.reconcile(); // an owner nudge mid-bootstrap: same
      expect(rig.link, isEmpty);
      rig.newLink(); // READY
      await rig.reconcile();
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
    });

    test('a listening link whose INIT sequence is still going out is not '
        'written to either', () async {
      final rig = _Rig();
      rig.newLink(listening: true, liveReady: false); // between INIT packets
      await rig.setOwners(_fgGait);
      expect(rig.link, isEmpty,
          reason: 'no live toggle may interleave with the INIT packets');
      rig.newLink(); // INIT done
      await rig.reconcile();
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
    });

    test('reconnect re-applies the current owners', () async {
      final rig = _Rig();
      await rig.setOwners(_fgGait);
      await rig.engine.debugDropLink();
      rig.newLink();
      expect(rig.engine.liveEnabled, isFalse);
      await rig.reconcile();
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
    });

    test('a delayed gen4 bundle never continues onto a replacement gen5 link', () async {
      final rig = _Rig(band: BandProfile.gen4);
      final gate = rig.park(_r10); // park inside the ON bundle
      rig.owners = const LiveStreamOwners(foreground: true);
      final pass = rig.reconcile();
      await rig.settle();
      await Future<void>.delayed(const Duration(milliseconds: 150)); // reach R10
      await rig.engine.debugDropLink();
      rig.newLink(band: BandProfile.gen5);
      gate.complete();
      await pass;
      expect(rig.link, isEmpty);
      expect(rig.all.map((w) => w.opcode), [_hr, _r10],
          reason: 'IMU/optical tail aborted at the first stale check');
    });
  });

  group('disconnect()', () {
    test('turns applied streams off before tearing down', () async {
      final rig = _Rig();
      await rig.setOwners(_fgGait);
      await rig.engine.disconnect();
      expect(rig.ops, [(_hr, 1), (_imu, 1), (_imu, 0), (_hr, 0)]);
      expect(rig.engine.liveEnabled, isFalse);
    });

    test('during a delayed ON: converges to OFF, nothing re-arms, and the '
        'shutdown latch is released for the next link', () async {
      final rig = _Rig();
      final gate = rig.park(_hr);
      rig.owners = _hrView;
      unawaited(rig.reconcile());
      await rig.settle();
      final closing = rig.engine.disconnect();
      await rig.settle();
      gate.complete();
      await closing;
      expect(rig.ops, [(_hr, 1), (_hr, 0)]);
      expect(rig.engine.liveEnabled, isFalse);
      // The owner is still there; a fresh link arms again.
      rig.newLink();
      await rig.reconcile();
      expect(rig.ops, [(_hr, 1)]);
    });

    test('during a failed ON: the shutdown intent is processed in the same pass', () async {
      final rig = _Rig();
      rig.failing.add(_hr);
      final gate = rig.park(_hr);
      rig.owners = _hrView;
      unawaited(rig.reconcile());
      await rig.settle();
      final closing = rig.engine.disconnect();
      await rig.settle();
      gate.complete();
      await closing;
      expect(rig.ops, [(_hr, 1), (_hr, 0)],
          reason: 'OFF attempted for the dirty bit before teardown');
    });

    test('during a delayed OFF: waits for it, writes nothing more', () async {
      final rig = _Rig();
      await rig.setOwners(_hrView);
      final gate = rig.park(_hr);
      rig.owners = LiveStreamOwners.none;
      unawaited(rig.reconcile());
      await rig.settle();
      final closing = rig.engine.disconnect();
      await rig.settle();
      gate.complete();
      await closing;
      expect(rig.ops, [(_hr, 1), (_hr, 0)]);
    });
  });

  group('keep-alive reassert', () {
    test('re-sends what is applied; HR only when no reading is flowing', () async {
      final rig = _Rig();
      await rig.setOwners(_fgGait);
      await rig.engine.debugReassertLiveStreams();
      expect(rig.ops, [(_hr, 1), (_imu, 1), (_imu, 1), (_hr, 1)]);
      rig.engine.state.liveHrAt = DateTime.now().millisecondsSinceEpoch;
      await rig.engine.debugReassertLiveStreams();
      expect(rig.ops.last, (_imu, 1), reason: 'HR is delivering: not re-sent');
    });

    test('a keep-alive reassert during a failing pass does not restart it', () async {
      final rig = _Rig();
      rig.failing.add(_hr);
      final gate = rig.park(_hr);
      rig.owners = _hrView;
      final pass = rig.reconcile();
      await rig.settle();
      final tick = rig.engine.debugReassertLiveStreams(); // the 30 s tick
      gate.complete();
      await Future.wait([pass, tick]);
      expect(rig.ops, [(_hr, 1)],
          reason: 'the failed ON is retried by a LATER tick, not re-run by '
              'the tick that overlapped it');
      expect(rig.engine.liveEnabled, isFalse);
      rig.failing.clear();
      rig.engine.state.liveHrAt = DateTime.now().millisecondsSinceEpoch;
      await rig.engine.debugReassertLiveStreams();
      expect(rig.ops, [(_hr, 1), (_hr, 1)], reason: 'the later tick retries');
    });

    test('nothing applied: nothing re-sent', () async {
      final rig = _Rig();
      await rig.engine.debugReassertLiveStreams();
      expect(rig.opcodes, isEmpty);
    });

    test('a teardown between the two re-arms stops the HR write', () async {
      final rig = _Rig();
      await rig.setOwners(_fgGait);
      final gate = rig.park(_imu);
      final pass = rig.engine.debugReassertLiveStreams();
      await rig.settle();
      await rig.engine.debugDropLink();
      rig.newLink();
      gate.complete();
      await pass;
      expect(rig.link, isEmpty);
      expect(rig.all.map((w) => w.opcode).where((o) => o == _hr).length, 1,
          reason: 'only the original HR ON — the reassert HR write was aborted');
    });
  });

  group('link priority follows desired IMU, not just applied', () {
    test('high as soon as IMU is desired, until the OFF has landed', () async {
      final rig = _Rig();
      expect(rig.engine.linkPriorityForCurrentState(), LinkPriority.balanced);
      final on = rig.park(_imu);
      rig.owners = _fgGait;
      final pass = rig.reconcile();
      await rig.settle();
      expect(rig.engine.linkPriorityForCurrentState(), LinkPriority.high,
          reason: 'requested before the flood starts');
      on.complete();
      await pass;
      final off = rig.park(_imu);
      rig.owners = LiveStreamOwners.none;
      final pass2 = rig.reconcile();
      await rig.settle();
      expect(rig.engine.linkPriorityForCurrentState(), LinkPriority.high,
          reason: 'held until the OFF has landed');
      off.complete();
      await pass2;
      expect(rig.engine.linkPriorityForCurrentState(), LinkPriority.balanced);
    });
  });

  group('gen4 — byte sequences unchanged', () {
    const fg = LiveStreamOwners(foreground: true);
    const iosBg = LiveStreamOwners(iosBackgroundKeepalive: true);

    test('foreground on a fresh link: HR, R10/R11, IMU, optical ON', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(fg);
      expect(rig.ops, [(_hr, 1), (_r10, 1), (_imu, 1), (_optSave, 1)]);
      expect(rig.link[3].body.sublist(0, 2), [revision1, 0x01]);
      expect(rig.link[2].body.first, 0x01, reason: 'gen4 IMU body is a bare byte');
    });

    test('full → off: optical mode, optical save, R10/R11, IMU, then HR', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(fg);
      await rig.setOwners(LiveStreamOwners.none);
      expect(rig.ops.sublist(4), [(_optMode, 0), (_optSave, 0), (_r10, 0), (_imu, 0), (_hr, 0)]);
      expect(rig.link[4].body.sublist(0, 2), [revision1, 0x00]);
    });

    test('full → HR-only (backgrounding on iOS): the old HR-only sequence', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(fg);
      await rig.setOwners(iosBg);
      expect(rig.ops.sublist(4), [(_hr, 1), (_optMode, 0), (_optSave, 0), (_r10, 0), (_imu, 0)]);
      expect(rig.engine.debugLiveApplied, const LiveStreamIntent(hr: true, imu: false));
    });

    test('fresh link, HR-only wanted (iOS background cold launch): HR ON then '
        'the defensive OFF tail — R10/R11 OFF persists on the strap', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(iosBg);
      expect(rig.ops, [(_hr, 1), (_optMode, 0), (_optSave, 0), (_r10, 0), (_imu, 0)]);
      // Once known, a second pass is silent.
      await rig.reconcile();
      expect(rig.ops.length, 5);
    });

    test('fresh link, nothing wanted (Android background): silent', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(LiveStreamOwners.none);
      expect(rig.opcodes, isEmpty);
    });

    test('background workout on a fresh link: HR on, defensive bundle off', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(const LiveStreamOwners(activeWorkout: true));
      expect(rig.ops, [(_hr, 1), (_optMode, 0), (_optSave, 0), (_r10, 0), (_imu, 0)]);
      expect(rig.engine.debugLiveApplied.imu, isFalse);
    });

    test('partial ON failure then owners gone: the whole OFF bundle is replayed', () async {
      final rig = _Rig(band: BandProfile.gen4);
      rig.failing.add(_r10);
      await rig.setOwners(fg);
      expect(rig.ops, [(_hr, 1), (_r10, 1), (_imu, 1), (_optSave, 1)],
          reason: 'the bundle runs to the end even when one write fails');
      expect(rig.engine.debugLiveApplied.imu, isFalse, reason: 'never claimed');
      rig.failing.clear();
      await rig.setOwners(LiveStreamOwners.none);
      expect(rig.ops.sublist(4), [(_optMode, 0), (_optSave, 0), (_r10, 0), (_imu, 0), (_hr, 0)],
          reason: 'dirty replays OFF even though nothing is desired');
    });

    test('partial OFF failure then an owner returns: the ON bundle is replayed', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(fg);
      rig.failing.add(_optSave);
      await rig.setOwners(LiveStreamOwners.none);
      expect(rig.engine.debugLiveApplied.imu, isTrue, reason: 'OFF not confirmed');
      // The failed OFF ended the pass before HR OFF was attempted (a failure
      // exits; the keep-alive retries), so HR is still applied here.
      expect(rig.engine.debugLiveApplied.hr, isTrue);
      rig.failing.clear();
      await rig.setOwners(fg);
      expect(rig.ops.sublist(8), [(_r10, 1), (_imu, 1), (_optSave, 1)],
          reason: 'dirty bundle replays ON in full; HR needs nothing');
      expect(rig.engine.debugLiveApplied, const LiveStreamIntent(hr: true, imu: true));
    });

    test('keep-alive re-arms R10/R11 on gen4', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(fg);
      rig.engine.state.liveHrAt = DateTime.now().millisecondsSinceEpoch;
      await rig.engine.debugReassertLiveStreams();
      expect(rig.ops.last, (_r10, 1));
      expect(rig.ops.length, 5);
    });
  });
}
