// Pure-policy tests for the live HR/IMU ownership model (discussion #287):
// which owners want which stream, and the single-step reconciler that walks
// the applied state towards the desired one. No engine, no band.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

const _off = LiveStreamIntent.off;
const _hrOnly = LiveStreamIntent(hr: true, imu: false);
const _imuOnly = LiveStreamIntent(hr: false, imu: true);
const _both = LiveStreamIntent(hr: true, imu: true);

LiveStreamIntent _gen5(LiveStreamOwners o, {bool fallback = false}) =>
    desiredLiveStreams(o, gen5: true, standardHrFallback: fallback);
LiveStreamIntent _gen4(LiveStreamOwners o, {bool fallback = false}) =>
    desiredLiveStreams(o, gen5: false, standardHrFallback: fallback);

/// Walk the reconciler to convergence, returning the steps it emitted.
List<LiveStreamStep> _walk({
  LiveStreamIntent applied = _off,
  required LiveStreamIntent desired,
  bool imuFresh = false,
  bool imuDirty = false,
  bool hrDirty = false,
}) {
  final steps = <LiveStreamStep>[];
  var a = applied;
  var fresh = imuFresh, iDirty = imuDirty, hDirty = hrDirty;
  for (var i = 0; i < 8; i++) {
    final s = nextLiveStreamStep(
      applied: a,
      desired: desired,
      imuFresh: fresh,
      imuDirty: iDirty,
      hrDirty: hDirty,
    );
    if (s == null) return steps;
    steps.add(s);
    a = applyLiveStreamStep(a, s);
    if (s.isImu) {
      fresh = false;
      iDirty = false;
    } else {
      hDirty = false;
    }
  }
  fail('did not converge: $steps');
}

