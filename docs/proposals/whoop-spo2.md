# Proposal: WHOOP SpO2 (blood oxygen) — evidence review and staged plan

Status: proposal only, no code yet. Written so other contributors can build on
the current state of `protocol` and `edge` without re-doing this research.

## Process (what was done, openly)

1. Collected the existing claims about the 96-byte realtime packet on the data
   characteristic: SpO2 at byte 5 (range gate 50–100), CRC-32
   (poly 0x04C11DB7, xor-out 0xF43F44AC) at bytes 92–95. Single source,
   unverified.
2. Checked which claims more than one independent source agrees on, and which
   rest on a single source.
3. Compared with what our own repos already know: `protocol` (`live.dart`,
   `records.dart`, `gen5_records.dart`), `whoop-rs` (`whoop-protocol/src/live.rs`,
   `spo2_from_paired`, v18 `spo2_pct`), `edge` (`ble_engine.dart`,
   `adapters/whoop_gen4.dart`, `adapters/signals.dart`).

What was NOT done: no real-device captures, no ground-truth comparison against a
reference oximeter, no CRC verification against our own captures. Everything
below that is not marked "verified in our repos" is an unverified claim with
the confidence level stated.

## Findings by generation

### WHOOP 4.0 — no secured SpO2

- Byte 5 of the 96-byte realtime packet is claimed to be SpO2 %. Single
  source, no ground truth, only a 50–100 plausibility gate.
- The same source says blood oxygen on the 4.0 is only measured once a day,
  during sleep, so byte 5 is expected to carry a value only inside sleep windows
  and 0/invalid otherwise. Unverified.
- Our `protocol` repo verified that `spo2RedRaw`/`spo2IrRaw` (inner 64/66) move
  in lockstep with a fixed offset: a red/IR ratio from them tracks channel drift,
  not oxygenation (`records.dart` explicitly forbids building SpO2 on them).
  whoop-rs therefore only computes a ratio-of-ratios estimate on paired v24
  windows and never a calibrated %.
- Open discrepancy: the single source maps the data stream to characteristic
  `61080004-…`, while whoop-rs maps `GEN4_DATA` to `61080005-…` and `…0004` to
  EVENTS (`whoop-client/src/uuids.rs`). One mapping is off by one; must be
  resolved against our own captures before any wiring.
- Constraint from edge AGENTS.md invariant 14: live high-rate streams are
  RAM-only, never persisted. That rules out persisting the stream, NOT a
  day metric: an in-memory aggregate over a validated sleep window can still
  produce a nightly value without persisting anything. Whether Gen4 ever gets
  a nightly metric is decided by validation + coverage, not by invariant 14
  alone.

### WHOOP 5.0 / MG — sleep-only, agreement with the vendor app unverified

- v18 historical records carry the strap's own computed SpO2 % at frame-abs
  byte 82 (= `inner[74]`), which our `protocol` already exposes as
  `spo2CandidateRaw` (`gen5_records.dart`) but deliberately does not publish as
  a percentage.
- Measurement schedule, reported by more than one independent source: 30 s
  measurement bursts every 1,200 s, only while the band declares sleep. 5/MG is
  reported to never send red/IR raw channels. Not verified by us.
- Reported comparison with the vendor app: nightly means 93.4–96.7 vs
  WHOOP's own 93.1–96.5 over the same weeks (period means 94.4 vs 94.8). No
  night had both readings, so this stays an estimate, not a validation.
- No usable offline derivation from raw PPG on 5.0: time multiplexing alone
  would NOT make SpO2 impossible (pulse oximeters alternate red/IR), but the
  decoded Gen5 data has no identified red/IR channel pair and the optical
  channel bursts are widely separated in time — so no derivation path is
  available from what we can decode. The byte-82 device value is the only
  usable source.
- Encoding unknown. Treat byte 82 as an opaque byte until a validation run
  pins its encoding; this is why `spo2Candidate` is deprecated.

