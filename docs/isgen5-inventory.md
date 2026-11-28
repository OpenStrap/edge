# `isGen5` inventory — DATA vs BEHAVIOUR

Every band-specific branch in `lib/ble/ble_engine.dart`, classified — and, as
of the D4/D9 wave, **the DATA half is done**: it lives in `BandEntry` /
`BandWireCommands` in `lib/ble/adapters/_registry.dart` and the code around it
is unconditional.

Line numbers are against `ble_engine.dart` at **6,854 lines** (post-split).
Re-derive them before acting — this file rots, and the previous revision's
numbers had drifted by +21 to +23 while claiming 30 occurrences when there
were 44.

**DATA** — the branch chooses a *value*: an opcode, a payload, a delay, an
offset, a flag. It belongs in the registry entry; the code around it becomes
unconditional.

**BEHAVIOUR** — the branch chooses a *different sequence of operations*: an
extra handshake step, a different decoder, a different failure policy. It
belongs in an adapter — except there is no adapter to put it in: the
`run(BandLink)` move was DECLINED (ASSUMPTIONS G1–G4), so behaviour stays in
the engine, deliberately, and this file no longer pretends otherwise.

**Counts, re-derived: 21 lines mention `isGen5`, from 44.** The unit is a LINE
matching `isGen5` and not matching `isGen5Clock` — `grep -c isGen5` reports 24
here and 47 on main, and the three-line difference either end is `isGen5Clock`,
which is not a band branch at all (last section). The previous revision counted
one number each way and the breakdown could not add up.

Sixteen logical sites moved to the table. The 21 that are left:

| Lines | What |
|---|---|
| 11 | 9 BEHAVIOUR sites (one of the eleven is a comment) |
| 4 | already-table-driven policy arguments |
| 2 | the `final isGen5 = …` locals that feed two of those arguments |
| 4 | log strings — 2 sites, a declaration and a use each |

---

## MOVED — the table (16 sites)

Every value is transcribed verbatim from the arm it replaced and pinned in
`test/band_registry_test.dart` ("the gen4/gen5 arm of every branch that moved").

| Line | Site | Field it reads now | gen4 → gen5 |
|---|---|---|---|
| 2135 | pre-registration pause | `BandEntry.preRegistrationDelay` | `Duration.zero` → 600 ms |
| 2333 | post-registration pause | `BandEntry.postRegistrationDelay` | `Duration.zero` → 500 ms |
| 2446 | `_bootstrapSetClock` | `BandEntry.setClockDriftGated` | `false` → `true` |
| 2585 | keep-alive live re-arm | `BandWireCommands.r10R11Realtime` | `0x3F` → `null` |
| 3234 | `_offloadPayload` | `BandWireCommands.offloadBody` | `[0x00]` → `[]` |
| 3467 | console-log line | `BandEntry.logsConsoleOutput` | `false` → `true` |
| 4610 | `gateEnforced` | `BandEntry.burstCountGateEnforced` | `false` → `true` |
| 5863 | `getStrapName` | `getAdvertisingName` + `…Body` | Harvard/`[0x00]` → custom/`[rev1]` |
| 5877 | `setStrapName` | `setAdvertisingName` | Harvard → custom (body shared) |
| 5888 | `getHello` | `hello` + `helloBody` | Harvard/`[0x00]` → `0x91`/`[0x01]` |
| 5929 | `enableLiveStreams` R10/R11 | `r10R11Realtime` | send → omit |
| 5943 | `enableLiveStreams` optical | `opticalDataIsLiveToggle` | `true` → `false` |
| 5948 | `enableLiveStreams` log | `opticalDataIsLiveToggle` | string unchanged |
| 5981 | `enableHrOnlyLive` | `r10R11Realtime` | send → omit |
| 5999 | `disableLiveStreams` | `r10R11Realtime` | send → omit |
| — | the two delays themselves | `kGen5Pre/PostRegistrationDelay` | moved out of `BleEngine` into `_registry.dart`; one copy, not two |

