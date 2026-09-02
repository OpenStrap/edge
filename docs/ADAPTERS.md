# Writing a band adapter

An adapter is `lib/ble/adapters/adapter.dart`'s `BandAdapter`: an `entry`
(identity — service UUID, characteristics, the registry row), a `signals`
declaration, and one `run(BandLink)` that yields `BandEvent`s. Nothing else.

## The size difference, both real numbers

- **A live-only notify sensor**: `ble_hrs.dart` is **84 lines** — no
  handshake, no clock, no INIT, one `notify()` subscription decoded straight
  into `SampleBatch`s. This is the honest floor for "how little an adapter can
  be", and it is the shape almost every future band should aim to stay near.
- **A framed, authed, offloading band** (gen4/gen5): the drain policy alone —
  `SeqAllocator`, `CounterRegressionDetector`, `AckRetryPolicy`,
  `TrimAckPolicy`, `BurstTrimGuard` and their neighbours in `ble_state.dart`,
  plus the connect/bond/MTU/INIT/offload state machine in `ble_engine.dart` —
  is easily **1,000+ lines**, and `ble_engine.dart` alone is over 8,000. That
  is the real cost of a band with a clock to set, a handshake to pass, a flash
  buffer to drain and trim, and a safe-trim invariant to never get wrong.

Neither number is a target. A band that is genuinely live-only should cost
close to 84 lines; a band that offloads history should expect to pay
something like the second number, not be squeezed into the first.

## iOS: only the primary device gets background restore

`BleRestoreManager.swift`'s restore `CBCentralManager` and the
AccessorySetupKit provisioning flow exist for the ONE primary band — the
device the offload engine drives and the device iOS is told about at pairing.
A second, notify-only sensor (a chest strap, a ring paired alongside the band)
connects live from its stored remote id while the app is foregrounded, and
does **not** get iOS's background relaunch-on-drop treatment. Concretely: a
paired second sensor syncs while the app is open, and goes quiet the moment
the app is backgrounded or killed, until it is reopened. This is a real,
current limitation — state it to a user (or a future contributor) directly
rather than let it be discovered through a bug report about missing overnight
strap data.

## Declare INPUTS, never capability booleans

`signals.dart`'s whole header explains why: a capability boolean
(`supportsSpo2()`) names an OUTPUT, so metric N+1 widens every adapter's
interface and turns a new metric into a change with a blast radius the size of
the device count. A signal names a physical INPUT — `InputSignal.rrIntervals`,
`hr1Hz`, `accel1Hz`, `skinTempRaw`, and so on — that is true independent of
any metric anyone has written yet.

`adapter.dart`'s own doc on `BandAdapter.signals` (around the class's
`signals` getter, near the `A declared-but-absent signal is WORSE than a
missing one` note) states the asymmetry directly: an UNDECLARED signal makes
every dependent metric abstain, cleanly, through the absence contract that
already exists everywhere in this codebase. A DECLARED-BUT-ABSENT signal is
worse — it tells every dependent metric "this input exists" and then hands it
nothing, which is a silent wrong answer rather than a clean refusal.

There is deliberately **no** `ecg` / `ppgWaveform` member on `InputSignal`
(`signals.dart`'s closing comment says so explicitly). `decoded_onehz` is one
row per second and raw prunes at three days — a waveform has nowhere to live
today. Adding the member before a store exists for it would let an adapter
declare a capability with nothing behind it, which is exactly the
declared-but-absent trap above. Build the store first.

## Where an adapter may NOT reach

Enforced by `test/observation_isolation_test.dart` and the seams it guards:

- **No `observation` table access of its own.** An adapter that has numbers
  the band computed itself yields a `VendorScalars` event; the HOST (`M1`'s
  `BandHost`, in `lib/ble/adapters/host.dart`) is the only thing that calls
  `LocalDb.putObservations`, outside the commit-then-confirm chain and
  best-effort, because a vendor scalar is not substrate and must never hold up
  the flash release a real offload ACK earns.
- **No `decoded_*` insert of its own.** The host commits every `SampleBatch`
  through the same durable path every other device uses
  (`commitSyncBatch` / `commitNativeBatch`); an adapter that wrote directly
  would bypass the safe-trim invariant (commit before ACK, verbatim-token
  echo) that the whole offload design exists to protect.
- **No `attribution` the host invents.** `Observation.attribution` is what a
  user reads next to a vendor number — "Oura", "Amazfit" — and it is not
  renderable without one. The adapter that knows which vendor it is supplies
  it; the host never guesses one to fill a gap.
