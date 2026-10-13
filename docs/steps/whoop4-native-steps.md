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

## Proposed opt-in R10 research capture (not implemented)

Plan date: 2026-10-13. Rechecked the application at [41a62050](https://github.com/namahsea/edge/tree/41a62050f505f3902c2a6b408b34660a208d3f92). This section specifies a future research tool, not step counting. “Reconstruction” means our own analysis of stored motion; it does not establish a native band step total.

### Verified interception points

| Stage | Existing code / symbols | Consequence for the plan |
| --- | --- | --- |
| Receive | [ble_engine.dart](https://github.com/namahsea/edge/blob/41a62050f505f3902c2a6b408b34660a208d3f92/lib/ble/ble_engine.dart), frame routing and serialized offload queue | Historical data and metadata already share the ordered drain. Keep this routing intact. |
| Decode | Same file, `_ingestHistoricalFrame` and `parseR10Lite` | The historical R10 sample has HR/RR/timing but does not retain accelerometer arrays. |
| Accept / reject | Same file, `_recordGate.admit`, `_archiveHistoricalFrame` | Accepted records become `RawRecord` plus `Sample`; rejected/undecodable records become `ArchiveRecord`. Both still carry inner bytes at this point. |
| Buffer / commit | `d.onHistoricalRecord`, then `d.commit(m.token)`; [app_state.dart](https://github.com/namahsea/edge/blob/41a62050f505f3902c2a6b408b34660a208d3f92/lib/state/app_state.dart), `onCommitBatch` | The existing callback receives accepted raw records, samples, archives, and device family before ACK. No new BLE callback is needed for the first version. |
| Durable normal storage | `_bandHost.commitNativeBatch` and [db.dart](https://github.com/namahsea/edge/blob/41a62050f505f3902c2a6b408b34660a208d3f92/lib/data/db.dart), `commitSyncBatch` | Preserve the existing atomic decoded-data/archive/cursor transaction and error propagation. |
| Trim authorization | `buildHistoryResultOk` after successful commit, task-generation and verdict checks | Return from the existing callback only after a bounded research-write attempt, if enabled. Do not generate a second ACK or change its token. |

[models.dart](https://github.com/namahsea/edge/blob/41a62050f505f3902c2a6b408b34660a208d3f92/lib/data/models.dart) confirms that `RawRecord.hex` contains the **full inner payload**, `capturedAt` is receive time in milliseconds, and `recTs` is device time in seconds. `ArchiveRecord` also carries inner hex and receive time, but its decoded record time can be absent. The old comment about keeping successful raw bytes for cloud re-decoding is not the current persistence behavior.

The smallest hook captures what arrives in the existing safe-trim batch callback. Pre-setup direct-store fallbacks and separate headless engines are outside this first version. Their absence must be declared in the session manifest; this is not a capture of every packet received by every app execution path.

### Smallest proposed change

Add a separate research recorder owned by AppState, and invoke it from the current foreground `onCommitBatch` callback:

1. Run the existing reset check and await `_bandHost.commitNativeBatch` exactly as today. A normal commit failure must still throw and prevent ACK.
2. If the build gate and explicit capture session are active, inspect that callback's `raws` and `archives`, without mutating either list or the samples.
3. Copy only matching WHOOP 4.0 historical R10 inner payloads into the separate local research store and await its write/flush before returning.
4. Catch **only research-store failures** separately. Stop research collection, mark it incomplete where possible, and surface the failure in the research screen. Normal sync may then continue under its existing durable-commit rules. Never catch and suppress a normal database/reset error.
5. Leave the engine's existing ACK checks and command writes untouched.

This is deliberately a **best-effort research copy**. When capture succeeds, bytes have been saved before ACK. When capture fails or reaches its limits, normal sync can still ACK and trim; the session must not claim those missing records were retained. A strict “no research byte lost” mode would require a different sync failure policy and is outside this small plan.

Use a private, dedicated directory under the platform's application cache/temporary directory, not `raw_archive`, `substrate_archive`, or a new table in the main database. Keep original payloads once; decode arrays when exporting. No schema migration, analytics-version bump, protocol re-pin, or new package dependency is expected for this capture-only version.

A minimal record filter must require:

- A positively identified `deviceFamily == 'gen4'`; absent identity means skip, not assume gen4.
- Inner packet byte `0x2F` and version/type byte `0x0A`.
- Initially the observed 1,920-byte form. Count other lengths as unsupported; do not reinterpret short historical version-10 records as R10.
- For archived candidates, preserve the archive reason and label them rejected/undecoded. Do not promote them into accepted physiology or trusted coverage.

The protocol's 685-byte minimum establishes room for the arrays, but does not establish the semantics of every longer, previously unseen layout. Broadening the first capture filter beyond the observed form should be a deliberate later research change.

### Opt-in, lifecycle, and limits

The existing [advancedDebugMode](https://github.com/namahsea/edge/blob/41a62050f505f3902c2a6b408b34660a208d3f92/lib/debug/debug_mode.dart) is a compile-time flag, while [settings.dart](https://github.com/namahsea/edge/blob/41a62050f505f3902c2a6b408b34660a208d3f92/lib/ui2/profile/settings.dart) has a runtime developer group. Neither alone is sufficient consent.

Proposed gates: Flutter `kDebugMode` **and** a new `WHOOP4_R10_RESEARCH` compile-time flag defaulting false **and** an explicit in-session Start action. The developer entry is visible only when those build gates pass. Do not persist an “enabled” preference or resume capture automatically after process restart.

The debug screen should provide Start, Stop, local Export, Delete, visible active/incomplete status, record/byte counts, and optional manual interval labels. Starting should explain that payloads contain health data and unknown fields. Turning developer mode off, resetting data, changing paired band, stopping, or reaching a limit must stop collection. Process death never re-arms it; surviving files remain explicitly unfinished.

Initial proposed limits, to verify on hardware: one session, 30-minute wall-clock lifetime, 20 MiB total raw/metadata storage, and a small bounded write batch. At the first size/time limit, stop collection and label the session truncated rather than silently downsample or overwrite. Export expansion needs its own bounded size check. Expired research files and export copies should be deleted after 24 hours on the next eligible research operation/startup, with immediate manual deletion available; deletion while the app is not running cannot be promised.

Capture only in the foreground callback; background/headless commits remain unchanged. A session may remain armed in RAM during a short phone-away interval, but collection is suspended while the app is backgrounded and that suspension must appear in the manifest. Return to the foreground before reconnecting. Do not change radio subscriptions, sync cadence, sensor/raw-save modes, battery polling, reconnect policy, or historical command parameters to create more data.

Cache storage is intentionally outside normal database backups, but is **evictable** and not a permanent archive. Verify actual Android/iOS cache placement and backup exclusions on target devices. If these cannot be established, fail closed for research capture on that platform rather than move into backed-up storage.

### Local storage and export contract

Keep bounded per-chunk NDJSON files, written to a temporary name, flushed/closed, then renamed within the research directory. A completed chunk marker records counts and a content digest. A truncated file or missing marker means incomplete capture. This provides a checkable file boundary, not an untested power-loss guarantee. Test platform behavior; never treat an unfinished file as a complete chunk.

Use a versioned manifest plus streaming NDJSON export, generated only after Stop. Export into that same private cache tree. The first version does not invoke a share sheet, cloud provider, automatic backup, telemetry, health export, or network client. A developer can deliberately retrieve the local bundle with device tooling; the app itself sends nothing. No capture data or real user bundle belongs in GitHub fixtures or issue attachments.

| Export item | Proposed representation and provenance |
| --- | --- |
| Device record time | Nullable `record_ts_epoch_s`, plus `timestamp_status`. Keep decoded header time even if rejected, labeled untrusted; never replace it with receive time. |
| Receive and commit times | `received_at_epoch_ms` from `capturedAt`; separate `context_observed_at_epoch_ms` and batch-commit observation time. |
| Raw payload | Exact `inner_hex`, payload byte length, packet/type bytes, sequence counter, and digest. Specify `payload_scope: inner`; outer framing, CRC bytes and radio fragments are not captured by this hook. |
| Disposition | Accepted or archived, archive reason, session-local batch identifier, normal commit succeeded flag, and research write status. Do not claim ACK success: this callback precedes ACK. |
| Accelerometer arrays | `accel_x_lsb`, `accel_y_lsb`, `accel_z_lsb`, 100 signed integer values each; `accel_scale_g_per_lsb: 1/4096`. Use the existing pinned protocol `frameAccel` reader during export, off the UI isolate. On decode failure retain raw and emit null arrays with a reason. |
| Sampling | Sample count, nominal rate 100 Hz marked repository-reported, adjacent timestamp deltas, duplicate/conflict counts, segment boundaries, and gap list. No invented per-sample absolute times. |
| Context | Session-local random device alias, identified generation, app version, protocol SHA, and firmware if already exposed. Existing `DeviceState.batteryPct`, `charging`, `chargingTs`, and connection transitions can be observed through `_onEngineState`; include observation times/freshness. Missing firmware/RSSI/battery remains null. |
| Reference intervals | Optional manually entered start/end times, activity label and independently counted steps, explicitly labeled user annotations rather than band output. |

Battery and connection snapshots observed during reconnection describe **sync time**, not the battery or link state when historical motion was recorded. Preserve observed timestamps and unknown freshness rather than projecting current context backwards. Do not add new polling to fill missing context.

Coverage needs two independent reports:

- **Capture completeness:** eligible observations seen in the callback versus successfully retained, retries/duplicates, exclusions, suspension intervals, write failures, limits, and unfinished chunks.
- **Motion availability:** distinct accepted, timestamp-valid R10 records within the manually specified study interval, contiguous timestamp runs, sample counts, missing seconds, and conflicting records for the same time. Archived/untrusted records are reported separately.

Do not use first-to-last timestamp span as continuous coverage. A nominal duration estimate may use 100 samples / 100 Hz only with an explicit assumption label; measured sampling rate and within-record timing remain unverified. If interval bounds or clock alignment are unknown, coverage fraction is null. “No R10 observed in this callback” does not prove the band recorded none.

Retry identity should use session-local device alias plus exact payload digest, not timestamp or counter alone. Export duplicate observations/counts and conflicting same-second payloads without counting them twice as unique coverage. Normal database deduplication must remain untouched.

### Privacy risks and containment

**The raw payload is health data**, even if only acceleration is exported as decoded columns. It also includes HR/RR and unknown regions; motion and timestamps can reveal routines or behavior. A random alias removes direct identifiers from metadata but does not anonymize the waveform or opaque bytes.

A significant existing path is [health_uploader.dart](https://github.com/namahsea/edge/blob/41a62050f505f3902c2a6b408b34660a208d3f92/lib/telemetry/health_uploader.dart): with separate consent/build gates, it exports the main database using `LocalDb.exportCopy(includeSubstrateArchive: false)`. That export excludes `substrate_archive`, **not arbitrary new tables or raw-archive reasons**. Adding research R10 to the main database could therefore include it in existing uploads/backups. The separate cache store avoids introducing research records into those paths without changing existing user preferences.

Containment requirements for the implementation:

- Do not log raw hex, decoded arrays, study annotations, stable identifiers, or private file contents through AppState `_log`, FileLog, Crashlytics, or telemetry. Error messages must contain only fixed error categories and nonsensitive counters.
- Store no MAC, serial, account/profile, DOB, GPS, full database copy, or battery-pack identifier in metadata. Do not rewrite opaque payload bytes to pretend they have been anonymized.
- Use app-private cache permissions. Exclude the directory from automatic backup, database export and import, uploader, AI/coach inputs, OS health export, and generic log bundles.
- Explain that cache files are plaintext under OS app protection unless an independently reviewed encryption design is added later. Rooted devices, debug extraction, or copied exports can expose them.
- Delete only this research directory and its exports on Delete/Reset; do not claim secure erasure on flash or deletion of copies a person already extracted.
- Stop and warn on research storage errors. Normal sync continuing can make lost research bytes unrecoverable after trim; show that limitation explicitly.

No network code, new permission, or cloud integration is part of this plan.

### Validation process and implementation sequence

1. **Recorder and gating tests first:** disabled-by-default means no research file or decode/write work; release/profile builds cannot arm capture; enabling developer mode alone cannot start it. Verify all stop/restart/reset paths.
2. **Selection and byte integrity:** use synthetic records and the pinned public fixture, without collecting new user data for CI. Include accepted R10, archived R10, short version-10 history, R24, gen5, live R10, invalid hex and unknown identity. Only known gen4 historical candidates qualify; exported inner bytes round-trip exactly.
3. **Sync integration:** prove normal commit occurs before research flush and callback return/ACK eligibility. Normal commit/reset errors still propagate; research errors alone cannot claim a successful capture or silently block sync forever. Exercise retried chunks, disconnect/task invalidation, trailing commits without tokens and interrupted export. Never assert this callback proves an ACK was sent.
4. **Storage/privacy regression:** enforce limits and cleanup, detect partial files, verify cache locations, and exercise existing database export, backup and uploader snapshot with sentinel research bytes. Assert they contain no new research bundle/metadata. Verify research operations make no network calls and add no payload logging.
5. **Coverage/export tests:** duplicates, same-second conflicts, timestamp regressions, invalid clocks, gaps, suspension and missing study bounds. Test known int16 axis values/scaling against the existing protocol reader; null stays null. Export/decoding must be streamed and off the UI isolate.
6. **Controlled hardware pilot:** start the tool before reconnect/catch-up; establish a short clock-aligned reference interval with counted walking, stillness and nonwalking arm movement, including a phone-disconnected interval. Record firmware/settings without changing recording modes. Reconnect foreground, stop and inspect local files. Report R10 availability first; do not count steps yet.
7. **Decision after pilot:** if there is no usable R10 coverage, record that result for the tested firmware/mode and investigate separately. If coverage is sufficient, repeat across sessions/users and longer disconnections. Only then design and validate a separate analytics detector against independent counted steps; retain the native-versus-reconstructed distinction.

Suggested performance acceptance: no work on the disabled path beyond the gate; bounded memory, disk and export size when enabled; measure extra commit latency on target phones. If capture latency destabilizes history sync, stop the experiment and revise the recorder rather than relax ACK/token safeguards. A hard timeout must not leave detached writes running after consent is revoked; cancellation and cleanup need explicit tests.

This sequence is a proposed future implementation. No recorder, controls, export files, step detector or device experiment was created or run in this documentation update.

### Exact proposed code changes for the first capture version

The filenames below define the proposed patch scope; new filenames are proposals, not claims that these files already exist.

| File in this fork | Later change |
| --- | --- |
| `lib/debug/debug_mode.dart` | Add the dedicated default-off research build gate, also requiring debug build mode. |
| `lib/state/app_state.dart` | Own the session; invoke the recorder from the existing commit callback; observe existing device context; stop/clear on lifecycle, reset, developer-off and band changes. |
| `lib/debug/whoop4_r10_capture.dart` **(new)** | Eligibility, session/limits, bounded private-cache chunk retention, deduplication, context timeline, error status and cleanup. |
| `lib/debug/whoop4_r10_export.dart` **(new)** | Local-only streaming manifest/NDJSON generation, pinned protocol acceleration extraction, coverage calculation and export-size limits. |
| `lib/ui2/profile/settings.dart` | Add the build-gated research entry to the existing developer group and wire developer-off revocation. |
| `lib/ui2/profile/whoop4_r10_research.dart` **(new)** | Debug-only consent, Start/Stop/Delete/local Export, reference interval inputs, and capture completeness/status. |
| `test/whoop4_r10_capture_test.dart` **(new)** | Selection, default-off gates, limits, retries, cleanup and partial-file behavior. |
| `test/whoop4_r10_export_test.dart` **(new)** | Byte round-trip, array scaling, coverage honesty, exclusions and no-network export. |
| `test/app_state_r10_research_test.dart` **(new)** | Commit ordering/failure isolation, context/lifecycle wiring, developer-off and reset, and existing export/uploader isolation. |

No changes to `ble_engine.dart`, `db.dart`, models, normal metric screens, protocol/analytics dependencies, or root README are proposed for this smallest version. Reusing the current callback and `frameAccel` is sufficient for inner payloads. Capturing outer frames, exact ACK outcomes, all headless/pre-setup traffic, or unknown R10 layouts would expand that scope and needs a separately reviewed plan.
