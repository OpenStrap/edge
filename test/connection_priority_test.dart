// Regression test for the BLE connection-parameter policy.
//
// THE BUG THIS EXISTS FOR
//
// The connect path in `ble/ble_engine.dart` called, exactly once, at setup:
//
//     if (Platform.isAndroid) {
//       await device.requestConnectionPriority(
//           connectionPriorityRequest: ConnectionPriority.high);
//     }
//
// and never lowered it again. The comment above it scoped the intent
// precisely — "a fast connection interval FOR THE DRAIN" — but nothing
// restored a slower one when the drain finished, and this app deliberately
// holds the BLE link open 24/7: `AppState.pauseForBackground` keeps the live
// connection instead of dropping it, and Android's EdgeTracking foreground
// service exists for no other reason than to keep that link alive.
//
// Android's CONNECTION_PRIORITY_HIGH is an 11.25-15 ms connection interval
// with SLAVE LATENCY 0 — the peripheral is forbidden from skipping a single
// connection event. That is ~67 radio wakes per second on the band, all day
// and all night, for a link whose steady-state traffic is a 1 Hz HR
// notification, a 10 s LINK_VALID heartbeat and a 30 s battery poll
// (kKeepAliveIntervalSeconds). Connection interval is the dominant power term
// for an otherwise idle BLE peripheral, and the band is the device here with
// the small battery.
//
// So the priority is now a function of what is actually on the wire:
//
//   * a history offload, or the full 100 Hz live flood  -> high
//     (both genuinely need the throughput; ~7.6 KB/s for the flood)
//   * the backgrounded HR-only downgrade                -> lowPower
//     (100-125 ms, slave latency 2 — the band may skip 2 of every 3 events;
//      this is the overnight stretch, where nothing consumes live data)
//   * nothing armed, or the marginal-radio fallback     -> balanced
//
// `high` must keep winning over the HR-only downgrade, because a HEADLESS
// background drain runs with live in HR-only mode: that is a real offload and
// it must not be throttled.
//
// The `standardHrFallback` case is subtle and was a defect in the first cut of
// this policy. `enableLiveStreams` sets `_liveHrOnly = false` and then returns
// EARLY when the fallback is latched, so the R10/R11 + IMU + optical toggles
// are never sent — the link carries HR only while the flags say "full live".
// Keying on the flags alone would pin `high` for traffic that isn't there, on
// exactly the marginal radios that tripped the latch in the first place.

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';

void main() {
  group('connectionPriorityFor', () {
    test('a history offload takes the fast interval', () {
      expect(
        connectionPriorityFor(
          offloadActive: true,
          liveEnabled: false,
          liveHrOnly: false,
          standardHrFallback: false,
        ),
        ConnectionPriority.high,
      );
    });

    test('an offload outranks the HR-only downgrade (headless drain)', () {
      // A background/headless drain connects with live in HR-only mode. The
      // offload is the whole point of that wake — throttling it to lowPower
      // would stretch the drain across the OS's short background window.
      expect(
        connectionPriorityFor(
          offloadActive: true,
          liveEnabled: true,
          liveHrOnly: true,
          standardHrFallback: false,
        ),
        ConnectionPriority.high,
      );
    });

    test('an offload outranks the marginal-radio fallback', () {
      // The fallback throttles the LIVE flood, not the history drain. A weak
      // radio still has to get the backlog off the band.
      expect(
        connectionPriorityFor(
          offloadActive: true,
          liveEnabled: true,
          liveHrOnly: false,
          standardHrFallback: true,
        ),
        ConnectionPriority.high,
      );
    });

    test('the full live flood takes the fast interval with no offload', () {
      // A workout streams R10/R11 + 100 Hz IMU + optical with no history
      // drain running. Dropping to balanced here is what would starve it into
      // tripping MarginalRadioDetector -> the sticky standardHrFallback latch,
      // which silently zeroes live step counting for the rest of the process.
      expect(
        connectionPriorityFor(
          offloadActive: false,
          liveEnabled: true,
          liveHrOnly: false,
          standardHrFallback: false,
        ),
        ConnectionPriority.high,
      );
    });

    test('the backgrounded HR-only link drops to lowPower', () {
      expect(
        connectionPriorityFor(
          offloadActive: false,
          liveEnabled: true,
          liveHrOnly: true,
          standardHrFallback: false,
        ),
        ConnectionPriority.lowPower,
      );
    });

    test('the marginal-radio fallback does not get the fast interval', () {
      // THE DEFECT THIS PINS: enableLiveStreams() sets _liveHrOnly = false and
      // then returns early under the fallback, so the flood toggles are never
      // sent. Flags alone say "full live"; the wire carries HR only.
      expect(
        connectionPriorityFor(
          offloadActive: false,
          liveEnabled: true,
          liveHrOnly: false,
          standardHrFallback: true,
        ),
        ConnectionPriority.balanced,
      );
    });

    test('the background downgrade outranks the fallback', () {
      // Both latched: nothing is consuming live data, so take the deeper
      // saving rather than the foreground-safe one.
      expect(
        connectionPriorityFor(
          offloadActive: false,
          liveEnabled: true,
          liveHrOnly: true,
          standardHrFallback: true,
        ),
        ConnectionPriority.lowPower,
      );
    });

    test('an idle link with nothing armed sits at balanced', () {
      // Live streams off entirely (spot-check cleanup restores them to OFF
      // when they were off before). Balanced rather than lowPower: a
      // foreground app can re-arm the flood at any moment.
      expect(
        connectionPriorityFor(
          offloadActive: false,
          liveEnabled: false,
          liveHrOnly: false,
          standardHrFallback: false,
        ),
        ConnectionPriority.balanced,
      );
    });

    test('liveHrOnly is ignored when no live stream is armed', () {
      // disableLiveStreams() clears _liveEnabled and _liveHrOnly together, but
      // the policy must be total rather than relying on that pairing holding.
      expect(
        connectionPriorityFor(
          offloadActive: false,
          liveEnabled: false,
          liveHrOnly: true,
          standardHrFallback: true,
        ),
        ConnectionPriority.balanced,
      );
    });
  });
}