## Self-critical assessment

- "Matches the WHOOP app" is agreement, not validation; only a reference
  oximeter (or PSG-grade device) validates. We state this explicitly, following
  the precedent in `vendor-staged-sleep.md`.
- The gen4 byte-5 claim is single-source; the sleep-only measurement reports
  do NOT contradict it (a realtime packet can carry SpO2 only during sleep,
  which is consistent with the claim). It stays unverified because it has one
  source and no ground-truth validation.
- No project anywhere publishes a live (daytime) SpO2 for any WHOOP
  generation. The realistic product surface is a nightly sleep SpO2 for
  5/MG, plus at most a raw/diagnostic byte for gen4.
- All sources agree the raw ADC channels cannot yield SpO2; any PR deriving %
  from red/IR on 4.0 contradicts our own verified findings and should be
  rejected.
- Relation to merged PR #472: its import surface already owns the `spo2`
  MetricSpec (suppressed row, vendor-import provenance, not charted). Live
  band-derived SpO2 must NOT create a second `spo2` row or chart key —
  provenance (vendor import vs band-derived) stays separate. Our raw capture
  (`Sample.spo2CandidateRaw`) is deliberately unread until the gate passes;
  the single publication path afterwards is `Spo2Data` in
  `lib/models/payloads.dart`.

## Staged plan (proposed)

1. **protocol** — raw, gated decode only:
   - Keep `spo2CandidateRaw` as-is. Do not document any interpretation of the
     byte until the validation workstream pins its encoding; it stays labeled
     candidate until validated.
   - Add a decoder for the 96-byte realtime packet exposing byte 5 as **raw +
     CRC flag only** — no percentage publishing. Resolve the characteristic
     UUID discrepancy from real captures first.
   - Tests from real frames; extend parity fixtures where applicable.
2. **whoop-rs** — DEFERRED. Current scope is `protocol` + `edge` + `analytics`
   (analytics owns the nightly metric, see step 3); only whoop-rs is out of
   scope for now. When picked up: mirror the decoders in `whoop-protocol` (live 96-byte packet,
   v18 byte 82 interpretation), expose raw values via `whoop-ffi`; keep the
   existing `spo2_pct` v18 and `spo2_from_paired` paths unchanged.
