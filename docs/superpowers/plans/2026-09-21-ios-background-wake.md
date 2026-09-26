# iOS background band-driven wakes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop holding the band's 1 Hz realtime-HR stream while the iOS app is backgrounded; instead ask the band to prompt the phone every 15 minutes so the process suspends between wakes and battery drain drops from hours of background time to minutes.

**Architecture:** Three pure policies (`BandPromptPolicy`, `livenessSilence`, `resumeLinkAction`) go in `lib/sync/sync_policy.dart`, tested without BLE or DB. The engine gains a suspension-aware keep-alive fuse and a `probeLink()` helper. `AppState` loses the `iosBackgroundKeepalive` live-stream owner and routes every `applyHighFreqWakeWindow` call through the new policy. The band's existing `HIGH_FREQ_SYNC_PROMPT` event (already handled by the engine as a `BackfillTrigger.strap` offload) becomes the background wake source.

**Tech Stack:** Flutter/Dart, `flutter_test`, the engine's `debugInstallFakeLink` / `debugAbsorbDecoded` seams. No native (Swift) change. No protocol or analytics change.

**Spec:** `docs/superpowers/specs/2026-09-21-ios-background-wake-design.md`

## Global Constraints

Copied from `CONTRIBUTING.md` and `AGENTS.md`; every task inherits them.

- Branch off `main`; one logical change per PR; explain *why* in the PR and say how it was verified on hardware.
- **No `Co-Authored-By` trailers** on any commit (CONTRIBUTING → Pull requests). Commit messages are short, lowercase, imperative, e.g. `ios: ...`, `fix: ...`.
- Decisions live in pure policy classes in `lib/sync/sync_policy.dart` / `lib/ble/ble_state.dart`; the engine and `AppState` only wire them. Policies never read `Platform.isIOS`; callers pass booleans.
- No `kAlgoVersion` bump: nothing derived, stored or displayed changes.
- Every flag set on a path must be cleared on the failure path (`finally`, timeout, give-up branch) — AGENTS §4.3.
- Never fabricate: a liveness decision must come from a real reply, never an assumed one.
- Verification commands: `flutter analyze` and `flutter test --concurrency=1` (the suite runs on real DB files; parallel workers race). Run `flutter pub get` first — `.dart_tool/` is absent in this checkout. Flutter is NOT on this machine's PATH (only `dart`); install Flutter stable or run the suite on a machine that has it before claiming green. CI runs both on the PR.
- `whoop_hist.jsonl` replay tests skip when the file is absent; that is expected.
- Do not hand-edit `ios/Runner/Info.plist` generated blocks (none are touched here).

---

## File map

| file | change |
|---|---|
| `lib/sync/sync_policy.dart` | + `kIosBackgroundPromptIntervalSeconds`, `kIosBackgroundPromptLease`, `kIosBackgroundPromptReason`, `kSmartWakePromptIntervalSeconds`; + `BandPromptRequest`, `BandPromptPolicy`; + `livenessSilence`; + `ResumeLinkAction`, `resumeLinkAction` |
| `lib/ble/ble_state.dart` | − `LiveStreamOwners.iosBackgroundKeepalive`; `desiredLiveStreams` drops the term |
| `lib/ble/ble_engine.dart` | + `_lastKeepAliveTickAt`, fuse via `livenessSilence`; + `probeLink()`; + `highFreqReason` / `highFreqUntil` getters; + `debugSetLiveness`, `debugFireKeepAlive` |
| `lib/state/app_state.dart` | `_liveOwners` drops the owner; `_refreshHighFreqWakeWindow` goes through `BandPromptPolicy`; `pauseForBackground` and `openSession` arm/disarm; resume paths use `_linkUsableAfterResume` |
| `test/band_prompt_policy_test.dart` | new — `BandPromptPolicy` |
| `test/link_liveness_policy_test.dart` | new — `livenessSilence`, `resumeLinkAction` |
| `test/keepalive_resume_test.dart` | new — engine fuse on a resumed tick |
| `test/link_probe_test.dart` | new — `probeLink()` |
| `test/live_stream_policy_test.dart`, `test/live_stream_ownership_test.dart` | owner removal |

---

### Task 0: Branch and toolchain

**Files:** none

- [ ] **Step 1: Branch off main**

```bash
cd /Users/osama/github/edge
git checkout main && git pull --ff-only
git checkout -b ios-background-band-prompts
```

- [ ] **Step 2: Make sure Flutter runs**

