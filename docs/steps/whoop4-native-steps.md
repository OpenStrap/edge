# WHOOP 4.0 stored records and native steps

Research date: 2026-10-13. Documentation only; no decoder, app, UI, or sync behavior changed.

## Finding

**OpenStrap cannot currently decode a verified, band-native all-day step total from WHOOP 4.0 historical records.** No mapped WHOOP 4.0 field in the audited decoder is established as a step counter. This establishes the current implementation's limits, not that the hardware has no such field.

There is a concrete lead: the protocol fixture contains large **historical R10 records with accelerometer arrays**, and the protocol library supports reading those arrays. Edge's historical ingestion keeps only their timestamp, heart rate, record counter, and RR intervals. It does not use those arrays for historical steps. Whether a disconnected band records these continuously, under normal settings, for a complete day remains unproven.

Two different outcomes must stay separate:

- **Native steps:** decoding a counter or aggregate actually calculated by the band. Not established for WHOOP 4.0.
- **Reconstructed steps:** applying our own validated detector to stored motion samples. Potentially feasible for intervals with sufficient samples, but continuous offline coverage and accuracy are unverified.

A statement that *all* WHOOP 4.0 history contains only low-rate summaries would be too broad. Low-rate R24 telemetry is not the only historical packet family present in the audited fixture.

## Scope and evidence levels