**Two of these are the rows marked DO NOT UNIFY, and they still are.**
`setClockDriftGated` and `burstCountGateEnforced` are `false` on WHOOP 4 because
its unconditional SET_CLOCK is the proven flow and an enforced burst gate on a
band whose count semantics nothing has pinned is a permanent stall (15 failures
→ abort → Stuck). Moving a flag is not flipping it; both comments travelled with
the field and are repeated on the field's own doc.

## BEHAVIOUR — stays in the engine (9 sites, 11 lines)

| Line | Site | What actually differs |
|---|---|---|
| 2363 | `_readGen5Hello()` in `_bootstrapAfterRegistration` | An extra handshake round-trip with its own link-death abort, ordered before the clock read. |
| 2469 | `_readAdvertisingNameGen5` | A gen5-only setup command with its own "not a readiness gate" failure semantics. |
| 2496 | `_maybeStartBatteryPackFollowUp` | A gen5-only background task with its own retry schedule and once-per-session latch. |
| 3635–3674 | historical record dispatch | `decodeGen5HistoricalSample` vs the gen4 version-routed chain, and which kinds fall through to `raw_archive`. |
| 5134 | `_enableGen5DeepBuffers` | A gen5-only multi-frame `SET_FF_VALUE` sequence behind the one audited `allowDangerous: true`. |
| 5160 | `sendInit` | Two INIT state machines in one method. Biggest single item — **and it writes host connection-priority state**: its `finally` clears `_connectSetup`, and a throw above that clear leaves the link pinned at setup priority for the whole connection with `_applyLinkPriority` early-returning forever. That is host state; it does not become data. |
| 5734 | `setAlarm` pre-arm | gen5 issues SET_CLOCK + a 120 ms settle before arming. A sequence, not a payload. |
| 5833 | `runAlarm` | Opcode swap **plus a computed body** — see below. |
| 5898 | `buzzPattern` | Opcode swap **plus a computed body** — see below. |

## NOT MOVED, and why — the honest boundary

**`runAlarm` (5833) and `buzzPattern` (5898) — DATA that a `const` table cannot
hold.** Both pick opcode *and* body. gen5's body is
`AlarmPayloads.gen5MaverickBuzz()`, a computed list; `kWhoopGen4`/`kWhoopGen5`
are `const`, so a field could only hold the twelve bytes transcribed into a
second place — which is exactly the duplication a named constant exists to
prevent. Moving the opcode alone would leave the body branch anyway, so both
stay whole.

**The four `AlarmPayloads` discriminators (5756, 5819, 5852, and `setAlarm`'s
own 5733) are already table-driven.** They are not branches in the engine; they
are one named ARGUMENT to a pure policy in `ble_state.dart` that already selects
by band. Widening `isGen5:` to take the entry moves no decision, and that file is
owned elsewhere. Left alone.

**Two sites, four lines, are log text only** — 5353/5364 (`SET_CLOCK (gen5)`)
and 5764/5768 (the alarm log), each a `final isGen5 = …` and its use. The
live-stream log used to be a third and is keyed off `opticalDataIsLiveToggle`
now, so it reads `isGen5` no more. Changing any of them changes a user-visible
log line with no wire meaning.

**`_maybeAugmentClockEpoch` (6206/6207/6223) is NOT a band branch — the previous
revision got this wrong.** It reads `op == Cmd.getClockGen5` on the *received*
response, not `session.band`, and edge sends `Cmd.getClock` (11) on both bands.
It mirrors protocol's own `control.dart:928` (`op == Cmd.getClockGen5 ? 3 : 2`).
Keying the offset off the session band would change behaviour for a `147` reply
on either link and would diverge from the parse it exists to patch. Left as is,
and it is why the count above excludes `isGen5Clock` at both ends: three lines
here, three on main, and neither number is about the band.

## What this wave actually cost

One new type (`BandWireCommands`, eight fields), five new `BandEntry` fields,
two constants relocated. No new mechanism, no capability booleans about our own
features, no command DSL: `r10R11Realtime` being `null` is an ABSENT COMMAND,
not a `supportsX()` claim, and it is the only field that decides whether
something happens rather than what gets sent.
