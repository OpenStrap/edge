# iOS background: band-driven wakes instead of a 1 Hz keep-alive stream

Date: 2026-09-21
Status: draft, awaiting maintainer review
Scope: `edge` only. No protocol or analytics change. No `kAlgoVersion` bump
(no analytics output changes).

## 1. Problem

On iOS the app keeps the band's realtime heart-rate stream (opcode 3) ON for
the whole time it is backgrounded. `AppState._liveOwners()` sets
`iosBackgroundKeepalive` whenever `_background && Platform.isIOS`, and
`desiredLiveStreams` turns that into `hr: true`. The band then sends one BLE
notification per second, all night. With the `bluetooth-central` background
mode each notification resumes the suspended process, so the process is
effectively never suspended: ~86,400 wakes a day.

Observed on a user's iPhone (Settings → Battery, one day): Edge at 62 % of
battery, 20 min on screen, 16 h 35 min background. The Android side hit the
same drain (issue #200) and fixed it by turning the stream off in background;
the comment in `_liveOwners` records the reason iOS kept it: "with zero
inbound traffic the Dart timers may never run and continuous capture stalls;
the stream is load-bearing there, not waste."

Nothing in background consumes the frames. `_processImmediateFrame` routes
realtime frames to an in-memory sink only, the derive scheduler is already
deferred to foreground on iOS, and `state.wristOn` / `liveHr` have no
background consumer. The stream is purely a wake source.

## 2. Goal

While backgrounded on iOS, the process must suspend between wakes, and wakes
must come from the band at a cadence measured in minutes, not seconds.
Continuous capture (flash → SQLite) must keep working, the smart-wake window
must keep working, and a link that genuinely dies must still be detected and
recovered.

Target: background wakes per day drop from ~86,400 to on the order of 100–300
(one per band prompt plus a handful of timers that fire while awake). The
user-visible check is the Background time on the iOS battery screen dropping
from hours to minutes.

## 3. Mechanism: the band's own sync prompt

The protocol already has what we need. `cmdEnterHighFreqSync(interval,
duration)` (opcode 0x60) tells the band to emit a `HIGH_FREQ_SYNC_PROMPT`
event (id 96) every `interval` seconds for `duration` seconds. The engine
already handles that event: `_handleEventInfo` case `highFreqSyncPrompt`
starts a historical refresh (`BackfillTrigger.strap`). The smart-wake feature
uses this at 61 s for a 90-minute lease (`applyHighFreqWakeWindow`).

An event notification is a BLE notification like any other, so it resumes a
suspended app. Each prompt therefore becomes: wake → GET_DATA_RANGE →
SEND_HISTORICAL_DATA → drain → commit → ACK → overdue Dart timers fire once →
suspend. That is the loop the headless restore wake already runs, minus the
connect.

Known bounds (protocol `cmdEnterHighFreqSync`): gen5 rejects `interval <= 60`
and `duration >= 28800`; gen4 bounds are unknown and gen4 is "the generation
that demonstrably works". Both proposed values below sit inside the gen5
bounds.

## 4. Design

### 4.1 Remove the iOS background owner of the HR stream

`LiveStreamOwners.iosBackgroundKeepalive` is deleted. `desiredLiveStreams`
loses the `o.iosBackgroundKeepalive` term. `_liveOwners()` no longer sets it.
iOS background with no physiological owner is then identical to Android
background: HR off, bundle off. Workouts, breathing sessions and a mounted
live-HR view keep owning HR exactly as today, in background or not.

gen4 is unaffected beyond that: `legacy = !gen5 && o.foreground` is already
false in background, so a backgrounded WHOOP 4.0 with no owner is fully off.

### 4.2 One pure policy decides what the band is asked to prompt

New value type and policy in `lib/sync/sync_policy.dart`:

```dart
class BandPromptRequest {
  final int intervalSeconds;
  final Duration lease;
  final DateTime until;     // what the engine stores as _highFreqUntil
  final String reason;      // 'wake_window:<source>' | 'ios_background'
}

class BandPromptPolicy {
  /// Highest-priority requester wins. Smart wake (61 s / 90 min) beats the
  /// iOS background keep-alive (900 s / 2 h). Neither → null (exit the mode).
  static BandPromptRequest? plan({
    required bool smartWakeEnabled,
    required DateTime? smartWakeTarget,
    required String smartWakeSource,
    required bool iosBackgrounded,
    required DateTime? currentUntil,   // what is armed right now, if anything
    required DateTime now,
  });
}
```

Rules:
- Smart-wake enabled → `(61 s, HighFreqWakeWindow.lease, until: target,
  reason: source)`. Byte-identical to today's call.
- Else `iosBackgrounded` → `(kIosBackgroundPromptIntervalSeconds = 900,
  kIosBackgroundPromptLease = 2 h, reason: 'ios_background')`. `until` is
  `now + lease`, except that if `currentUntil` is an `ios_background` lease
  with more than half of it left, the existing `until` is returned unchanged
  so the engine's "unchanged → no write" guard holds and the band is not
  re-written on every tick. A lease is renewed once it is past half-way.
- Else → null.

Constants live next to the other timing constants with the same
ASSUMES / FALSIFIED BY / WHEN WRONG / HOW TO CHECK doc block the file uses.
The interval is deliberately equal to `BackfillPolicy.periodicFloorSeconds`
(900) so the engine's own periodic timer and the prompt trigger coalesce on
`_lastBackfillAt` rather than doubling up.

### 4.3 Arming points (AppState)

`_refreshHighFreqWakeWindow()` becomes the single place that calls the policy
and passes the result to `engine.applyHighFreqWakeWindow(...)`. Its existing
call sites already cover the lifecycle:

| call site | why it matters now |
|---|---|
| post-connect block in `openSession` | first arm after a connect |
| after the backlog drains | re-evaluate once the flash is caught up |
| background reconnect post-connect block | re-arm after a link drop in background |
| `_runPeriodicBackfill` background branch (25-min throttle) | keeps the 2 h lease rolling; the overdue 10-min timer fires once per prompt wake |

Two new calls:
- `pauseForBackground()` — right after `_nudgeLive()`, so the band is asked to
  prompt the moment the stream is dropped.
- `openSession()` fast-reclaim branch — so the foreground drops the
  background request (unless a smart-wake window is open).

The headless path in `background_sync.dart` keeps its smart-wake-only call:
a headless run ends with a disconnect, so a background lease there is moot.

The log line in `pauseForBackground` changes from "holding live connection
for continuous background capture" to state the prompt cadence, and the
`[SYNC] HighFreq enter (ios_background)` line is the hardware-verification
marker.

### 4.4 Suspension-aware liveness

Today's liveness logic assumes the process is always running. Two places
would misfire on a process that was suspended for 15 minutes:

**(a) `_keepAliveFire` fuse.** `sinceLastRx > 120 s` bounces the link. On a
prompt wake the overdue 30 s tick and the inbound notification race on the
Dart event loop; if the tick wins, `sinceLastRx` is ~900 s and the link is
torn down on every wake.

Fix: the engine records `_lastKeepAliveTickAt`. A new pure function in
`sync_policy.dart`:

```dart
/// Silence that counts as evidence the link is dead. Silence that
/// accumulated while the process could not run (no tick for > 2 periods)
/// proves nothing — the phone was not listening — so the clock restarts at
/// the tick that noticed the gap.
Duration livenessSilence({
  required Duration sinceLastRx,
  required Duration sinceLastTick,
  required Duration tickPeriod,
});
```

Returns `sinceLastRx` normally; returns `Duration.zero` when
`sinceLastTick > 2 * tickPeriod` (a resumed tick). The fuse uses this value;
the forced-battery-poll decision keeps using raw `sinceLastRx`, so a resumed
tick always sends a poll. If the poll is not answered, the next tick sees
real silence and the fuse works exactly as before.

**(b) Resume freshness** (`openSession` fast reclaim and `foregroundCatchUp`).
`isLinkStale(sinceLastRx, liveStreamArmed: false)` is 90 s. After a quiet
15-minute background stretch every foreground open would tear the link down.

Fix: a pure decision plus a real probe.

```dart
enum ResumeLinkAction { trust, probe, reconnect }
ResumeLinkAction resumeLinkAction(Duration sinceLastRx, {required bool liveStreamArmed});
```

- Fresh under the existing bar → `trust` (today's fast reclaim).
- Stale with a live stream armed → `reconnect` (today's behaviour: a stream
  that stopped is a dead link).
- Stale with no stream armed → `probe`.

`BleEngine.probeLink()` sends GET_BATTERY_LEVEL through `_sendAwaited` and
returns whether a reply arrived within the existing command timeout. `probe`
→ reply → treat as `trust`; no reply → `reconnect`. Both call sites use the
same helper in AppState so the two paths cannot drift (§4.7 in AGENTS.md).

### 4.5 What does not change

- All timer periods (10 s heartbeat, 30 s keep-alive, 1 min supervisor,
  10 min AppState backfill tick, 900 s engine backfill). They only run while
  the process is awake; each fires at most once per wake.
- `DeriveDebouncer` background tier, `DeriveScheduler` iOS deferral.
- Restore central arming, `setOwnsBand`, `IosBleRestore` wake handling.
- Android behaviour: `iosBackgrounded` is false there; no Android path reads
  the new policy.
- Commit-before-ACK, `RecordGate`, `DrainController` — the prompt path is the
  existing `BackfillTrigger.strap` path.

### 4.6 Failure modes and fallbacks

| failure | what happens | detection |
|---|---|---|
| Band drops the link after minutes of phone silence (gen4 idle policy unknown) | `_onEngineState` disconnect branch arms the restore central; band reconnects when reachable; post-connect block re-arms the prompt. Still far cheaper than 1 Hz. | `didDisconnect` / `Connection dropped` every ~15 min in the log → lower the interval constant (e.g. 300 s) |
| gen4 rejects 900 s or a 2 h duration | mode never engages, no prompts, no background sync until foreground / BG task / restore wake | no `HighFreq prompt received` lines after `HighFreq enter (ios_background)` → try smaller values |
| Band prompt arrives but the offload is floored | `BackfillPolicy` floors `strap` at 90 s × empty-streak backoff (max 360 s); at 900 s it always runs | `[SYNC]` floor lines |
| Process killed by jetsam | restore central relaunches on the next band reachability event, as today | unchanged |
| Smart-wake night | policy prefers the 61 s window; `_checkSmartWake` runs from the overdue keep-alive tick on each prompt wake, i.e. at most ~1 min later than today | `[smart-wake]` lines |

## 5. Testing

Pure policy tests (no BLE/DB), following `test/sync_policy_test.dart`:
- `BandPromptPolicy.plan`: smart-wake beats background; background produces
  900 s / 2 h; lease renewal only past half-way; null when neither.
- `livenessSilence`: normal ticks pass through; a resumed tick returns zero;
  boundary at exactly 2 periods.
- `resumeLinkAction`: fresh → trust; stale+stream → reconnect; stale+no
  stream → probe.

Existing tests to update:
- `test/live_stream_policy_test.dart`: the two `iosBackgroundKeepalive`
  cases become "background with no owner: off" on both generations.
- `test/live_stream_ownership_test.dart`: the "iOS background with no other
  owner: HR only" rig case and the gen4 "full → HR-only (backgrounding on
  iOS)" sequence; the latter keeps its byte-sequence assertion through a
  workout owner instead, so the gen4 HR-only wire order stays pinned.
- `test/gen5_wiring_test.dart` `applyHighFreqWakeWindow` cases: unchanged
  behaviour, confirm still green.

Engine rig tests (fake-link seam, as in `live_stream_ownership_test.dart`):
- A resumed keep-alive tick with 900 s of silence does not bounce the link and
  does send GET_BATTERY_LEVEL.
- `probeLink()` resolves true on a reply, false on timeout.

Hardware verification (required by CONTRIBUTING for anything touching sync;
recorded in the PR):
1. iPhone + WHOOP 4.0, app backgrounded overnight. Share
   `Documents/openstrap_sync.log` (visible in Files). Expect
   `HighFreq enter (ios_background)`, then `HighFreq prompt received` roughly
   every 15 min, each followed by a `Backlog drained` line; no
   `bouncing the link` or `Connection dropped` storm.
2. Next day Settings → Battery: Background time for Edge in minutes, not hours.
3. Foreground open after hours: log shows a probe and fast reclaim, not
   `stale link, reconnecting`, on a healthy link.
4. One alarm night with smart wake on: `[smart-wake]` check lines during the
   window.

## 6. Out of scope

- A user-facing battery-saver toggle (not needed if the default is right).
- Changing the smart-wake 61 s interval or the 90-minute lease.
- Android (already off in background).
- Any change to what is derived, stored, or displayed.