3. **edge** — pass through the band-reported `deviceSpo2` samples for
   gen5/5.0/MG; the per-burst medians and the nightly mean are computed in
   `OpenStrap/analytics` (a metric, not signal wiring — AGENTS.md assigns
   metrics there), labeled as a device estimate, same labeling discipline as
   `vendor_staged`.
   - After the gate passes: feed `Sample.spo2CandidateRaw` into `Spo2Data`
     (`lib/models/payloads.dart`) as the single publication path — no separate
     display path, no second `spo2` metric row (see #472 note above).
   - NO user-facing display on either generation until the validation
     workstream lands: gen5 byte 82 stays raw until its encoding (bit-7 flag)
     is pinned and validated against a reference device; gen4 byte 5 stays
     diagnostic, never user-facing, until ground-truth validated.
   - Diagnostics stay RAM-ONLY, never in `_log`/FileLog. FileLog persists to
     disk (`lib/sync/file_log.dart`). Check where it lands on each Android
     version before claiming who can read it; regardless of readability the
     data would still be PERSISTED, which is the reason health diagnostics stay
     in RAM.
   - Respect invariants: live streams RAM-only (inv. 14), never fabricate a
     metric (inv. 3), bump `kAlgoVersion` when any output changes (inv. 4).
4. **Validation workstream** (prerequisite for ANY user-facing SpO2 value,
   both generations): paired measurements against a reference oximeter over
   at least 10 nights / 30 paired samples across at least 3 distinct wearers (one
   wearer's nights can satisfy the counts alone, so the wearer minimum is
   separate); the display gate opens only when
   accuracy criteria are met — MAE <= 2 pp AND |mean bias| <= 1 pp AND
   Bland-Altman 95% limits of agreement within +/-4 pp. Correlation
   (Pearson/Spearman) is reported separately and is NEVER treated as proof of
   accuracy. Burst-level pairs are NOT sufficient: the gate must also compare
   the actual NIGHTLY OUTPUT (our aggregation over the band-declared sleep
   window, burst weighting included) against the reference aggregated over the
   same night, because burst-level agreement can pass while the nightly
   calculation uses the wrong window or weights. COVERAGE REQUIREMENT (else a
   constant estimate passes by construction): reference samples must span the
   saturation range (e.g. stratified bins across 85–100%) and participants must
   be representative (FDA oximeter guidance explicitly calls out skin
   pigmentation); accuracy is assessed per range/group, and a degenerate
   constant estimate (all reference samples ~97%) must NOT open the gate.
   BURST COVERAGE: the reference must provide time-aligned readings for EVERY
   burst used in the nightly aggregate — sparse reference samples can match the
   nightly device output while missing errors during most of the night — and
   MINIMUM SLEEP-WINDOW COVERAGE must be defined with an independent check for
   omitted bursts before approving a nightly estimate (data loss leaving only a
   few bursts must not pass the gate). WINDOW MEMBERSHIP: included/excluded
   bursts are checked independently against the band-declared sleep boundaries,
   and the reference aggregate is constructed from the correct window — two
   aggregates sharing the same WRONG window can match each other. WEIGHTS: the
   expected burst weights are defined independently and the implementation is
   checked against them; the reference aggregate must NOT copy the device's
   weights (e.g. bursts of 90/90/99 with weights 1/1/8 yield 97.2 instead of
   the equal-weight mean 93 — a weighting defect the copied weights would
   conceal). Gen4 has NO nightly SpO2 output —
   its byte 5 is a live-stream byte only — so any Gen4 display gate must
   instead use time-aligned LIVE reference measurements (same accuracy
   thresholds: MAE <= 2 pp, |bias| <= 1 pp, 95% LoA within +/-4 pp), never the
   nightly gate. If Gen4 LATER gains a nightly metric (in-memory aggregate over
   a validated sleep window), that nightly output must be validated exactly
   like the Gen5 one — against the reference aggregated over the same window —
   because accurate live samples alone cannot detect wrong window selection or
   weighting. Plus: byte-82 encoding pin-down, UUID discrepancy resolution.

## Publication path after the gate (explicit)

The gate and the publication path are separate concerns; both are specified
here so the gate is evaluable without shipping a display:

- **Validation-only read is allowed BEFORE the gate passes.** Evaluating the
  gate requires the actual nightly output, so the same nightly aggregation
  intended for publication is computed and compared against the reference —
  internally only. User-facing output stays withheld until the gate passes;
  `Sample.spo2CandidateRaw` remains unread by the UI in the meantime.
- **Payload changes (edge `payloads.dart`):** `Spo2Data` currently has no
  percentage accessor and `TodayData.spo2` returns null while `odi_per_hour`
  is null. Publication therefore adds: a `spo2Pct` field on `Spo2Data`, a
  `double? get spo2Pct` accessor, and a getter condition on `TodayData.spo2`
  that accepts the payload once validation has passed (flagged by the
  validation record, not by the mere presence of a byte).
- **UI integration:** publishing through `Spo2Data` alone does NOT display
  anything — the chart reads `metric_series` and the Explore row stays hidden
  without stored `spo2` history. The integration step therefore writes the
  validated nightly value into the existing `spo2` series with
  band-derived provenance, reusing the #472 import row's provenance axis —
  NO second `spo2` row, no second chart key.

## Out of scope

- Any medical claim or diagnosis (terms.html: wellness only, not a medical
  device).
- Deriving SpO2 from red/IR ADC counts.
- Persisting live-stream data.
