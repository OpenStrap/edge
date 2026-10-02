# Proposal: a `vendor_staged` sleep source

Status: open question for the owner. Nothing here is implemented.

## What it would bend

1. `observation` is never an input to a derivation (OBSERVATION_SPEC §3,
   enforced by `test/observation_isolation_test.dart`). A vendor hypnogram
   banked as observations would be read back into the pipeline.
2. `InputSignal` names inputs, never outputs (`lib/ble/adapters/signals.dart`).
   A vendor hypnogram is a vendor output.

## The idea

Today the main-sleep window comes from (`lib/compute/substrate.dart`):

```
user override (manual / confirmed / rejected) > auto (van Hees) > auto_fallback (HR-led) > none
```

The proposal adds one rung:

```
user override > vendor_staged > auto > auto_fallback > none
```

Why a hypnogram and not other vendor numbers: a sleep score or readiness is
a composite with no method we can describe. A hypnogram is a window plus a
per-epoch stage label, the same shape as our own `stages4`, so it can be
cross-checked against our staging night by night. Agreement is not
validation (both can be wrong the same way); only PSG validates either.

Our own staging is not a high bar: on DREAMT the pre-#34 rules scored
kappa 0.036 and the current rules 0.132 held-out (analytics
`cardio_stager.dart`).

The user override keeps priority. A vendor window the user corrects is
corrected through the existing `sleep_override` flow in `sleep_detail.dart`.

## Conditions before it ships

1. A ring we own has produced hypnogram frames that decode correctly with
   our decoder. The layout is unverified on Ring 4/5.
2. A table for the epoch series. `observation` stays scalars only
   (`db.dart`), so the hypnogram gets its own table when this has a reader.
3. The pipeline reads that table, never `observation`, so the isolation
   test still holds.
4. A vendor-staged night is labelled as vendor-staged wherever our staging
   renders. Showing a vendor window as our own detection is the failure to
   avoid.

## Out of scope

- A general "trust vendor numbers" rule.
- Any change in `analytics`; it stays device-blind (OBSERVATION_SPEC §4). The
  hypnogram would enter at the substrate layer, like the user override.
- Ownership changes. Which device owns a signal stays with
  `_resolveOwnership` (`signal_priority`, primary device by default).

## Doing nothing

This is the current state and costs nothing: #468 banks the per-stage
minutes as attributed vendor scalars, the epoch frames stay in
`raw_archive`, and this source can be built from those bytes later.
