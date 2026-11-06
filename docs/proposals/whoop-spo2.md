# Proposal: WHOOP SpO2 (blood oxygen) — evidence review and staged plan

Status: proposal only, no code yet. Written so other contributors can build on
the current state of `protocol` and `edge` without re-doing this research.

## Process (what was done, openly)

1. Reviewed `christianmeurer/whoop-reader` (MIT) end to end: 96-byte realtime
   packet on the data characteristic, SpO2 claimed at byte 5 (range gate 50–100),
   CRC-32 (poly 0x04C11DB7, xor-out 0xF43F44AC) at bytes 92–95.
2. Cross-checked against the community sources it cites
   (jogolden/whoomp, bWanShiTong/reverse-engineering-whoop) and against current
   open-source projects: ryanbr/noop ecosystem (issues #103, #2814, PRs #73, #11),
   LeonardSEO/wearable5.0, rusheelraj.com/blog/whoop, Gadgetbridge issue #5731.
3. Compared with what our own repos already know: `protocol` (`live.dart`,
   `records.dart`, `gen5_records.dart`), `whoop-rs` (`whoop-protocol/src/live.rs`,
   `spo2_from_paired`, v18 `spo2_pct`), `edge` (`ble_engine.dart`,
   `adapters/whoop_gen4.dart`, `adapters/signals.dart`).

What was NOT done: no real-device captures, no ground-truth comparison against a
reference oximeter, no CRC verification against our own captures. Everything
below that is not marked "verified in our repos" is community knowledge with
the confidence level stated.

## Findings by generation

### WHOOP 4.0 — no secured SpO2

- whoop-reader decodes byte 5 of the 96-byte realtime packet as SpO2 %.
  Single source, no ground truth, only a 50–100 plausibility gate.
- The original reverse-engineering author states blood oxygen on the 4.0 is
  "only measured once a day, during sleep" — so byte 5 is expected to carry a
  value only inside sleep windows and 0/invalid otherwise.
- Our `protocol` repo verified that `spo2RedRaw`/`spo2IrRaw` (inner 64/66) move
  in lockstep with a fixed offset: a red/IR ratio from them tracks channel drift,
  not oxygenation (`records.dart` explicitly forbids building SpO2 on them).
  noop documents the same fields as "raw ADC; SpO2 % computed server-side".
  whoop-rs therefore only computes a ratio-of-ratios estimate on paired v24
  windows and never a calibrated %.
- Open discrepancy: whoop-reader maps the data stream to characteristic
  `61080004-…`, while whoop-rs maps `GEN4_DATA` to `61080005-…` and `…0004` to
  EVENTS (`whoop-client/src/uuids.rs`). One mapping is off by one; must be
  resolved against our own captures before any wiring.
- Constraint from edge AGENTS.md invariant 14: live high-rate streams are
  RAM-only, never persisted. A live SpO2 could therefore only ever be an
  ephemeral display value, never a day metric.

### WHOOP 5.0 / MG — community-reported app agreement, sleep-only

- v18 historical records carry the strap's own computed SpO2 % at frame-abs
  byte 82 (= `inner[74]`), which our `protocol` already exposes as
  `spo2CandidateRaw` (`gen5_records.dart`) but deliberately does not publish as
  a percentage.
- Measurement schedule, confirmed independently by noop#2814, noop#73 and
  wearable5.0 (FINDINGS §13): 30 s measurement bursts every 1,200 s, only while
  the band declares sleep. 5/MG never sends red/IR raw channels (noop#11).
- Validation against the vendor app (noop#73): nightly means 93.4–96.7 vs
  WHOOP's own 93.1–96.5 over the same weeks (period means 94.4 vs 94.8). No
  night had both readings, so this stays an estimate, not a validation.
- Offline derivation of SpO2 from raw PPG is physically not possible on 5.0
  (26 time-multiplexed optical channels; red/IR never sampled simultaneously).
  The byte-82 device value is the only usable source.
- Encoding not fully pinned: values above 128 decompose as `128 + flag`, bit 7
  looks like a status flag. This is why `spo2Candidate` is deprecated.

## Self-critical assessment

- "Matches the WHOOP app" is agreement, not validation; only a reference
  oximeter (or PSG-grade device) validates. We state this explicitly, following
  the precedent in `vendor-staged-sleep.md`.
- The gen4 byte-5 claim is single-source and contradicted by the sleep-only
  measurement reports; we treat it as unverified.
- No project anywhere publishes a live (daytime) SpO2 for any WHOOP
  generation. The realistic product surface is a nightly sleep SpO2 for
  5/MG, plus at most a raw/diagnostic byte for gen4.
- All sources agree the raw ADC channels cannot yield SpO2; any PR deriving %
  from red/IR on 4.0 contradicts our own verified findings and should be
  rejected.

## Staged plan (proposed)

1. **protocol** — raw, gated decode only:
   - Keep `spo2CandidateRaw` as-is; add a pinned, documented interpretation
     (bit 7 flag, value = low 7 bits) behind a plausibility gate, still
     labeled candidate until validated.
   - Add a decoder for the 96-byte realtime packet exposing byte 5 as **raw +
     CRC flag only** — no percentage publishing. Resolve the characteristic
     UUID discrepancy from real captures first.
   - Tests from real frames; extend parity fixtures where applicable.
2. **whoop-rs** — DEFERRED: current scope is `protocol` + `edge` only. When
   picked up: mirror the decoders in `whoop-protocol` (live 96-byte packet,
   v18 byte 82 interpretation), expose raw values via `whoop-ffi`; keep the
   existing `spo2_pct` v18 and `spo2_from_paired` paths unchanged.
3. **edge** — pass through the band-reported `deviceSpo2` samples for
   gen5/5.0/MG; the per-burst medians and the nightly mean are computed in
   `OpenStrap/analytics` (a metric, not signal wiring — AGENTS.md assigns
   metrics there), labeled as a device estimate, same labeling discipline as
   `vendor_staged`.
   - NO user-facing display on either generation until the validation
     workstream lands: gen5 byte 82 stays raw until its encoding (bit-7 flag)
     is pinned and validated against a reference device; gen4 byte 5 stays
     diagnostic, never user-facing, until ground-truth validated.
   - Diagnostics stay RAM-ONLY, never in `_log`/FileLog: FileLog writes to
     Android external storage (`lib/sync/file_log.dart`), so a timestamped
     candidate/sleep line there is readable by other apps (CWE-532).
   - Respect invariants: live streams RAM-only (inv. 14), never fabricate a
     metric (inv. 3), bump `kAlgoVersion` when any output changes (inv. 4).
4. **Validation workstream** (prerequisite for ANY user-facing SpO2 value,
   both generations): paired measurements against a reference oximeter over
   at least 10 nights / 30 paired samples; the display gate opens only when
   accuracy criteria are met — MAE <= 2 pp AND |mean bias| <= 1 pp AND
   Bland-Altman 95% limits of agreement within +/-4 pp. Correlation
   (Pearson/Spearman) is reported separately and is NEVER treated as proof of
   accuracy. Burst-level pairs are NOT sufficient: the gate must also compare
   the actual NIGHTLY OUTPUT (our aggregation over the band-declared sleep
   window, burst weighting included) against the reference aggregated over the
   same night, because burst-level agreement can pass while the nightly
   calculation uses the wrong window or weights. Gen4 has NO nightly SpO2
   output — its byte 5 is a live-stream byte only — so any Gen4 display gate
   must instead use time-aligned LIVE reference measurements (same accuracy
   thresholds: MAE <= 2 pp, |bias| <= 1 pp, 95% LoA within +/-4 pp), never the
   nightly gate. Plus: byte-82 encoding pin-down, UUID discrepancy
   resolution.

## Out of scope

- Any medical claim or diagnosis (terms.html: wellness only, not a medical
  device).
- Deriving SpO2 from red/IR ADC counts.
- Persisting live-stream data.