Run: `flutter --version`
Expected: a stable Flutter 3.x line. If `flutter: command not found`, install Flutter stable (https://docs.flutter.dev/get-started/install/macos) and add it to PATH before continuing. Then:

```bash
flutter pub get
flutter test --concurrency=1 test/sync_policy_test.dart test/live_stream_policy_test.dart
```

Expected: PASS (baseline green before touching anything).

---

### Task 1: `BandPromptPolicy` — who gets to ask the band to prompt

**Files:**
- Modify: `lib/sync/sync_policy.dart` (insert after `kNoStreamPollSilenceSeconds`, before `isLinkStale`, ~line 105–113)
- Create: `test/band_prompt_policy_test.dart`

**Interfaces:**
- Produces:
  - `const int kSmartWakePromptIntervalSeconds = 61;`
  - `const int kIosBackgroundPromptIntervalSeconds = 900;`
  - `const Duration kIosBackgroundPromptLease = Duration(hours: 2);`
  - `const String kIosBackgroundPromptReason = 'ios_background';`
  - `class BandPromptRequest { int intervalSeconds; Duration duration; DateTime until; String reason; }` with named constructors `BandPromptRequest.smartWake({required DateTime target, required Duration lease, required String source})` and `BandPromptRequest.iosBackground(DateTime now)`.
  - `BandPromptRequest? BandPromptPolicy.plan({required BandPromptRequest? smartWake, required bool iosBackgrounded, required String? currentReason, required DateTime? currentUntil, required DateTime now})`

- [ ] **Step 1: Write the failing tests**

`test/band_prompt_policy_test.dart`:

```dart
// Pure tests for BandPromptPolicy (sync_policy.dart): which requester gets
// to program the band's HIGH_FREQ_SYNC prompt, and when a running
// background lease is renewed. No BLE, no DB.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

void main() {
  final now = DateTime(2026, 9, 21, 23, 0);
  final smartWake = BandPromptRequest.smartWake(
    target: now.add(const Duration(hours: 8)),
    lease: const Duration(minutes: 90),
    source: 'habitual',
  );

  group('BandPromptPolicy.plan', () {
    test('nothing wants a prompt → null', () {
      expect(
        BandPromptPolicy.plan(
          smartWake: null,
          iosBackgrounded: false,
          currentReason: null,
          currentUntil: null,
          now: now,
        ),
        isNull,
      );
    });

    test('iOS backgrounded → 900 s prompts on a 2 h lease', () {
      final r = BandPromptPolicy.plan(
        smartWake: null,
        iosBackgrounded: true,
        currentReason: null,
        currentUntil: null,
        now: now,
      )!;
      expect(r.intervalSeconds, kIosBackgroundPromptIntervalSeconds);
      expect(r.intervalSeconds, 900);
      expect(r.duration, kIosBackgroundPromptLease);
      expect(r.until, now.add(kIosBackgroundPromptLease));
      expect(r.reason, kIosBackgroundPromptReason);
    });

    test('smart wake beats the background keep-alive', () {
      final r = BandPromptPolicy.plan(
        smartWake: smartWake,
        iosBackgrounded: true,
        currentReason: kIosBackgroundPromptReason,
        currentUntil: now.add(const Duration(hours: 1)),
        now: now,
      )!;
      expect(r.intervalSeconds, kSmartWakePromptIntervalSeconds);
      expect(r.intervalSeconds, 61);
      expect(r.reason, 'habitual');
      expect(r.until, smartWake.until);
      expect(r.duration, const Duration(minutes: 90));
    });

    test('smart wake alone (foreground) is byte-identical to today', () {
      final r = BandPromptPolicy.plan(
        smartWake: smartWake,
        iosBackgrounded: false,
        currentReason: null,
        currentUntil: null,
        now: now,
      );
      expect(r, smartWake);
    });

    test('a background lease with more than half left is kept as-is', () {
      final until = now.add(const Duration(minutes: 70)); // 70 of 120 min left
      final r = BandPromptPolicy.plan(
        smartWake: null,
        iosBackgrounded: true,
        currentReason: kIosBackgroundPromptReason,
        currentUntil: until,
        now: now,
      )!;
      expect(r.until, until, reason: 'unchanged → the engine writes nothing');
    });

    test('a background lease past half-way is renewed from now', () {
      final until = now.add(const Duration(minutes: 50)); // 50 of 120 min left
      final r = BandPromptPolicy.plan(
        smartWake: null,
        iosBackgrounded: true,
        currentReason: kIosBackgroundPromptReason,
        currentUntil: until,
        now: now,
      )!;
      expect(r.until, now.add(kIosBackgroundPromptLease));
    });

    test('a running smart-wake lease is not mistaken for a background lease', () {
      final r = BandPromptPolicy.plan(
        smartWake: null, // window just closed
        iosBackgrounded: true,
        currentReason: 'habitual',
        currentUntil: now.add(const Duration(minutes: 80)),
        now: now,
      )!;
      expect(r.reason, kIosBackgroundPromptReason);
      expect(r.until, now.add(kIosBackgroundPromptLease));
    });

    test('foregrounded with no window → null even if a background lease runs', () {
      expect(
        BandPromptPolicy.plan(
          smartWake: null,
          iosBackgrounded: false,
          currentReason: kIosBackgroundPromptReason,
          currentUntil: now.add(const Duration(hours: 1)),
          now: now,
        ),
        isNull,
      );
    });
  });

  group('BandPromptRequest', () {
    test('iosBackground fits gen5 bounds (> 60 s, < 28800 s)', () {
      final r = BandPromptRequest.iosBackground(now);
      expect(r.intervalSeconds, greaterThan(60));
      expect(r.duration.inSeconds, lessThan(28800));
    });
    test('value equality', () {
      expect(BandPromptRequest.iosBackground(now),
          BandPromptRequest.iosBackground(now));
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test --concurrency=1 test/band_prompt_policy_test.dart`
Expected: FAIL — `BandPromptRequest` / `BandPromptPolicy` undefined.

- [ ] **Step 3: Implement the policy**

In `lib/sync/sync_policy.dart`, directly after the `kNoStreamPollSilenceSeconds` constant (line ~105) and before `isLinkStale`, add:

```dart
// ── band prompt (ENTER_HIGH_FREQ_SYNC) ───────────────────────────────────────
/// Prompt interval the smart-wake window asks for. gen5 rejects <= 60.
const int kSmartWakePromptIntervalSeconds = 61;

/// How often a backgrounded iOS app asks the band to prompt it. Each
/// HIGH_FREQ_SYNC_PROMPT event is one BLE notification → one process wake →
/// one flash offload (`BleEngine._handleEventInfo`, `BackfillTrigger.strap`).
/// This replaces the 1 Hz realtime-HR stream that used to be held in
/// background purely to keep the process schedulable (~86,400 wakes/day).
/// Equal to [BackfillPolicy.periodicFloorSeconds] so the engine's periodic
/// timer and the prompt coalesce on `_lastBackfillAt` instead of doubling up.
///
/// ASSUMES: the band keeps the link up through this much phone-side silence
/// (no LINK_VALID is written while the process is suspended), and honours a
/// 900 s interval on gen4 (gen5 bounds are > 60 s and < 28800 s duration;
/// gen4 bounds are unknown — protocol `cmdEnterHighFreqSync`).
/// FALSIFIED BY: a band idle policy shorter than the interval, or a band
/// that rejects the interval.
/// WHEN WRONG: a dropped link is re-armed by the restore central and
/// reconnects on the next reachability event (still orders of magnitude
/// cheaper than 1 Hz); a rejected interval means no prompts, and background
/// sync falls back to BG tasks, restore wakes and foreground opens.
/// HOW TO CHECK: `HighFreq prompt received` roughly every 15 min in the
/// sync log with no `Connection dropped` between them.
const int kIosBackgroundPromptIntervalSeconds = 900;

/// Lease requested per ENTER_HIGH_FREQ_SYNC for the background prompt. Under
/// gen5's 28800 s ceiling. Renewed once past half-way by [BandPromptPolicy],
/// driven from the 25-min background tick in `AppState._runPeriodicBackfill`,
/// which fires on the first prompt wake after it falls due.
const Duration kIosBackgroundPromptLease = Duration(hours: 2);

/// Reason string the engine stores for a background lease; the policy uses
/// it to tell its own lease apart from a smart-wake one.
const String kIosBackgroundPromptReason = 'ios_background';

/// One requester's ask: program the band to prompt every [intervalSeconds]
/// for [duration]. [until] is what the engine keeps as `_highFreqUntil` and
/// compares to decide whether a re-apply is a no-op.
class BandPromptRequest {
  final int intervalSeconds;
  final Duration duration;
  final DateTime until;
  final String reason;

  const BandPromptRequest({
    required this.intervalSeconds,
    required this.duration,
    required this.until,
    required this.reason,
  });

  /// The smart-wake window's ask — the values `applyHighFreqWakeWindow` has
  /// always been called with.
  BandPromptRequest.smartWake({
    required DateTime target,
    required Duration lease,
    required String source,
  }) : this(
          intervalSeconds: kSmartWakePromptIntervalSeconds,
          duration: lease,
          until: target,
          reason: source,
        );

  /// The iOS background keep-alive's ask, leased from [now].
  BandPromptRequest.iosBackground(DateTime now)
      : this(
          intervalSeconds: kIosBackgroundPromptIntervalSeconds,
          duration: kIosBackgroundPromptLease,
          until: now.add(kIosBackgroundPromptLease),
          reason: kIosBackgroundPromptReason,
        );

  @override
  bool operator ==(Object other) =>
      other is BandPromptRequest &&
      other.intervalSeconds == intervalSeconds &&
      other.duration == duration &&
      other.until == until &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(intervalSeconds, duration, until, reason);

  @override
  String toString() =>
      'BandPromptRequest($reason every ${intervalSeconds}s until $until)';
}

/// Decides what the band is asked to prompt. Pure; the caller supplies the
/// smart-wake plan (already reduced to a request or null), whether the app
/// is backgrounded on iOS, and what the engine currently has applied.
class BandPromptPolicy {
  /// Priority: smart wake (61 s, its own lease) > iOS background keep-alive
  /// (900 s, 2 h) > nothing. A running background lease with more than half
  /// of it left is returned unchanged so the engine's "same reason + same
  /// until" guard skips the write; past half-way it is renewed from [now].
  static BandPromptRequest? plan({
    required BandPromptRequest? smartWake,
    required bool iosBackgrounded,
    required String? currentReason,
    required DateTime? currentUntil,
    required DateTime now,
  }) {
    if (smartWake != null) return smartWake;
    if (!iosBackgrounded) return null;
    if (currentReason == kIosBackgroundPromptReason &&
        currentUntil != null &&
        currentUntil.difference(now) > kIosBackgroundPromptLease ~/ 2) {
      return BandPromptRequest(
        intervalSeconds: kIosBackgroundPromptIntervalSeconds,
        duration: kIosBackgroundPromptLease,
        until: currentUntil,
        reason: kIosBackgroundPromptReason,
      );
    }
    return BandPromptRequest.iosBackground(now);
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test --concurrency=1 test/band_prompt_policy_test.dart`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/sync/sync_policy.dart test/band_prompt_policy_test.dart
git commit -m "sync: BandPromptPolicy — who programs the band's sync prompt"
```

---

### Task 2: Suspension-aware liveness policies

**Files:**
- Modify: `lib/sync/sync_policy.dart` (directly after `isLinkStale`, ~line 113–116)
- Create: `test/link_liveness_policy_test.dart`

**Interfaces:**
- Produces:
  - `Duration livenessSilence({required Duration sinceLastRx, required Duration sinceLastTick, required Duration tickPeriod})`
  - `enum ResumeLinkAction { trust, probe, reconnect }`
  - `ResumeLinkAction resumeLinkAction(Duration sinceLastRx, {required bool liveStreamArmed})`

- [ ] **Step 1: Write the failing tests**

`test/link_liveness_policy_test.dart`:

```dart
// Pure tests for the two suspension-aware liveness decisions in
// sync_policy.dart. An iOS process suspended between band prompts sees
// minutes of silence on a perfectly healthy link; neither decision may read
// that silence as death.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

void main() {
  const period = Duration(seconds: kKeepAliveIntervalSeconds);

  group('livenessSilence', () {
    test('ticks arriving on cadence: silence is the raw rx gap', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(seconds: 200),
          sinceLastTick: period,
          tickPeriod: period,
        ),
        const Duration(seconds: 200),
      );
    });

    test('first tick of a session (no previous tick) passes rx through', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(seconds: 200),
          sinceLastTick: Duration.zero,
          tickPeriod: period,
        ),
        const Duration(seconds: 200),
      );
    });

    test('a tick that missed more than two periods restarts the clock', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(minutes: 15),
          sinceLastTick: const Duration(minutes: 15),
          tickPeriod: period,
        ),
        Duration.zero,
      );
    });

    test('exactly two periods late is still a normal tick', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(seconds: 200),
          sinceLastTick: period * 2,
          tickPeriod: period,
        ),
        const Duration(seconds: 200),
      );
    });

    test('one microsecond past two periods is a resume', () {
      expect(
        livenessSilence(
          sinceLastRx: const Duration(seconds: 200),
          sinceLastTick: period * 2 + const Duration(microseconds: 1),
          tickPeriod: period,
        ),
        Duration.zero,
      );
    });
  });

  group('resumeLinkAction', () {
    test('fresh under the streaming bar → trust', () {
      expect(
        resumeLinkAction(const Duration(seconds: 5), liveStreamArmed: true),
        ResumeLinkAction.trust,
      );
    });
    test('fresh under the no-stream bar → trust', () {
      expect(
        resumeLinkAction(const Duration(seconds: 60), liveStreamArmed: false),
        ResumeLinkAction.trust,
      );
    });
    test('stale with a live stream armed → reconnect (a stream that stopped)',
        () {
      expect(
        resumeLinkAction(const Duration(seconds: 31), liveStreamArmed: true),
        ResumeLinkAction.reconnect,
      );
    });
    test('stale with no stream armed → probe, never guess', () {
      expect(
        resumeLinkAction(const Duration(minutes: 15), liveStreamArmed: false),
        ResumeLinkAction.probe,
      );
    });
    test('agrees with isLinkStale on the trust boundary', () {
      for (final armed in [true, false]) {
        for (var s = 0; s < 200; s += 5) {
          final d = Duration(seconds: s);
          final stale = isLinkStale(d, liveStreamArmed: armed);
          expect(
            resumeLinkAction(d, liveStreamArmed: armed) ==
                ResumeLinkAction.trust,
            !stale,
            reason: 'armed=$armed s=$s',
          );
        }
      }
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test --concurrency=1 test/link_liveness_policy_test.dart`
Expected: FAIL — `livenessSilence` / `resumeLinkAction` undefined.

- [ ] **Step 3: Implement**

In `lib/sync/sync_policy.dart`, right after the `isLinkStale` function, add:

```dart
/// Silence that counts as evidence the link is dead, for the keep-alive
/// fuse (`BleEngine._keepAliveFire`).
///
/// Silence that accumulated while the process could not run proves nothing:
/// an iOS app suspended between band prompts was not listening. A tick that
/// arrives more than two periods after the previous one is such a resume,
/// and the clock restarts at it — the caller must still probe (it does: the
/// forced battery poll keys off the RAW rx gap), and the NEXT tick judges
/// the reply on the normal bar.
Duration livenessSilence({
  required Duration sinceLastRx,
  required Duration sinceLastTick,
  required Duration tickPeriod,
}) =>
    sinceLastTick > tickPeriod * 2 ? Duration.zero : sinceLastRx;

/// What a resume path (foreground open, BG-task wake) may do with a link
/// that still reports connected.
enum ResumeLinkAction {
  /// Data arrived recently: reuse the link (fast reclaim).
  trust,

  /// Quiet, but no stream was armed so quiet is expected: ask the band
  /// (`BleEngine.probeLink`) and decide on the reply.
  probe,

  /// Quiet with a live stream armed: a stream that stopped is a dead link.
  reconnect,
}

/// [isLinkStale]'s bar, plus the one refinement a suspended process needs:
/// a stale-looking link with NO stream armed is probed rather than torn down.
ResumeLinkAction resumeLinkAction(
  Duration sinceLastRx, {
  required bool liveStreamArmed,
}) {
  if (!isLinkStale(sinceLastRx, liveStreamArmed: liveStreamArmed)) {
    return ResumeLinkAction.trust;
  }
  return liveStreamArmed ? ResumeLinkAction.reconnect : ResumeLinkAction.probe;
}
```

Also update the doc comment on `kLinkFreshnessNoStreamSeconds` (line ~92): change "(Android background, where live is fully off …)" to "(Android background, and iOS background since the band-prompt change, where live is fully off …)".

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test --concurrency=1 test/link_liveness_policy_test.dart test/sync_policy_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/sync/sync_policy.dart test/link_liveness_policy_test.dart
git commit -m "sync: suspension-aware liveness — livenessSilence and resumeLinkAction"
```

---

### Task 3: Remove the `iosBackgroundKeepalive` live-stream owner

**Files:**
- Modify: `lib/ble/ble_state.dart:1894-1985` (`LiveStreamOwners`, `desiredLiveStreams`)
- Modify: `lib/state/app_state.dart:2828-2903` (`_liveOwners` and its policy comment)
- Modify: `test/live_stream_policy_test.dart:95-99,129-134`
- Modify: `test/live_stream_ownership_test.dart:189-193,565-600`

**Interfaces:**
- Consumes: nothing new.
- Produces: `LiveStreamOwners` without `iosBackgroundKeepalive`. Any remaining reference is a compile error, which is the point.

- [ ] **Step 1: Update the policy tests first**

In `test/live_stream_policy_test.dart`, replace the two-test pair at lines 95–102:

```dart
    test('iOS background with no physiological owner: HR only', () {
      expect(
        _gen5(const LiveStreamOwners(iosBackgroundKeepalive: true)),
        _hrOnly,
      );
    });
    test('Android background with no owner: off', () {
      expect(_gen5(LiveStreamOwners.none), _off);
    });
```

with:

```dart
    test('background with no owner: off on both platforms', () {
      // iOS used to hold HR here purely to keep the suspended process
      // schedulable (~86,400 wakes/day). The band's HIGH_FREQ_SYNC prompt is
      // the wake source now (BandPromptPolicy), so background owns nothing.
      expect(_gen5(LiveStreamOwners.none), _off);
    });
```

And replace the gen4 test at lines 129–135:

```dart
    test('background with no owner: off (Android) / HR-only (iOS keepalive)', () {
      expect(_gen4(LiveStreamOwners.none), _off);
      expect(
        _gen4(const LiveStreamOwners(iosBackgroundKeepalive: true)),
        _hrOnly,
      );
    });
```

with:

```dart
    test('background with no owner: off', () {
      expect(_gen4(LiveStreamOwners.none), _off);
    });
```

- [ ] **Step 2: Update the ownership rig tests**

In `test/live_stream_ownership_test.dart`:

Delete the test at lines 189–193:

```dart
    test('iOS background with no other owner: HR only', () async {
      final rig = _Rig();
      await rig.setOwners(const LiveStreamOwners(iosBackgroundKeepalive: true));
      expect(rig.ops, [(_hr, 1)]);
    });
```

In the `gen4 — byte sequences unchanged` group, replace

```dart
    const iosBg = LiveStreamOwners(iosBackgroundKeepalive: true);
```

with

```dart
    // A background workout is the surviving HR-only owner on gen4 (the iOS
    // background keep-alive owner is gone); it pins the same wire order.
    const bgWorkout = LiveStreamOwners(activeWorkout: true);
```

and in the two tests that used `iosBg`, substitute `bgWorkout` and rename them:

```dart
    test('full → HR-only (background workout): the old HR-only sequence', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(fg);
      await rig.setOwners(bgWorkout);
      expect(rig.ops.sublist(4), [(_hr, 1), (_optMode, 0), (_optSave, 0), (_r10, 0), (_imu, 0)]);
      expect(rig.engine.debugLiveApplied, const LiveStreamIntent(hr: true, imu: false));
    });

    test('fresh link, HR-only wanted (background workout on a cold launch): HR ON then '
        'the defensive OFF tail — R10/R11 OFF persists on the strap', () async {
      final rig = _Rig(band: BandProfile.gen4);
      await rig.setOwners(bgWorkout);
      expect(rig.ops, [(_hr, 1), (_optMode, 0), (_optSave, 0), (_r10, 0), (_imu, 0)]);
```

(keep the rest of each test body as it is). Search the file for any other `iosBg` use and substitute the same way:

Run: `grep -n "iosBg\|iosBackgroundKeepalive" test/live_stream_ownership_test.dart`
Expected: no output.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `flutter test --concurrency=1 test/live_stream_policy_test.dart test/live_stream_ownership_test.dart`
Expected: the ownership test still compiles (it no longer references the field) but the policy test's "background with no owner: off on both platforms" passes trivially; the point of this step is to confirm the suite runs before the field is removed. PASS is acceptable here.

- [ ] **Step 4: Remove the owner from `ble_state.dart`**

In `class LiveStreamOwners` (line ~1894) delete the field and its doc:

```dart
  /// iOS, backgrounded: the inbound 1 Hz notification is what keeps the
  /// suspended process schedulable, so HR stays on there with no other owner.
  /// An Edge platform policy, not a measured guarantee.
  final bool iosBackgroundKeepalive;
```

delete `this.iosBackgroundKeepalive = false,` from the constructor, and change `toString` to:

```dart
  @override
  String toString() => 'LiveStreamOwners('
      'hrView: $visibleLiveHrView, workout: $activeWorkout, '
      'fgGait: $foregroundGaitWorkout, breathing: $breathing, '
      'movement: $movementSampling, '
      'passiveSteps: $passiveStrapSteps, foreground: $foreground)';
```

In the doc block above `desiredLiveStreams`, change

```dart
///   wantHr  = visibleLiveHrView || activeWorkout || breathing
///           || iosBackgroundKeepalive
```

to

```dart
///   wantHr  = visibleLiveHrView || activeWorkout || breathing
```

and in the function body remove the `o.iosBackgroundKeepalive ||` line:

```dart
  final hr = o.visibleLiveHrView ||
      o.activeWorkout ||
      o.breathing ||
      legacy;
```

- [ ] **Step 5: Remove the owner from `AppState._liveOwners`**

In `lib/state/app_state.dart`, in `_liveOwners()` (line ~2890) delete:

```dart
      iosBackgroundKeepalive: _background && Platform.isIOS,
```

In the policy comment block above it (lines ~2836–2850) replace the `HR ←` bullet:

```dart
  //   HR  ← a mounted live-HR view, any workout, a breathing session or
  //         window, or iOS backgrounded (the inbound 1 Hz notification is what
  //         keeps the suspended process schedulable — with zero inbound
  //         traffic the Dart timers may never run and continuous capture
  //         stalls; the stream is load-bearing there, not waste).
```

with

```dart
  //   HR  ← a mounted live-HR view, any workout, a breathing session or
  //         window. iOS background is NOT an owner any more: the 1 Hz stream
  //         was held there purely to keep the suspended process schedulable
  //         (~86,400 wakes/day, most of a day's battery). The band's own
  //         HIGH_FREQ_SYNC prompt is the wake source now — see
  //         BandPromptPolicy and _refreshHighFreqWakeWindow.
```

and the `Android backgrounded with no owner is fully OFF` sentence to `Backgrounded with no owner is fully OFF on both platforms — …` (keep the rest of that sentence).

- [ ] **Step 6: Run analyze and the two suites**

Run: `flutter analyze`
Expected: no `iosBackgroundKeepalive` references remain. If any other file references it, remove that reference the same way (there should be none: `grep -rn iosBackgroundKeepalive lib test` → empty).

Run: `flutter test --concurrency=1 test/live_stream_policy_test.dart test/live_stream_ownership_test.dart test/gen5_wiring_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/ble/ble_state.dart lib/state/app_state.dart test/live_stream_policy_test.dart test/live_stream_ownership_test.dart
git commit -m "ios: stop owning the 1 Hz HR stream in background"
```

---

### Task 4: Engine — suspension-aware keep-alive fuse

**Files:**
- Modify: `lib/ble/ble_engine.dart` — `_keepAliveFire` (line ~3453), session setup near `_lastRx = DateTime.now();` (line ~2607), debug seams block (line ~1539)
- Create: `test/keepalive_resume_test.dart`

**Interfaces:**
- Consumes: `livenessSilence` (Task 2), `kKeepAliveIntervalSeconds`, `kLivenessFuseSeconds`.
- Produces:
  - `@visibleForTesting void debugSetLiveness({DateTime? lastRx, DateTime? lastKeepAliveTick})`
  - `@visibleForTesting void debugFireKeepAlive()`

- [ ] **Step 1: Write the failing test**

`test/keepalive_resume_test.dart`:

```dart
// The keep-alive fuse on a process that was suspended. An iOS app woken by a
// band prompt after 15 quiet minutes must NOT bounce the link on its first
// (overdue) tick — it must probe. A tick that arrived on cadence with the
// same silence still bounces.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

class _Rig {
  final logs = <String>[];
  final opcodes = <int>[];
  late final BleEngine engine;

  _Rig() {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
    );
    engine.debugInstallFakeLink(
      band: BandProfile.gen4,
      listening: true,
      onWrite: (Uint8List frame) async {
        final p = parseFrame(frame, profile: BandProfile.gen4);
        if (p != null && p.valid) opcodes.add(p.inner[2]);
        return true;
      },
    );
  }

  bool get bounced => logs.any((l) => l.contains('bouncing the link'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  test('overdue tick after 15 min of suspension: no bounce, battery probe sent',
      () async {
    final rig = _Rig();
    final ago = DateTime.now().subtract(const Duration(minutes: 15));
    rig.engine.debugSetLiveness(lastRx: ago, lastKeepAliveTick: ago);

    rig.engine.debugFireKeepAlive();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(rig.bounced, isFalse,
        reason: 'silence while suspended is not evidence of a dead link');
    expect(rig.opcodes, contains(Cmd.getBatteryLevel),
        reason: 'the resumed tick must ask the band instead of guessing');
    expect(rig.logs.any((l) => l.contains('resumed after')), isTrue);
  });

  test('tick on cadence with the same silence still bounces', () async {
    final rig = _Rig();
    final now = DateTime.now();
    rig.engine.debugSetLiveness(
      lastRx: now.subtract(const Duration(seconds: kLivenessFuseSeconds + 5)),
      lastKeepAliveTick:
          now.subtract(const Duration(seconds: kKeepAliveIntervalSeconds)),
    );

    rig.engine.debugFireKeepAlive();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(rig.bounced, isTrue);
  });

  test('first tick of a session judges the raw rx gap', () async {
    final rig = _Rig();
    rig.engine.debugSetLiveness(
      lastRx: DateTime.now()
          .subtract(const Duration(seconds: kLivenessFuseSeconds + 5)),
      lastKeepAliveTick: null,
    );

    rig.engine.debugFireKeepAlive();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(rig.bounced, isTrue);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test --concurrency=1 test/keepalive_resume_test.dart`
Expected: FAIL — `debugSetLiveness` / `debugFireKeepAlive` undefined.

- [ ] **Step 3: Implement in the engine**

Near the other liveness fields (after `DateTime _lastRx = …;` at line ~1967) add:

```dart
  /// Wall-clock of the previous keep-alive tick. A tick that arrives more
  /// than two periods after this one means the process was suspended in
  /// between (iOS, between band prompts): silence accumulated then is not
  /// evidence — see `livenessSilence`. Null until the first tick of a session.
  DateTime? _lastKeepAliveTickAt;
```

In the session setup block, next to `_lastRx = DateTime.now(); // fresh link — never treat as stale on resume` (line ~2607) add:

```dart
      _lastKeepAliveTickAt = null; // first tick of this link judges raw silence
```

Replace the start of `_keepAliveFire` (line ~3453):

```dart
  void _keepAliveFire(_Session session) {
    if (_session != session || !session.connected) return;
    // Liveness watchdog: iOS can resume us with the peripheral flagged connected
    // while its GATT notifications silently died. If no frame has arrived for
    // longer than the fuse, bounce the link so the caller's reconnect loop runs.
    if (sinceLastRx.inSeconds > kLivenessFuseSeconds) {
```

with:

```dart
  void _keepAliveFire(_Session session) {
    if (_session != session || !session.connected) return;
    final now = DateTime.now();
    final lastTick = _lastKeepAliveTickAt;
    _lastKeepAliveTickAt = now;
    final sinceLastTick =
        lastTick == null ? Duration.zero : now.difference(lastTick);
    // Liveness watchdog: iOS can resume us with the peripheral flagged connected
    // while its GATT notifications silently died. If no frame has arrived for
    // longer than the fuse, bounce the link so the caller's reconnect loop runs.
    // Silence that built up while the process was SUSPENDED (this tick is
    // overdue by more than two periods — an iOS band-prompt wake) is not
    // evidence: the clock restarts here, the forced battery poll below still
    // fires off the raw gap, and the next tick judges the reply normally.
    final silence = livenessSilence(
      sinceLastRx: sinceLastRx,
      sinceLastTick: sinceLastTick,
      tickPeriod: const Duration(seconds: kKeepAliveIntervalSeconds),
    );
    if (silence == Duration.zero && sinceLastRx.inSeconds > kLivenessFuseSeconds) {
      _log('[keepalive] resumed after ${sinceLastTick.inSeconds}s without a '
          'tick — liveness clock restarted, probing the band.');
    }
    if (silence.inSeconds > kLivenessFuseSeconds) {
```

Everything after that `if` stays as it is (the bounce body, `shouldPauseMaintenanceTraffic`, the RTC re-verify, `_reconcileLive`, the forced battery poll that keys off raw `sinceLastRx`, `_applyLinkPriority`, `onKeepAlive`).

Add the two seams next to `debugReceiveFrame` (line ~1539):

```dart
  /// Test seam: back-date the liveness stamps so a keep-alive tick can be
  /// judged as "on cadence" or "overdue after a suspension".
  @visibleForTesting
  void debugSetLiveness({DateTime? lastRx, DateTime? lastKeepAliveTick}) {
    if (lastRx != null) _lastRx = lastRx;
    _lastKeepAliveTickAt = lastKeepAliveTick;
  }

  /// Test seam: run one keep-alive tick against the installed fake link.
  @visibleForTesting
  void debugFireKeepAlive() {
    final s = _session;
    if (s != null) _keepAliveFire(s);
  }
```

Make sure `lib/ble/ble_engine.dart` already imports `../sync/sync_policy.dart` (it does — `kLivenessFuseSeconds` comes from there).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test --concurrency=1 test/keepalive_resume_test.dart test/history_task_safety_test.dart test/command_correlation_test.dart`
Expected: PASS. (`history_task_safety_test` asserts the bounce log stays empty in a scenario with on-cadence ticks; it must remain green.)

- [ ] **Step 5: Commit**

```bash
git add lib/ble/ble_engine.dart test/keepalive_resume_test.dart
git commit -m "ble: keep-alive fuse ignores silence accumulated while suspended"
```

---

### Task 5: Engine — `probeLink()` and high-freq state getters

**Files:**
- Modify: `lib/ble/ble_engine.dart` — next to `getBattery()` (line ~3560), next to `_highFreqUntil` fields (line ~1708)
- Create: `test/link_probe_test.dart`

**Interfaces:**
- Consumes: `_sendAwaited` (returns `({bool written, Future<CorrelatedResponse?> response})`; the response future resolves `null` on timeout).
- Produces:
  - `Future<bool> probeLink({Duration timeout = CommandAwaiter.defaultTimeout})`
  - `String? get highFreqReason`, `DateTime? get highFreqUntil`

- [ ] **Step 1: Write the failing test**

`test/link_probe_test.dart`:

```dart
// BleEngine.probeLink(): a real question to the band, answered by a real
// reply. Used by resume paths that find a quiet link after the process was
// suspended (resumeLinkAction.probe). Never "assumes alive".

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

class _Link {
  final logs = <String>[];
  final written = <({int seq, int opcode})>[];
  late final BleEngine engine;
  bool answerBattery;
  bool writesSucceed;

  _Link({this.answerBattery = false, this.writesSucceed = true}) {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
    );
    engine.debugInstallFakeLink(
      band: BandProfile.gen4,
      listening: true,
      onWrite: (Uint8List frame) async {
        final p = parseFrame(frame, profile: BandProfile.gen4)!;
        final seq = p.inner[1];
        final opcode = p.inner[2];
        written.add((seq: seq, opcode: opcode));
        if (!writesSucceed) return false;
        if (opcode == Cmd.getBatteryLevel && answerBattery) {
          Future<void>.microtask(() => engine.debugAbsorbDecoded(
                Decoded('cmd_response', {
                  'opcode': Cmd.getBatteryLevel,
                  'req_seq': seq,
                  'cmd_status': CommandAwaiter.statusSuccess,
                  'battery_pct': 61.0,
                }),
              ));
        }
        return true;
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  const fast = Duration(milliseconds: 40);

  test('answered → true, and the reply still lands in state', () async {
    final link = _Link(answerBattery: true);
    expect(await link.engine.probeLink(timeout: fast), isTrue);
    expect(link.written.map((w) => w.opcode), contains(Cmd.getBatteryLevel));
    expect(link.engine.state.batteryPct, 61.0);
  });

  test('unanswered → false after the timeout', () async {
    final link = _Link(answerBattery: false);
    final sw = Stopwatch()..start();
    expect(await link.engine.probeLink(timeout: fast), isFalse);
    expect(sw.elapsed, greaterThanOrEqualTo(fast));
    expect(link.engine.pendingCommandCount, 0,
        reason: 'the awaiter must not leak a pending entry');
  });

  test('write failed → false immediately', () async {
    final link = _Link(writesSucceed: false);
    expect(await link.engine.probeLink(timeout: fast), isFalse);
  });

  test('no session → false without writing', () async {
    final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    expect(await engine.probeLink(timeout: fast), isFalse);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test --concurrency=1 test/link_probe_test.dart`
Expected: FAIL — `probeLink` undefined.

- [ ] **Step 3: Implement**

In `lib/ble/ble_engine.dart`, directly after `Future<void> getBattery() => _pollBatteryIfDue(force: true);` add:

```dart
  /// Ask the band something cheap and wait for the answer. True iff a reply
  /// correlated within [timeout]. For resume paths that find a link quiet
  /// after the process was not listening (iOS, suspended between band
  /// prompts): silence then is not evidence, so they ask instead of guessing
  /// — see `resumeLinkAction`. GET_BATTERY_LEVEL is the probe because it is
  /// the one poll this link already relies on for liveness.
  Future<bool> probeLink({
    Duration timeout = CommandAwaiter.defaultTimeout,
  }) async {
    if (_session?.connected != true) return false;
    final out = await _sendAwaited(
      Cmd.getBatteryLevel,
      const <int>[],
      timeout: timeout,
    );
    if (!out.written) return false;
    final reply = await out.response;
    final alive = reply != null;
    _log('[probe] battery poll ${alive ? 'answered' : 'unanswered'} '
        '(${timeout.inMilliseconds} ms) — link ${alive ? 'live' : 'dead'}.');
    return alive;
  }
```

Next to the `_highFreqUntil` / `_highFreqReason` fields (line ~1708) add public read-only views for `AppState`:

```dart
  /// What the band is currently asked to prompt (ENTER_HIGH_FREQ_SYNC), as
  /// last applied on this link. Null when the mode is off or the link is
  /// gone — a reconnect resets both, so a caller re-applies after it.
  String? get highFreqReason => _highFreqReason;
  DateTime? get highFreqUntil => _highFreqUntil;
```

Check that `_sendAwaited`'s `response` future does resolve to `null` on timeout: open `CommandAwaiter.register` in `lib/ble/ble_state.dart:1540-1575` and confirm the timer completes the completer with `null`. If it completes with an error instead, wrap `await out.response` in `try { … } catch (_) { return false; }`. The `unanswered → false` test pins whichever it is.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test --concurrency=1 test/link_probe_test.dart test/command_correlation_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ble/ble_engine.dart test/link_probe_test.dart
git commit -m "ble: probeLink() — ask the band before trusting a quiet link"
```

---

### Task 6: AppState — arm the band prompt through the policy

**Files:**
- Modify: `lib/state/app_state.dart` — `_refreshHighFreqWakeWindow` (line ~5296), `pauseForBackground` (line ~2787–2820), `openSession` fast-reclaim branch (line ~4920–4945)

**Interfaces:**
- Consumes: `BandPromptPolicy.plan`, `BandPromptRequest.smartWake`, `engine.highFreqReason`, `engine.highFreqUntil` (Tasks 1, 5), `HighFreqWakeWindow.planNow`, `HighFreqWakeWindow.lease`.
- Produces: no new public surface. `_refreshHighFreqWakeWindow()` keeps its name and every existing call site.

There is no unit test for `AppState` (it owns the DB); the policy tests in Task 1 cover the decision, and hardware verification in Task 8 covers the wiring. Keep the diff minimal.

- [ ] **Step 1: Route `_refreshHighFreqWakeWindow` through the policy**

Replace the body of `_refreshHighFreqWakeWindow` (currently: plan → `engine.applyHighFreqWakeWindow(enabled: plan.shouldEnable, targetWake: plan.targetWake, duration: HighFreqWakeWindow.lease, intervalSeconds: 61, reason: plan.source)` → log) with:

```dart
  /// The ONE place the band's HIGH_FREQ_SYNC prompt is programmed. Two
  /// requesters, one decision (`BandPromptPolicy`): the smart-wake window
  /// (61 s, ahead of an alarm) and, on iOS while backgrounded, the 15-min
  /// keep-alive prompt that replaced the 1 Hz HR stream as the thing that
  /// wakes a suspended process. Called on connect, after the backlog drains,
  /// on every background (re)connect, from the 25-min background tick (lease
  /// renewal), on backgrounding and on foreground reclaim.
  Future<void> _refreshHighFreqWakeWindow() async {
    if (!engine.isConnected) return;
    try {
      final armed = armedSmartWakeWindow(epoch: alarmEpoch, schedule: _schedule);
      final plan = await HighFreqWakeWindow.planNow(
        scheduledWindowEnd: armed?.windowEnd,
        scheduledWindowMinutes: armed?.minutes ?? 0,
      );
      final target = plan.targetWake;
      final req = BandPromptPolicy.plan(
        smartWake: plan.shouldEnable && target != null
            ? BandPromptRequest.smartWake(
                target: target,
                lease: HighFreqWakeWindow.lease,
                source: plan.source,
              )
            : null,
        iosBackgrounded: _background && Platform.isIOS,
        currentReason: engine.highFreqReason,
        currentUntil: engine.highFreqUntil,
        now: DateTime.now(),
      );
      if (req == null) {
        await engine.applyHighFreqWakeWindow(
          enabled: false,
          targetWake: null,
          reason: plan.source,
        );
      } else {
        await engine.applyHighFreqWakeWindow(
          enabled: true,
          targetWake: req.until,
          duration: req.duration,
          intervalSeconds: req.intervalSeconds,
          reason: req.reason,
        );
      }
      _log(
        '[SYNC] Band prompt: smartWake=${plan.shouldEnable} '
        '(source=${plan.source} samples=${plan.sampleCount}) '
        'iosBackground=${_background && Platform.isIOS} → '
        '${req == null ? 'off' : req.toString()}',
      );
    } catch (e) {
      _log('[SYNC] Band prompt refresh skipped: $e');
    }
  }
```

`Platform` is already imported in `app_state.dart` (used by `_liveOwners`). `sync_policy.dart` is already imported (grep `import '../sync/sync_policy.dart'`; add it if absent).

- [ ] **Step 2: Arm on backgrounding**

In `pauseForBackground()`, inside `if (!Platform.isIOS) return; if (engine.isConnected) { … }`, replace:

```dart
    if (engine.isConnected) {
      IosBleRestore.foregroundActive =
          true; // "app owns the band" — don't let restore compete
      await IosBleRestore.setOwnsBand(true);
      _log(
        'Backgrounded — holding live connection for continuous background capture',
      );
    } else {
```

with:

```dart
    if (engine.isConnected) {
      IosBleRestore.foregroundActive =
          true; // "app owns the band" — don't let restore compete
      await IosBleRestore.setOwnsBand(true);
      // The live stream is off now (see _liveOwners); ask the band to prompt
      // us instead. Each prompt is one BLE notification → one wake → one
      // flash offload → suspend again. This is what keeps continuous capture
      // going without the 1 Hz stream.
      await _refreshHighFreqWakeWindow();
      _log(
        'Backgrounded — live stream off; band prompts every '
        '${kIosBackgroundPromptIntervalSeconds}s keep the offload going.',
      );
    } else {
```

Update the doc comment above `pauseForBackground` (lines ~2770–2786). Replace the paragraph starting "So we DELIBERATELY keep the live connection + streams up here" with:

```dart
  /// So we DELIBERATELY keep the live CONNECTION up here instead of
  /// disconnecting — but not the live STREAMS. The 1 Hz realtime-HR stream
  /// used to be held purely so iOS would resume us once a second; that was
  /// ~86,400 wakes a day and most of a day's battery. Now the band is asked
  /// to prompt us every [kIosBackgroundPromptIntervalSeconds] (its
  /// HIGH_FREQ_SYNC mode); each prompt event resumes the process, the engine
  /// drains the flash, and the process suspends again.
```

- [ ] **Step 3: Disarm on foreground reclaim**

In `openSession()`'s fast-reclaim branch (the block ending with `_nudgeLive(); unawaited(foregroundCatchUp()); _startBackfillTimer(); return;`), add one line after `_nudgeLive();`:

```dart
        _nudgeLive();
        // `_background` flipped: drop the background band prompt (the
        // smart-wake window, if open, keeps its own).
        unawaited(_refreshHighFreqWakeWindow());
```

The full-connect path below it already calls `_refreshHighFreqWakeWindow()` in its post-connect block, as does the background reconnect path (`_reconnect`, line ~5144). No change there.

- [ ] **Step 4: Fix the stale comment on the reconnect path**

At line ~5148 (`_reconnect` post-connect block) change

```dart
          // Live streams come up per the current owners (see _liveOwners:
          // backgrounded with no owner is OFF on Android and HR-only on iOS);
```

to

```dart
          // Live streams come up per the current owners (see _liveOwners:
          // backgrounded with no owner is OFF on both platforms);
```

- [ ] **Step 5: Analyze and run the suites touched so far**

Run: `flutter analyze`
Expected: no issues.

Run: `flutter test --concurrency=1 test/band_prompt_policy_test.dart test/gen5_wiring_test.dart test/alarm_test.dart test/high_freq_wake_window_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/state/app_state.dart
git commit -m "ios: ask the band to prompt every 15 min while backgrounded"
```

---

### Task 7: AppState — probe a quiet link on resume instead of tearing it down

**Files:**
- Modify: `lib/state/app_state.dart` — `openSession` (line ~4913–4948), `foregroundCatchUp` (line ~5273–5285)

**Interfaces:**
- Consumes: `resumeLinkAction`, `ResumeLinkAction` (Task 2), `engine.probeLink()` (Task 5), `engine.sinceLastRx`, `engine.liveEnabled`.
- Produces: `Future<bool> _linkUsableAfterResume(String where)` (private).

- [ ] **Step 1: Add the shared helper**

Directly above `openSession()` add:

```dart
  /// Whether a link that still reports connected may be reused after the
  /// process was not watching it (foreground resume, BG-task wake).
  /// Fresh → yes. Quiet with a live stream armed → no: a stream that stopped
  /// is a dead link. Quiet with NO stream armed → ask the band
  /// (`probeLink`) rather than guess — an iOS process suspended between band
  /// prompts sees minutes of silence on a perfectly healthy link, and
  /// tearing it down on every foreground open would cost a reconnect and a
  /// full re-drain each time. ONE helper for both resume sites so the two
  /// cannot drift (AGENTS §4.7).
  Future<bool> _linkUsableAfterResume(String where) async {
    final quiet = engine.sinceLastRx.inSeconds;
    switch (resumeLinkAction(
      engine.sinceLastRx,
      liveStreamArmed: engine.liveEnabled,
    )) {
      case ResumeLinkAction.trust:
        return true;
      case ResumeLinkAction.reconnect:
        _log('$where: no BLE data for ${quiet}s with a live stream armed — '
            'stale link, reconnecting.');
        return false;
      case ResumeLinkAction.probe:
        final ok = await engine.probeLink();
        _log('$where: quiet link (${quiet}s, no stream armed) — probe '
            '${ok ? 'answered, reusing the link' : 'unanswered, reconnecting'}.');
        return ok;
    }
  }
```

- [ ] **Step 2: Use it in `openSession`**

Replace

```dart
      if (!isLinkStale(
        engine.sinceLastRx,
        liveStreamArmed: engine.liveEnabled,
      )) {
```

with

```dart
      if (await _linkUsableAfterResume('Resume')) {
```

and delete the now-duplicated log after that block:

```dart
      _log(
        'Resume: no BLE data for ${engine.sinceLastRx.inSeconds}s — stale link, reconnecting.',
      );
```

(keep the `await engine.disconnect();` that follows it). Update the comment above the `if` — replace "Trust DATA, not the flag: if a notification arrived recently the link is genuinely live → keep the fast reclaim. Otherwise it's stale → tear it down" with "Trust DATA, not the flag: a recent notification proves the link; a quiet link with no stream armed is asked (probe); a quiet link that should have been streaming is torn down".

- [ ] **Step 3: Use it in `foregroundCatchUp`**

Replace

```dart
    if (isLinkStale(
      engine.sinceLastRx,
      liveStreamArmed: engine.liveEnabled,
    )) {
      _log(
        'Foreground catch-up: no BLE data for ${engine.sinceLastRx.inSeconds}s '
        '— zombie link, forcing reconnect instead of a stale-link pull.',
      );
      await engine.disconnect();
      return;
    }
```

with

```dart
    if (!await _linkUsableAfterResume('Foreground catch-up')) {
      await engine.disconnect();
      return;
    }
```

- [ ] **Step 4: Confirm `isLinkStale` has no other AppState callers**

Run: `grep -n "isLinkStale" lib/state/app_state.dart`
Expected: no output. (`grep -rn isLinkStale lib` should show only `sync_policy.dart` and `sync/background_sync.dart` if the headless path uses it; leave the headless path alone — it connects fresh and never resumes a held link.)

- [ ] **Step 5: Analyze, run the full suite**

Run: `flutter analyze`
Expected: no issues.

Run: `flutter test --concurrency=1`
Expected: PASS (replay tests skip without `whoop_hist.jsonl`; that is expected).

- [ ] **Step 6: Commit**

```bash
git add lib/state/app_state.dart
git commit -m "ios: probe a quiet link on resume instead of reconnecting"
```

---

### Task 8: Hardware verification, docs, PR

**Files:**
- Modify: `docs/superpowers/specs/2026-09-21-ios-background-wake-design.md` (status line only)
- No code.

- [ ] **Step 1: Build to a real iPhone with a WHOOP 4.0**

```bash
flutter run --release --dart-define-from-file=.env
```

Pair (quit the official WHOOP app first), confirm "Listening" in the app, then background it and leave the phone overnight (screen off, not charging for at least a few hours so the battery screen is meaningful).

- [ ] **Step 2: Pull the log and check the four markers**

Files app → On My iPhone → Edge → `openstrap_sync.log` (and `.1`). Share it to the Mac and run:

```bash
grep -c "HighFreq prompt received" openstrap_sync.log
grep -n "Band prompt:\|HighFreq enter\|HighFreq exit" openstrap_sync.log | tail -20
grep -c "Backlog drained\|records pulled" openstrap_sync.log
grep -n "bouncing the link\|Connection dropped\|stale link\|resumed after\|\[probe\]" openstrap_sync.log | tail -30
```

Expected:
- `HighFreq enter (ios_background)` once per backgrounding / lease renewal, and `HighFreq prompt received` about 4 per hour of background.
- One drain per prompt.
- No `bouncing the link` / `Connection dropped` repeating on the 15-min cadence. If they do repeat: the band's idle policy is shorter than 900 s → lower `kIosBackgroundPromptIntervalSeconds` (try 300), re-run Task 1's test expectations for the new value, re-verify.
- If `HighFreq enter (ios_background)` is logged but no prompts ever arrive: gen4 rejected the values → try `intervalSeconds: 300` and/or a shorter lease (`Duration(minutes: 90)`), re-verify.
- On the next foreground open: `[probe] battery poll answered` and `Resume: quiet link … reusing the link`, not `stale link, reconnecting`.

- [ ] **Step 3: Read the battery screen**

Settings → Battery → last 24 h → Edge. Record On screen / Background minutes and the percentage. Before this change the user's phone showed 62 %, 20 min on screen, 16 h 35 min background. Expect background time in minutes.

- [ ] **Step 4: Smart-wake regression (one alarm night)**

Enable smart wake for one weekday alarm, background the app overnight. Next morning:

```bash
grep -n "\[smart-wake\]\|Band prompt: smartWake=true" openstrap_sync.log | tail
```

Expected: the window arms with `reason` = the plan source at 61 s, and `[smart-wake]` check lines appear during the window (the early buzz only if light sleep was detected; the fallback alarm fires regardless).

- [ ] **Step 5: Mark the spec and commit**

Change the spec's `Status:` line to `Status: implemented on branch ios-background-band-prompts; hardware-verified <date> (see PR)`.

```bash
git add docs/superpowers/specs/2026-09-21-ios-background-wake-design.md docs/superpowers/plans/2026-09-21-ios-background-wake.md
git commit -m "docs: iOS background band-prompt design and plan"
```

- [ ] **Step 6: Open the PR**

```bash
git push -u origin ios-background-band-prompts
gh pr create --base main --title "ios: wake on band prompts instead of holding a 1 Hz HR stream in background" --body-file - <<'EOF'
## Why

On iOS the app kept the band's realtime-HR stream on the whole time it was backgrounded, purely so the inbound 1 Hz notification would keep the suspended process schedulable (`_liveOwners` → `iosBackgroundKeepalive`). That is ~86,400 process wakes a day. On a real phone: Edge at 62 % of the day's battery with 20 min on screen and 16 h 35 min "Background" (screenshot below). Android hit the same drain in #200 and already runs with the stream off in background.

## What

- The iOS background owner of the HR stream is removed; background owns nothing on either platform (workouts, breathing and a mounted live-HR view still own HR as before).
- While backgrounded on iOS the band is asked to prompt us every 15 min via its existing HIGH_FREQ_SYNC mode (`ENTER_HIGH_FREQ_SYNC`, 2 h lease renewed past half-way). The engine already turned that prompt event into a `BackfillTrigger.strap` flash offload; now it is also the wake source. Decision lives in `BandPromptPolicy` (`sync_policy.dart`), which also owns the smart-wake window's existing 61 s request (unchanged bytes).
- Two liveness decisions learn about suspension: the keep-alive fuse ignores silence that accumulated while no tick could run (`livenessSilence`) and probes instead; resume paths probe a quiet link with no stream armed (`resumeLinkAction` + `BleEngine.probeLink`) instead of tearing it down on every foreground open.

No native change, no protocol change, no `kAlgoVersion` bump (nothing derived changes).

## Before / after (user-visible)

- Before: Settings → Battery shows hours of Background time for Edge every day.
- After: minutes. "Last data" in background lags up to 15 min instead of ~1 min; the widget's battery % updates on each prompt.

## How I verified it

- `flutter analyze` + `flutter test --concurrency=1` green.
- iPhone <model/iOS> + WHOOP 4.0 fw <version>, <N> h backgrounded overnight: `HighFreq prompt received` every ~15 min, one drain each, no link bounces (log excerpt attached). Battery screen next day: <x> % / <m> min background.
- One smart-wake alarm night: window armed at 61 s, `[smart-wake]` checks ran.
- Foreground reopen after hours: probe answered, fast reclaim, no reconnect.

## Open question for maintainers

gen4's accepted range for the 0x60 interval/duration is undocumented; 900 s / 2 h worked on my band. If a different band drops the link sooner, `kIosBackgroundPromptIntervalSeconds` is the one knob.

Design: `docs/superpowers/specs/2026-09-21-ios-background-wake-design.md`
EOF
```

Fill in the `<…>` placeholders from Steps 2–4 before submitting. Attach the battery screenshot. Do not add a `Co-Authored-By` line.

---

## Self-review

**Spec coverage:** §4.1 → Task 3. §4.2 → Task 1. §4.3 → Task 6 (all call sites named). §4.4(a) → Task 4. §4.4(b) → Tasks 2, 5, 7. §4.5 (unchanged items) → nothing to do; Task 6 Step 4 fixes the one stale comment. §4.6 → Task 8 Step 2 decision table. §5 tests → Tasks 1–5, 3; hardware → Task 8.

**Placeholder scan:** the only `<…>` are in the PR body and are explicitly filled from Task 8 measurements.

**Type consistency:** `BandPromptPolicy.plan(smartWake:, iosBackgrounded:, currentReason:, currentUntil:, now:)` — same in Tasks 1 and 6. `engine.highFreqReason` / `highFreqUntil` — Task 5 defines, Task 6 uses. `resumeLinkAction(Duration, {required bool liveStreamArmed})` — Tasks 2 and 7. `probeLink({Duration timeout})` — Tasks 5 and 7. `debugSetLiveness({lastRx, lastKeepAliveTick})` / `debugFireKeepAlive()` — Task 4 only.