void main() {
  group('desiredLiveStreams — gen5 policy table (#287)', () {
    test('ordinary READY with no owner: off', () {
      expect(_gen5(LiveStreamOwners.none), _off);
      // A foreground connection is NOT an owner on gen5.
      expect(_gen5(const LiveStreamOwners(foreground: true)), _off);
    });
    test('visible live-HR view: HR only', () {
      expect(
        _gen5(const LiveStreamOwners(visibleLiveHrView: true, foreground: true)),
        _hrOnly,
      );
    });
    test('foreground gait workout: HR + IMU', () {
      expect(
        _gen5(const LiveStreamOwners(
          activeWorkout: true,
          foregroundGaitWorkout: true,
          foreground: true,
        )),
        _both,
      );
    });
    test('non-gait workout (incl. manual strength): HR only', () {
      expect(
        _gen5(const LiveStreamOwners(activeWorkout: true, foreground: true)),
        _hrOnly,
      );
    });
    test('background gait workout: HR stays, IMU off pending measurement', () {
      expect(_gen5(const LiveStreamOwners(activeWorkout: true)), _hrOnly);
    });
    test('breathing session/window: HR only', () {
      expect(
        _gen5(const LiveStreamOwners(breathing: true, foreground: true)),
        _hrOnly,
      );
    });
    test('bounded movement-sampling window: IMU only', () {
      expect(_gen5(const LiveStreamOwners(movementSampling: true)), _imuOnly);
    });
    test('passive strap-step opt-in: IMU only', () {
      expect(_gen5(const LiveStreamOwners(passiveStrapSteps: true)), _imuOnly);
    });
    test('iOS background with no physiological owner: HR only', () {
      expect(
        _gen5(const LiveStreamOwners(iosBackgroundKeepalive: true)),
        _hrOnly,
      );
    });
    test('Android background with no owner: off', () {
      expect(_gen5(LiveStreamOwners.none), _off);
    });
    test('marginal-radio fallback masks IMU only', () {
      expect(
        _gen5(
          const LiveStreamOwners(
            activeWorkout: true,
            foregroundGaitWorkout: true,
          ),
          fallback: true,
        ),
        _hrOnly,
      );
      expect(
        _gen5(const LiveStreamOwners(movementSampling: true), fallback: true),
        _off,
      );
    });
    test('history sync has no owner field at all', () {
      // Nothing in LiveStreamOwners describes a sync; the type is the proof.
      expect(LiveStreamOwners.none.toString(), isNot(contains('sync')));
    });
  });

  group('desiredLiveStreams — gen4 keeps today\'s behaviour', () {
    test('foreground connection alone arms HR + the bundle', () {
      expect(_gen4(const LiveStreamOwners(foreground: true)), _both);
    });
    test('background with no owner: off (Android) / HR-only (iOS keepalive)', () {
      expect(_gen4(LiveStreamOwners.none), _off);
      expect(
        _gen4(const LiveStreamOwners(iosBackgroundKeepalive: true)),
        _hrOnly,
      );
    });
    test('background workout keeps HR and drops the bundle', () {
      expect(_gen4(const LiveStreamOwners(activeWorkout: true)), _hrOnly);
    });
    test('fallback masks the bundle on gen4 too', () {
      expect(
        _gen4(const LiveStreamOwners(foreground: true), fallback: true),
        _hrOnly,
      );
    });
  });

  group('nextLiveStreamStep — order and convergence', () {
    test('converged: null', () {
      for (final i in [_off, _hrOnly, _imuOnly, _both]) {
        expect(nextLiveStreamStep(applied: i, desired: i), isNull);
      }
    });
    test('full arm: HR ON then bundle ON (today\'s enable order)', () {
      expect(
        _walk(desired: _both),
        [LiveStreamStep.hrOn, LiveStreamStep.imuOn],
      );
    });
    test('full disarm: bundle OFF then HR OFF (today\'s disable order)', () {
      expect(
        _walk(applied: _both, desired: _off),
        [LiveStreamStep.imuOff, LiveStreamStep.hrOff],
      );
    });
    test('full → HR-only: bundle OFF only', () {
      expect(_walk(applied: _both, desired: _hrOnly), [LiveStreamStep.imuOff]);
    });
    test('HR-only → full: bundle ON only', () {
      expect(_walk(applied: _hrOnly, desired: _both), [LiveStreamStep.imuOn]);
    });
    test('HR-only ↔ IMU-only swaps ON before OFF', () {
      expect(
        _walk(applied: _hrOnly, desired: _imuOnly),
        [LiveStreamStep.imuOn, LiveStreamStep.hrOff],
      );
      expect(
        _walk(applied: _imuOnly, desired: _hrOnly),
        [LiveStreamStep.hrOn, LiveStreamStep.imuOff],
      );
    });
    test('applyLiveStreamStep flips exactly one bit', () {
      expect(applyLiveStreamStep(_off, LiveStreamStep.hrOn), _hrOnly);
      expect(applyLiveStreamStep(_hrOnly, LiveStreamStep.imuOn), _both);
      expect(applyLiveStreamStep(_both, LiveStreamStep.imuOff), _hrOnly);
      expect(applyLiveStreamStep(_hrOnly, LiveStreamStep.hrOff), _off);
    });
  });

  group('nextLiveStreamStep — fresh link (gen4 bundle state unknown)', () {
    test('nothing desired: stays silent', () {
      expect(_walk(desired: _off, imuFresh: true), isEmpty);
    });
    test('HR-only desired: HR ON then a defensive bundle OFF', () {
      expect(
        _walk(desired: _hrOnly, imuFresh: true),
        [LiveStreamStep.hrOn, LiveStreamStep.imuOff],
      );
    });
    test('full desired: same as a known-off link', () {
      expect(
        _walk(desired: _both, imuFresh: true),
        [LiveStreamStep.hrOn, LiveStreamStep.imuOn],
      );
    });
    test('IMU-only desired: bundle ON', () {
      expect(_walk(desired: _imuOnly, imuFresh: true), [LiveStreamStep.imuOn]);
    });
  });

  group('nextLiveStreamStep — dirty bits replay the newest direction', () {
    test('dirty bundle with nothing desired: OFF is replayed (unlike fresh)', () {
      expect(_walk(desired: _off, imuDirty: true), [LiveStreamStep.imuOff]);
    });
    test('dirty bundle, applied off, desired on: ON', () {
      expect(_walk(desired: _imuOnly, imuDirty: true), [LiveStreamStep.imuOn]);
    });
    test('dirty bundle, applied on, desired on: re-applied ON', () {
      expect(
        _walk(applied: _imuOnly, desired: _imuOnly, imuDirty: true),
        [LiveStreamStep.imuOn],
      );
    });
    test('dirty HR after a failed ON, owner gone: HR OFF', () {
      expect(_walk(desired: _off, hrDirty: true), [LiveStreamStep.hrOff]);
    });
    test('dirty HR after a failed OFF, new owner: HR ON', () {
      expect(
        _walk(applied: _hrOnly, desired: _hrOnly, hrDirty: true),
        [LiveStreamStep.hrOn],
      );
    });
    test('dirty HR and bundle with nothing desired: bundle OFF then HR OFF', () {
      expect(
        _walk(desired: _off, imuDirty: true, hrDirty: true),
        [LiveStreamStep.imuOff, LiveStreamStep.hrOff],
      );
    });
  });
}