Audited Edge at [303723dc](https://github.com/namahsea/edge/tree/303723dc7e612bfde4c48cb5e2f6da2428a546e9), with its pinned dependencies:

- [OpenStrap protocol 89080bcf](https://github.com/OpenStrap/protocol/tree/89080bcfac7767b3a871fd3a7d9307f5f30dad26).
- [OpenStrap analytics ad638474](https://github.com/OpenStrap/analytics/tree/ad6384746d36a2e6b7b964658d308e40de403c8a).

**Proven here** means observable in these source revisions or the checked-in fixture bytes. It does not mean independently validated against a device or WHOOP's internal implementation. **Repository-reported** means an interpretation or hardware observation described by source comments/tests. **Hypothesis** means a possible explanation requiring new evidence.

This review inspected source and counted fixture bytes in memory through GitHub. It did not connect to a band, collect new offline recordings, run Dart tests, or independently establish the provenance or walking ground truth of the fixture.

## What the public WHOOP information establishes

[WHOOP's Steps support article](https://support.whoop.com/s/article/Steps) lists WHOOP 4.0 as supported and describes accelerometer-based step detection with machine-learning filtering. Its [step-tracking announcement](https://www.whoop.com/us/en/thelocker/start-tracking-steps-with-whoop/) also describes processing motion data. Neither source identifies a BLE step-counter offset or establishes whether the final algorithm executes on the band, phone, or service.

The user reports official support saying the band retains up to 14 days of unsynced data. The [WHOOP 4.0 connectivity support page](https://support.whoop.com/s/article/WHOOP-4-0-iOS-Connectivity-and-Pairing?language=en_US) returned only a site shell during this review, so the exact retention statement was not independently retrieved here.

Even accepting that retention statement, **stored sensor history does not establish stored step totals**. Catch-up could involve later computation from sensor data or other features. The 14-day claim also does not establish that every raw accelerometer sample is retained for that duration.

## Historical sync and persistence

In [ble_engine.dart](https://github.com/namahsea/edge/blob/303723dc7e612bfde4c48cb5e2f6da2428a546e9/lib/ble/ble_engine.dart), the historical flow is:

1. Send the historical-data command.
2. Receive framed historical data, identified by inner packet type `0x2F`.
3. Dispatch by device family and record version in `_ingestHistoricalFrame`.
4. Decode accepted records to `Sample`; archive undecodable records as raw hex.
5. Commit the batch, including relevant cursor/archive state.
6. Only after successful durable commit, send the history-result acknowledgement using the received metadata token.

Acknowledgement lets the band advance/trim the drained history. The safe-trim guarantee is a durable commit of the data Edge chooses to retain; it is **not a guarantee that all original bytes of successfully decoded records remain available**.

Historical `0x2F` packets do not enter the live-frame callback used by the live motion/step pipeline. Increasing sync frequency changes when data is drained; it does not prove a change in sensor recording rate.

In [db.dart](https://github.com/namahsea/edge/blob/303723dc7e612bfde4c48cb5e2f6da2428a546e9/lib/data/db.dart):

- `commitSyncBatch` persists interpreted samples and queues supported canonical one-Hz rows.
- `raw_archive` retains undecodable/rejected records and selected other cases, subject to retention policies.
- The old `raw_records` store has been dropped. A temporary `RawRecord` object in the sync flow does not imply permanent storage of its hex.
- Successful R24 payload tails and successful R10 IMU payloads are not generally preserved by that path. Reanalysis may therefore require a new capture before acknowledgement allows trimming.
- `_isGen4R10LiteHistorical` excludes historical R10 samples from canonical one-Hz conversion; they remain in the legacy samples path.

## Fields and record families

All offsets below are **zero-based offsets into the inner payload**, including its packet-type byte. They are not offsets into a complete BLE frame. Maps must be gated by generation, layout version, and payload length.

| Requested quantity | Evidence in WHOOP 4.0 history | Assessment |
| --- | --- | --- |
| Steps | No verified step field in mapped R24 or R10 headers. | Native all-day totals unavailable in current implementation. |
| Activity counts | No validated firmware count or activity-class field in the mapped gen4 records. | Protocol `activity` is locally computed from R10 acceleration, not an encoded count. |
| Accelerometer summaries | R24 contains three float32 vector components at offsets 36, 40, 44; a duplicate vector occurs at 52, 56, 60. | Available low-rate motion/gravity information; not a raw stepping waveform. |
| Accelerometer waveform | Large historical R10 carries 100 int16 samples per axis at offsets 85, 285, 485. | Decodable in protocol; ignored by Edge's historical ingestion. Full-day availability unknown. |
| Movement intensity | R10 magnitude standard deviation can be computed; analytics can derive motion/activity measures from available inputs. | Derived measures, not proven firmware intensity aggregates. |
| Calories / strain aggregates | No validated gen4 historical fields found for either. | App calculations from HR/profile are not decoded band totals. Unknown bytes could have other meanings. |

### R24 and related low-rate versions

[records.dart](https://github.com/OpenStrap/protocol/blob/89080bcfac7767b3a871fd3a7d9307f5f30dad26/lib/src/records.dart) maps timing, HR, RR intervals, acceleration/gravity vectors, and selected optical/ambient values. The strongest field maps are for versions 24 and 12; other recognized versions have different offsets or partial support.

Important exclusions:

- The uint32 at offsets 3–6 is a **record sequence counter**, used for stream/sync ordering. It is not a step count and can reset on reboot.
- The vector at offsets 52–63 duplicates the vector at 36–47 in the inspected v24 fixture entries. It is not a second high-frequency motion window.
- Float32 regions at offsets 32–35 and 48–51 remain semantically unresolved. The latter overlaps the legacy `skinContact` byte; treating that byte as a reliable wear/quality measure is unsupported by the newer field analysis.
- Other unresolved tail values, including regions around offsets 72 and 88, are not established steps, activity, calories, or strain.
- Legacy names such as `skinTempRaw` and `ppgRedIr` are not proof of physical meaning. The decoder documents substantial uncertainty in those interpretations.

The decoder exposes `rawTail`, but Edge does not persist that tail for successfully accepted R24 samples. Unknown bytes are therefore a research opportunity, **not an already decoded step field being discarded**.

Version 25 is treated separately: repository comments describe periodic optical waveform bursts. Edge archives it rather than treating it as ordinary R24 telemetry. No step interpretation is established.

### Historical R10: the strongest motion lead

[live.dart](https://github.com/OpenStrap/protocol/blob/89080bcfac7767b3a871fd3a7d9307f5f30dad26/lib/src/live.dart) recognizes long R10 records in both live `0x2B` and historical `0x2F` forms. `frameAccel` can read the arrays from either form. The minimum length for the array region is 685 bytes; fixture records are 1,920 bytes.

The repository reports approximately 100 Hz: 100 samples per axis with consecutive record timestamps one second apart. That observation does not prove ordinary offline recording produces continuous R10 history over hours or days.

Edge instead calls `parseR10Lite` from [control.dart](https://github.com/OpenStrap/protocol/blob/89080bcfac7767b3a871fd3a7d9307f5f30dad26/lib/src/control.dart), extracting only timestamp, sequence counter, HR, and RR. This is a real omitted motion payload.

Protocol `decodeRecord` also exposes `stepsInc` for R10. **It computes this locally**, using detrending and autocorrelation; it does not decode a native band count. At the documented 100 Hz rate, its lag range 7–40 cannot represent ordinary walking cadences of 100–130 steps/min. The source and existing tests report zero output on their real R10 fixture records. That is neither validation of an accurate detector nor evidence that the wearer took zero steps.

A short historical record whose version byte is 10 is not automatically the same R10 layout. Protocol motion decoding length-gates this case; Edge's lite historical dispatch uses a weaker length check. New research must classify both length and packet family rather than treating every `0x2F/0x0A` record as IMU data.

### R11 and generation differences

Historical R11-shaped records are present in the fixture. Edge has no matching accepted gen4 physiological sample path for them, so they fall through to raw archival.

The protocol's `decodeR11Raw` is explicitly a **live-only** decoder. Its two-channel signal meaning remains unconfirmed; source comments report that an accelerometer interpretation was ruled out for the live captures examined. Do not apply the live map to historical R11 or label either as steps without further evidence.

[gen5_records.dart](https://github.com/OpenStrap/protocol/blob/89080bcfac7767b3a871fd3a7d9307f5f30dad26/lib/src/gen5_records.dart) has a separate gen5 v18 `stepMotionCounter`, cadence, and activity-class interpretation. The counter's observed behavior has stronger evidence than its semantic naming; the code still qualifies those interpretations. **These are not WHOOP 4.0 fields.** Gen4 and gen5 versions can reuse version numbers with different layouts.

Edge's nullable `step_count`, `step_cadence`, and `activity_class` columns do not establish gen4 support. Its [_stepCounterModulus mapping](https://github.com/namahsea/edge/blob/303723dc7e612bfde4c48cb5e2f6da2428a546e9/lib/compute/derivation_engine.dart) currently has a gen5 entry only.

## Fixture inspection and limits

The pinned [decode_parity_cases.json](https://github.com/OpenStrap/protocol/blob/89080bcfac7767b3a871fd3a7d9307f5f30dad26/decode_parity_cases.json) contains 2,934 entries but only 978 distinct hex payloads. Duplicate entries must not be counted as independent observations.

Direct byte inspection found:

| Inner packet / version / length | Fixture entries | Distinct payloads |
| --- | ---: | ---: |
| Historical `0x2F` / 24 / 96 bytes | 1,887 | 629 |
| Historical `0x2F` / 10 / 1,920 bytes | 237 | 79 |
| Historical `0x2F` / 11 / 1,924 bytes | 237 | 79 |

All 1,887 v24 entries had byte-identical vector regions at offsets 36–47 and 52–63. The fixture includes live and control families too; the table is not the full corpus.

Entries contain `kind`, `hex`, and `out`. They do not provide independently counted walking steps, disconnected-session labels, or proof of normal all-day coverage. Expected decoder output is not independent physiological ground truth.

Existing test source inspected, **not executed in this review**:

- [gen4_field_honesty_test.dart](https://github.com/OpenStrap/protocol/blob/89080bcfac7767b3a871fd3a7d9307f5f30dad26/test/gen4_field_honesty_test.dart): field uncertainty and limitations of the R10 step search.
- [decode_integrity_test.dart](https://github.com/OpenStrap/protocol/blob/89080bcfac7767b3a871fd3a7d9307f5f30dad26/test/decode_integrity_test.dart): long historical R10 recognition and short-version collision guards.
- [r11_test.dart](https://github.com/OpenStrap/protocol/blob/89080bcfac7767b3a871fd3a7d9307f5f30dad26/test/r11_test.dart): live R11 structural decoding, without establishing signal meaning.

## Proven, guessed, and unknown

**Proven in the audited code/bytes**

- Historical sync exists and can deliver more than the ordinary R24 summary family.
- The fixture has long historical R10 payloads, and protocol code can extract their acceleration arrays.
- Edge's historical R10 path ignores those arrays; its accepted R24 path also omits unknown raw tails from durable storage.
- No currently mapped gen4 field is established as native steps. Existing R10 `stepsInc` is a local estimate.
- Record sequence counters and gen5 field mappings cannot serve as gen4 native steps.

**Hypotheses, not findings**

- An unresolved gen4 field or firmware-specific record might encode a native step/motion aggregate.
- Stored R10 might permit retrospective step estimation for some offline intervals.
- WHOOP's displayed total might be calculated after sync from raw data, summaries, proprietary features, or a combination.

**Still unknown**

- Whether normal WHOOP 4.0 offline operation records R10 continuously, intermittently, only in particular modes, or in response to specific commands.
- Which firmware versions, settings, and sync modes expose each historical family.
- Whether any unmapped bytes are counters with step semantics, and their reset, rollover, wear, and time-boundary behavior.
- Whether all necessary motion data survives long disconnections and normal history retention.
- Where WHOOP performs step computation and whether its official count is recoverable through this BLE interface.
- Accuracy of an independent detector against actual counted steps, including nonwalking wrist motion.

## Recommended next research, before implementation

1. Arrange an explicitly consented WHOOP 4.0 capture with firmware, device family, mode/settings, timestamps, and timezone recorded. Start with a short disconnected interval before attempting a full day.
2. Include independently counted walking, stillness, and nonwalking arm movement. A consenting user's official WHOOP totals may be a secondary comparison, not the sole ground truth.
3. Preserve original framed and inner payloads during catch-up **before acknowledgement permits trimming**, using a separately reviewed capture workflow. Do not assume the current database retains successful raw records, and do not bypass commit-before-ACK safeguards or issue speculative destructive commands.
4. Inventory record families, lengths, versions, timestamps, and gaps across the entire disconnected interval. Determine R10 coverage and sample rate before treating it as retrospective all-day motion.
5. Test candidate counters against counted steps and nonwalking controls across sessions and multiple users. Verify resets, rollover, repeated sync/deduplication, midnight boundaries, and firmware changes. Correlation in a single capture is insufficient.
6. If continuous raw motion is available, evaluate an independent detector with explicit coverage and error reporting. If only partial motion is available, report partial coverage; never fill the missing day with inferred steps.
7. If a true native field is verified, propose a protocol decoder change and tests separately, then Edge persistence/aggregation. If not, retain the distinction between device-derived motion estimates and native totals.

Until those checks succeed, do not advertise native WHOOP 4.0 all-day step recovery. Preserve missing values as unknown. This audit recommends research and capture design, not shipping an unvalidated step estimator.

## Additional inspected application paths

Alongside the linked sync, database, and decoder sources:

- [lib/compute/substrate.dart](https://github.com/namahsea/edge/blob/303723dc7e612bfde4c48cb5e2f6da2428a546e9/lib/compute/substrate.dart): available motion inputs and missing step-counter representation.
- [lib/compute/derivation_engine.dart](https://github.com/namahsea/edge/blob/303723dc7e612bfde4c48cb5e2f6da2428a546e9/lib/compute/derivation_engine.dart): generation-specific counter handling and derived metrics.
- [analytics motion/steps.dart](https://github.com/OpenStrap/analytics/blob/ad6384746d36a2e6b7b964658d308e40de403c8a/lib/src/onehz/motion/steps.dart): motion-based estimates and the distinction between high-rate step detection and low-rate activity measures.
